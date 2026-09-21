// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Charter } from "./AgentTreasury.sol";
import { IWETH9 } from "./DualFill.sol";
import { LaunchParams } from "./TokenLaunchFactory.sol";
import { FillTerms, IDualFillAgentFactory } from "./interfaces/IDualFillAgentFactory.sol";
import { IDualFillAgentTreasury } from "./interfaces/IDualFillAgentTreasury.sol";
import { IDualFillFactory } from "./interfaces/IDualFillFactory.sol";
import { DualFillAgentTreasuryDeployer } from "./libraries/DualFillAgentTreasuryDeployer.sol";

/// @title DualFillAgentFactory
/// @notice Creates the Robinhood Chain side of an agent Dual Fill in one transaction: a treasury
///         with its charter, the runway in it, and the treasury's own fill, so a funded agent
///         without a fill can never exist.
///
/// The treasury, not the person, is the fill's creator. The person stays the Dual Fill's
/// `rhCreator`, and `treasuryOf(rhCreator, dualFillKey)` names the treasury, so nothing has to be
/// predicted before the key exists and the treasury is checked in one read.
///
/// **The charter is sized to the market it will trade.** With `opening = vQuoteInit + target`,
/// the quote side of the pool the fill opens, a single call may spend at most 0.62% of it and a
/// day at most 3%, and a day's sells at most 3% of the opening token side. On a constant-product
/// curve that holds a day of the agent's buys to about a 6% price move whatever the fill's size.
///
/// **The runway is in the fill's quote and the bond in the fee token.** A fill priced in WETH
/// takes one payment that covers both, as before. A fill priced in USDG or a stock takes its
/// runway in that asset by approval and its bond in the fee token beside it, by approval or as
/// ETH on a wrap rail.
///
/// No owner, no fee and no setter. The fill factory, the venue and its allowance ledger are fixed
/// here.
contract DualFillAgentFactory is IDualFillAgentFactory, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PER_CALL_RESERVE_BPS = 62;
    uint256 public constant MAX_DAILY_RESERVE_BPS = 300;
    uint256 internal constant MAX_PAGE = 500;
    uint256 internal constant BPS = 10_000;

    address public immutable DUAL_FILL_FACTORY;
    address public immutable LAUNCH_FACTORY;
    /// The fill factory's default quote on the day this factory was deployed. A treasury's
    /// runway is in its own fill's quote; this is the asset a reader that predates per-fill
    /// quotes expects, and `quoteOf` answers for one treasury.
    address public immutable RUNWAY_ASSET;
    /// The fill factory's bond asset, which every treasury bonds in whatever it trades.
    address public immutable FEE_TOKEN;
    /// Whether ETH can pay in on this rail. It wraps into `FEE_TOKEN`, so it pays the bond on
    /// any fill, and the whole runway only where the quote is the fee token.
    bool public immutable NATIVE_WRAP;
    address public immutable ROUTER;
    address public immutable PERMIT2;

    mapping(address creator => mapping(bytes32 dualFillKey => address treasury)) public treasuryOf;
    mapping(address treasury => bool) public isFromFactory;
    address[] private _treasuries;

    constructor(address dualFillFactory, address router, address permit2) {
        if (dualFillFactory == address(0)) revert ZeroAddress();
        if (dualFillFactory.code.length == 0) revert NotAContract();
        if (router != address(0) && (router.code.length == 0 || permit2.code.length == 0)) {
            revert NotAContract();
        }

        DUAL_FILL_FACTORY = dualFillFactory;
        LAUNCH_FACTORY = IDualFillFactory(dualFillFactory).LAUNCH_FACTORY();
        RUNWAY_ASSET = IDualFillFactory(dualFillFactory).QUOTE();
        FEE_TOKEN = IDualFillFactory(dualFillFactory).FEE_TOKEN();
        NATIVE_WRAP = IDualFillFactory(dualFillFactory).NATIVE_WRAP();
        ROUTER = router;
        PERMIT2 = permit2;
    }

    /// @notice Deploy a treasury with `c` as its charter, fund it with `runway` in `p.quote`, and
    ///         have it create the fill `p` and `t` describe. On a fill whose quote is the fee
    ///         token the runway covers the bond and is paid by approval, or in ETH on a wrap
    ///         rail. On any other fill the runway is paid by approval and the bond, `t.feeBudget`
    ///         of `FEE_TOKEN`, beside it by approval or in ETH on a wrap rail.
    /// @param runway Has to cover one call's spend, and the fill's bond where the bond is in the
    ///        same asset. What the bond does not use stays in the treasury.
    function createAndFill(
        Charter calldata c,
        LaunchParams calldata p,
        FillTerms calldata t,
        uint256 runway
    ) external payable nonReentrant returns (address treasury, address fill) {
        if (treasuryOf[msg.sender][t.dualFillKey] != address(0)) {
            revert TreasuryExists();
        }
        if (c.dailyMint != 0) revert MintUnavailable();
        _checkCaps(c, p, t);
        if (p.quote == address(0)) revert QuoteMismatch();
        bool oneAsset = p.quote == FEE_TOKEN;
        uint256 needed = oneAsset ? t.feeBudget + c.perCallSpend : c.perCallSpend;
        if (runway == 0 || runway < needed) revert NoRunway();

        treasury = DualFillAgentTreasuryDeployer.deploy(
            msg.sender, DUAL_FILL_FACTORY, ROUTER, PERMIT2, p.quote, c, t.dualFillKey
        );
        _pull(p.quote, treasury, runway, oneAsset);
        if (!oneAsset) _pull(FEE_TOKEN, treasury, t.feeBudget, true);
        fill = IDualFillAgentTreasury(treasury).startFill(p, t);

        treasuryOf[msg.sender][t.dualFillKey] = treasury;
        isFromFactory[treasury] = true;
        _treasuries.push(treasury);
        emit AgentDualFillCreated(msg.sender, treasury, c.operator, fill, t.dualFillKey, runway);
    }

    function treasuryCount() external view returns (uint256) {
        return _treasuries.length;
    }

    function treasuries(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = _treasuries.length;
        if (offset >= total) return new address[](0);
        if (limit > MAX_PAGE) limit = MAX_PAGE;
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _treasuries[i];
        }
    }

    function quoteOf(address treasury) external view returns (address) {
        return isFromFactory[treasury] ? IDualFillAgentTreasury(treasury).QUOTE() : address(0);
    }

    /// The limits against the side's market as it opens. `DualFillFactory.createFill` holds the
    /// reserves to the approved row and the target to its cap later in the same transaction, so
    /// a charter checked here against other figures never reaches a fill.
    function _checkCaps(Charter calldata c, LaunchParams calldata p, FillTerms calldata t)
        private
        pure
    {
        uint256 opening = p.vQuoteInit + t.target;
        if (
            c.perCallSpend > (opening * MAX_PER_CALL_RESERVE_BPS) / BPS
                || c.dailySpend > (opening * MAX_DAILY_RESERVE_BPS) / BPS
                || c.dailySell
                    > (Math.mulDiv(p.vTokenInit, p.vQuoteInit, opening) * MAX_DAILY_RESERVE_BPS)
                        / BPS
        ) revert CharterAboveCap();
    }

    /// Each leg goes straight to the treasury, and the treasury's own balance is what is
    /// checked: it is what the bond and every later spend come out of. ETH pays only the leg in
    /// the fee token, which is what it wraps into; the other leg is pulled by approval whatever
    /// was sent.
    function _pull(address asset, address treasury, uint256 amount, bool wrapsHere) private {
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(treasury);
        if (msg.value == 0 || !wrapsHere) {
            token.safeTransferFrom(msg.sender, treasury, amount);
        } else {
            if (!NATIVE_WRAP) revert NativeUnsupported();
            if (msg.value != amount) revert WrongPayment();
            IWETH9(asset).deposit{ value: amount }();
            token.safeTransfer(treasury, amount);
        }
        if (token.balanceOf(treasury) != before + amount) revert WrongPayment();
    }
}
