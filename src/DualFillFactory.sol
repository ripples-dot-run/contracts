// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IWETH9 } from "./DualFill.sol";
import { LaunchParams, TokenLaunchFactory } from "./TokenLaunchFactory.sol";
import { IDualFill } from "./interfaces/IDualFill.sol";
import { IDualFillFactory } from "./interfaces/IDualFillFactory.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";
import { DualFillDeployer } from "./libraries/DualFillDeployer.sol";

/// @title DualFillFactory
/// @notice Deploys the Robinhood Chain side of every fill-first Dual Fill, and is the record of
///         which fills are real.
///
/// A fill is only worth joining if the contract holding the money is the one whose code was
/// reviewed and its terms are the ones the Dual Fill published, so both are settled here, before
/// any money arrives: the launch factory, its fee token and the keeper are fixed at construction,
/// and a fill's launch parameters are held to the approved row and committed to by hash.
/// `isFill` and `fillOf(creator, dualFillKey)` answer the rest in one read each.
///
/// A fill escrows the quote its launch names. The launch factory admits that asset against the
/// registry when the fill opens, and this factory applies the same admission when the fill is
/// created, so a side that takes deposits is one whose launch the row will accept: the asset has
/// a live row, its decimals are the row's, and the reserves are the row's standalone shape. The
/// bond stays in the fee token whatever the quote, because the launch fee does.
///
/// No owner, no fee and no setter. Rotating the keeper is a new factory, and fills already
/// created on this one run out under the keeper they were created with.
contract DualFillFactory is IDualFillFactory, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_FILL_BPS = 4_000;
    uint64 public constant MIN_DURATION = 10 minutes;
    uint64 public constant MAX_DURATION = 24 hours;
    uint64 public constant MIN_PUBLIC_WINDOW = 10 minutes;
    uint64 public constant OPEN_GRACE = 15 minutes;
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;
    uint256 public constant LP_SUPPLY = 219_000_000e18;
    uint256 public constant V_TOKEN_INIT = 1_073_000_000e18;
    uint96 public constant MAX_CREATOR_TAX_BPS = 1_000;
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 10;
    uint256 internal constant MAX_LOGO_BYTES = 512;
    uint256 internal constant MAX_DESCRIPTION_BYTES = 2_048;
    uint256 internal constant MAX_SOCIAL_BYTES = 256;
    uint256 internal constant BPS = 10_000;

    address public immutable LAUNCH_FACTORY;
    /// The launch factory's default quote on the day this factory was deployed. A fill settles
    /// in the quote its own launch names; this is the asset a reader that predates per-fill
    /// quotes expects, and `quoteOf` answers for one fill.
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

    /// @notice Deploy a fill for the caller's side of the Dual Fill `dualFillKey`, funded with its
    ///         launch bond. Pay the bond in `FEE_TOKEN` by approval, or in native ETH on a wrap
    ///         rail. The fill escrows `p.quote`, which has to be named and admitted.
    /// @dev The launch is held here to the supplies, the row and the identity limits the launch
    ///      factory will accept, so a fill that takes deposits can open. The launch factory's
    ///      owner can still raise the fee past the bond, restate the row or revoke the quote;
    ///      each makes `open` revert, and the side refunds after its grace like any side that
    ///      did not open.
    function createFill(
        LaunchParams calldata p,
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
        _checkParams(p);
        if (target == 0 || target > (p.graduationQuote * MAX_FILL_BPS) / BPS) {
            revert InvalidTarget();
        }
        if (feeBudget < TokenLaunchFactory(LAUNCH_FACTORY).launchFee()) revert FeeBudgetTooLow();

        IDualFill.Init memory init = IDualFill.Init({
            launchFactory: LAUNCH_FACTORY,
            quote: p.quote,
            feeToken: FEE_TOKEN,
            keeper: KEEPER,
            nativeWrap: NATIVE_WRAP,
            creator: msg.sender,
            dualFillKey: dualFillKey,
            target: target,
            deadline: deadline,
            publicUntil: publicUntil,
            openAlone: openAlone,
            feeBudget: feeBudget,
            paramsHash: keccak256(abi.encode(p))
        });
        fill = DualFillDeployer.deploy(init);
        _fundBond(fill, feeBudget);

        fillOf[msg.sender][dualFillKey] = fill;
        isFill[fill] = true;
        _fills.push(fill);
        _announce(fill, init, p);
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
        return isFill[fill] ? IDualFill(fill).QUOTE() : address(0);
    }

    function _checkWindows(uint64 deadline, uint64 publicUntil) private view {
        uint256 nowTs = block.timestamp;
        if (
            deadline < nowTs + MIN_DURATION || deadline > nowTs + MAX_DURATION
                || publicUntil < nowTs + MIN_PUBLIC_WINDOW || publicUntil > deadline
        ) revert InvalidDeadline();
    }

    /// The launch `open` will create, held to what the launch factory would accept from it and
    /// to the one identity both chains can carry. The quote is named explicitly because the hash
    /// commits to it: `address(0)` would mean whatever the registry's default is on the day the
    /// fill opens. A quote with no live row binds nothing, so it admits no fill, and a row whose
    /// decimals are no longer the asset's own describes a market a power of ten off its size.
    function _checkParams(LaunchParams calldata p) private view {
        if (
            p.curveSupply != CURVE_SUPPLY || p.lpTokenSupply != LP_SUPPLY
                || p.vTokenInit != V_TOKEN_INIT
        ) revert SupplyMismatch();
        if (p.quote == address(0)) revert QuoteMismatch();

        address registry = TokenLaunchFactory(LAUNCH_FACTORY).quoteRegistry();
        if (registry == address(0) || !IQuoteRegistry(registry).approvedQuote(p.quote)) {
            revert EconomicsMismatch();
        }
        IQuoteRegistry.QuoteEconomics memory e = IQuoteRegistry(registry).quoteEconomics(p.quote);
        if (e.decimals != _decimalsOf(p.quote)) revert QuoteDecimalsMismatch();
        if (p.vQuoteInit != e.standalonePhantomQuote || p.graduationQuote != e.graduationThreshold)
        {
            revert EconomicsMismatch();
        }

        if (
            p.lpUnlockAt != 0 || p.creatorTaxBps > MAX_CREATOR_TAX_BPS
                || !_within(p.name, 1, MAX_NAME_BYTES) || !_within(p.symbol, 1, MAX_SYMBOL_BYTES)
                || !_within(p.logo, 1, MAX_LOGO_BYTES)
                || !_within(p.description, 0, MAX_DESCRIPTION_BYTES)
                || !_within(p.twitter, 0, MAX_SOCIAL_BYTES)
                || !_within(p.telegram, 0, MAX_SOCIAL_BYTES)
                || !_within(p.discord, 0, MAX_SOCIAL_BYTES)
                || !_within(p.website, 0, MAX_SOCIAL_BYTES)
                || !_within(p.farcaster, 0, MAX_SOCIAL_BYTES)
        ) revert InvalidParams();
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

    function _announce(address fill, IDualFill.Init memory init, LaunchParams calldata p) private {
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
            p
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
