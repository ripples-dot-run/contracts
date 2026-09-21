// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CollectionParams, Mode } from "./Collection721.sol";
import { IWETH9 } from "./DualFill.sol";
import { LaunchParams, LinkedParams, TokenLaunchFactory } from "./TokenLaunchFactory.sol";
import { ILinkedDualFill } from "./interfaces/ILinkedDualFill.sol";
import { ILinkedDualFillFactory } from "./interfaces/ILinkedDualFillFactory.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";
import { LinkedDualFillDeployer } from "./libraries/LinkedDualFillDeployer.sol";

/// @title LinkedDualFillFactory
/// @notice Deploys the Robinhood Chain side of every combined Dual Fill, and is the record of
///         which of those fills are real.
///
/// A combined side opens a linked launch: a token of exactly `TOTAL_SUPPLY`, its market, and a
/// collection whose mints route part of their price into that market and earn minters a share of
/// the supply. Everything that launch will be is fixed here, before any money arrives, and held to
/// what the launch factory and the collection will accept when the fill opens: the supplies, the
/// approved linked row, the identity, the coupling and the collection's terms. A fill that takes
/// deposits can therefore open, unless the launch factory's owner restates the row, revokes the
/// quote or raises the fee past the bond, in which case it refunds like any side that did not
/// open.
///
/// A fill escrows the quote its launch names, and its collection mints in the same asset. The
/// quote is admitted here as the launch factory will admit it at open: a live row, the asset's
/// own decimals, and the row's linked shape. The bond stays in the fee token whatever the quote.
///
/// The collection is held to one shape: pre-generated artwork at a base URI that `open` freezes,
/// minting from the open with no end time, no later waves and the vest kept by the wallet that
/// minted. Its price has to route at least the minters' share at the opening price once every
/// piece has sold, so a sold-out collection never hands minters tokens below what contributors
/// paid.
///
/// No owner, no fee and no setter, as `DualFillFactory`. Both sides of a combined Dual Fill open
/// or neither, so a fill here can never be created to open alone.
contract LinkedDualFillFactory is ILinkedDualFillFactory, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FILL_BPS = 4_000;
    uint64 public constant MIN_DURATION = 10 minutes;
    uint64 public constant MAX_DURATION = 24 hours;
    uint64 public constant MIN_PUBLIC_WINDOW = 10 minutes;
    uint64 public constant OPEN_GRACE = 15 minutes;
    uint256 public constant TOTAL_SUPPLY = 1_065_000_000e18;
    uint256 public constant LP_SUPPLY = 265_000_000e18;
    uint256 public constant V_TOKEN_INIT = 1_073_000_000e18;
    uint96 public constant MAX_CREATOR_TAX_BPS = 1_000;
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 10;
    uint96 public constant MAX_NFT_ALLOCATION_BPS = 500;
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    /// `open` stores the identity in the token and the collection at about 700 gas a byte, on top
    /// of an open that costs 13.2M with a short one. At the launch factory's own limits the widest
    /// open measured 16.4M, more than the opener sends, so a combined side is held tighter: the
    /// widest open these admit measures 14.46M with its calldata (`LinkedDualFillFork.t.sol`).
    uint256 public constant MAX_URI_BYTES = 200;
    uint256 public constant MAX_PIECES = 1_000;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 768;
    uint256 internal constant MAX_SOCIAL_BYTES = 96;
    uint256 internal constant MAX_WALLET_CAP = 65_535;
    uint64 internal constant MAX_VEST_CLIFF = 365 days;
    uint64 internal constant MAX_VEST_DURATION = 1_460 days;
    uint256 internal constant BPS = 10_000;

    address public immutable LAUNCH_FACTORY;
    /// The launch factory's default quote on the day this factory was deployed. A fill, its
    /// market and its collection settle in the quote its own launch names; this is the asset a
    /// reader that predates per-fill quotes expects, and `quoteOf` answers for one fill.
    address public immutable QUOTE;
    address public immutable FEE_TOKEN;
    address public immutable KEEPER;
    /// Whether native currency can pay in on this rail. It wraps into `FEE_TOKEN`, so the bond
    /// can always be paid that way here and a fill takes native deposits only when its quote is
    /// the fee token.
    bool public immutable NATIVE_WRAP;

    mapping(address creator => mapping(bytes32 dualFillKey => address fill)) public fillOf;
    mapping(address fill => bool) public isFill;
    address[] private _fills;

    constructor(address launchFactory, address keeper, bool nativeWrap) {
        if (launchFactory == address(0) || keeper == address(0)) revert ZeroAddress();
        if (launchFactory.code.length == 0) revert NotAContract();
        LAUNCH_FACTORY = launchFactory;
        KEEPER = keeper;
        NATIVE_WRAP = nativeWrap;
        QUOTE = TokenLaunchFactory(launchFactory).QUOTE();
        FEE_TOKEN = address(TokenLaunchFactory(launchFactory).FEE_TOKEN());
    }

    /// @notice The curve a combined launch declares for a minters' share of `nftAllocationBps`,
    ///         so that curve, pool position and share add up to exactly `TOTAL_SUPPLY`.
    function curveSupplyFor(uint96 nftAllocationBps) public pure returns (uint256) {
        return (TOTAL_SUPPLY * (BPS - nftAllocationBps)) / BPS - LP_SUPPLY;
    }

    /// @notice Deploy a fill for the caller's side of the combined Dual Fill `dualFillKey`,
    ///         funded with its launch bond. Pay the bond in `FEE_TOKEN` by approval, or in native
    ///         ETH on a wrap rail.
    function createFill(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        bytes32 dualFillKey,
        uint256 target,
        uint64 deadline,
        uint64 publicUntil,
        bool openAlone,
        uint256 feeBudget
    ) external payable nonReentrant returns (address fill) {
        if (dualFillKey == bytes32(0)) revert InvalidDualFillKey();
        if (fillOf[msg.sender][dualFillKey] != address(0)) revert FillExists();
        _checkWindows(deadline, publicUntil);
        if (openAlone) revert OpenAloneRefused();
        _checkCoupling(lp);
        IQuoteRegistry.QuoteEconomics memory e = _checkLaunch(tp, lp);
        _checkCollection(tp, np, lp, e.minPriceQuote);
        if (target == 0 || target > (tp.graduationQuote * MAX_FILL_BPS) / BPS) {
            revert InvalidTarget();
        }
        if (feeBudget < TokenLaunchFactory(LAUNCH_FACTORY).launchFee()) revert FeeBudgetTooLow();

        ILinkedDualFill.Init memory init = ILinkedDualFill.Init({
            launchFactory: LAUNCH_FACTORY,
            quote: tp.quote,
            feeToken: FEE_TOKEN,
            keeper: KEEPER,
            nativeWrap: NATIVE_WRAP,
            creator: msg.sender,
            dualFillKey: dualFillKey,
            target: target,
            deadline: deadline,
            publicUntil: publicUntil,
            openAlone: false,
            feeBudget: feeBudget,
            paramsHash: keccak256(abi.encode(tp, np, lp))
        });
        fill = LinkedDualFillDeployer.deploy(init);
        _fundBond(fill, feeBudget);

        fillOf[msg.sender][dualFillKey] = fill;
        isFill[fill] = true;
        _fills.push(fill);
        _announce(fill, init, tp, np, lp);
    }

    function fillCount() external view returns (uint256) {
        return _fills.length;
    }

    function fills(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _fills.length;
        if (offset >= total) return new address[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _fills[i];
        }
    }

    function quoteOf(address fill) external view returns (address) {
        return isFill[fill] ? ILinkedDualFill(payable(fill)).QUOTE() : address(0);
    }

    function _checkWindows(uint64 deadline, uint64 publicUntil) private view {
        uint256 nowTs = block.timestamp;
        if (
            deadline < nowTs + MIN_DURATION || deadline > nowTs + MAX_DURATION
                || publicUntil < nowTs + MIN_PUBLIC_WINDOW || publicUntil > deadline
        ) revert InvalidDeadline();
    }

    /// The minters' share is held to 5% so the curve keeps most of the supply, and the vest is
    /// the minting wallet's on a collection that can never grow a second wave.
    function _checkCoupling(LinkedParams calldata lp) private pure {
        if (
            lp.nftAllocationBps == 0 || lp.nftAllocationBps > MAX_NFT_ALLOCATION_BPS
                || lp.mintToCurveBps == 0 || lp.mintToCurveBps > BPS
                || lp.vestCliff > MAX_VEST_CLIFF || lp.vestDuration > MAX_VEST_DURATION
                || lp.objectClaim || lp.wavesOpen
        ) revert InvalidCoupling();
    }

    /// The launch `open` will create, held to the linked row and to the one identity both chains
    /// can carry. The curve is whatever leaves exactly `TOTAL_SUPPLY` once the launch factory has
    /// reserved the minters' share on top of curve and pool. The quote is named explicitly
    /// because the hash commits to it, a quote with no live row binds nothing and so admits no
    /// fill, and a row whose decimals are no longer the asset's own describes a market a power
    /// of ten off its size.
    function _checkLaunch(LaunchParams calldata tp, LinkedParams calldata lp)
        private
        view
        returns (IQuoteRegistry.QuoteEconomics memory e)
    {
        if (
            tp.curveSupply != curveSupplyFor(lp.nftAllocationBps) || tp.lpTokenSupply != LP_SUPPLY
                || tp.vTokenInit != V_TOKEN_INIT
        ) revert SupplyMismatch();
        if (tp.quote == address(0)) revert QuoteMismatch();

        address registry = TokenLaunchFactory(LAUNCH_FACTORY).quoteRegistry();
        if (registry == address(0) || !IQuoteRegistry(registry).approvedQuote(tp.quote)) {
            revert EconomicsMismatch();
        }
        e = IQuoteRegistry(registry).quoteEconomics(tp.quote);
        if (e.decimals != _decimalsOf(tp.quote)) revert QuoteDecimalsMismatch();
        if (tp.vQuoteInit != e.phantomQuote || tp.graduationQuote != e.graduationThreshold) {
            revert EconomicsMismatch();
        }

        if (
            tp.lpUnlockAt != 0 || tp.creatorTaxBps > MAX_CREATOR_TAX_BPS
                || !_within(tp.name, 1, MAX_NAME_BYTES) || !_within(tp.symbol, 1, MAX_SYMBOL_BYTES)
                || !_within(tp.logo, 1, MAX_URI_BYTES)
                || !_within(tp.description, 0, MAX_DESCRIPTION_BYTES)
                || !_within(tp.twitter, 0, MAX_SOCIAL_BYTES)
                || !_within(tp.telegram, 0, MAX_SOCIAL_BYTES)
                || !_within(tp.discord, 0, MAX_SOCIAL_BYTES)
                || !_within(tp.website, 0, MAX_SOCIAL_BYTES)
                || !_within(tp.farcaster, 0, MAX_SOCIAL_BYTES)
        ) revert InvalidParams();
    }

    /// The collection carries the launch's own name and symbol, settles in its quote, and is the
    /// one shape `open` can freeze: pre-generated pieces at a base URI with no placeholder. The
    /// last check is the one that sizes it: every piece sold routes at least the minters' share
    /// priced at the opening reserves.
    function _checkCollection(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        uint256 minPriceQuote
    ) private pure {
        if (
            np.quote != tp.quote || keccak256(bytes(np.name)) != keccak256(bytes(tp.name))
                || keccak256(bytes(np.symbol)) != keccak256(bytes(tp.symbol)) || np.maxSupply == 0
                || np.maxSupply > MAX_PIECES || np.perWalletCap > MAX_WALLET_CAP
                || np.startTime != 0 || np.endTime != 0 || np.mode != Mode.PREGEN
                || !_within(np.baseURI, 1, MAX_URI_BYTES) || bytes(np.placeholderURI).length != 0
                || np.royaltyBps > MAX_ROYALTY_BPS || np.priceQuote < minPriceQuote
                || Math.mulDiv(np.priceQuote, lp.mintToCurveBps, BPS) == 0
        ) revert InvalidCollection();

        uint256 mintersShare = (TOTAL_SUPPLY * lp.nftAllocationBps) / BPS;
        if (
            Math.mulDiv(np.priceQuote, np.maxSupply * lp.mintToCurveBps, BPS)
                < Math.mulDiv(mintersShare, tp.vQuoteInit, tp.vTokenInit)
        ) revert InvalidCollection();
    }

    /// The bond goes straight to the fill, and the fill's own balance is what is checked: it is
    /// what `open` pays the launch fee out of and what `returnFeeBudget` returns.
    function _fundBond(address fill, uint256 feeBudget) private {
        IERC20 feeToken = IERC20(FEE_TOKEN);
        uint256 before = feeToken.balanceOf(fill);
        if (msg.value == 0) {
            feeToken.safeTransferFrom(msg.sender, fill, feeBudget);
        } else {
            if (!NATIVE_WRAP || FEE_TOKEN != QUOTE) revert NativeUnsupported();
            if (msg.value != feeBudget) revert WrongPayment();
            IWETH9(FEE_TOKEN).deposit{ value: feeBudget }();
            feeToken.safeTransfer(fill, feeBudget);
        }
        if (feeToken.balanceOf(fill) != before + feeBudget) revert WrongPayment();
    }

    function _announce(
        address fill,
        ILinkedDualFill.Init memory init,
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp
    ) private {
        emit FillCreated(
            fill,
            init.creator,
            init.dualFillKey,
            init.target,
            init.deadline,
            init.publicUntil,
            init.openAlone,
            init.feeBudget,
            init.paramsHash,
            tp,
            np,
            lp
        );
    }

    /// An asset that will not say what its smallest unit means cannot be settled in, and the
    /// launch factory would refuse it at open under this same name.
    function _decimalsOf(address quote) private view returns (uint8) {
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            return d;
        } catch {
            revert QuoteDecimalsMismatch();
        }
    }

    function _within(string calldata value, uint256 min, uint256 max) private pure returns (bool) {
        uint256 length = bytes(value).length;
        return length >= min && length <= max;
    }
}
