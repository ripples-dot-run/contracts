// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CollectionParams } from "./Collection721.sol";
import { CollectionDeployer } from "./libraries/CollectionDeployer.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";

/// @notice Registry and deployer for drops. Creators pay the launch fee directly in the quote
///         token. Collections are deployed outright rather than cloned so every one of them
///         verifies on Blockscout with no proxy indirection.
///
///         **This factory's admin events share topic0 with the token factory's.** `TreasurySet`,
///         `PlatformSignerSet`, `FeePassConsumed`, `LaunchFeeSet`, `QuoteRegistrySet`,
///         `FeesWithdrawn` and the `Ownable2Step` pair are byte-identical signatures on
///         `TokenLaunchFactory`, so a scanner keyed on topic0 alone will file a treasury rotation
///         on one rail as a rotation on the other. There are two deployed factories on every
///         chain and they are rotated separately, so an indexer has to filter on the emitting
///         address as well. `LaunchpadFactory.t.sol` pins the collision rather than leaving it to
///         be discovered. Nothing here touches a launch: a linked drop is deployed by
///         `TokenLaunchFactory`, and this factory deploys standalone drops only.
contract LaunchpadFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint96 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    /// Ceiling on what a drop listed here can charge on secondary sales.
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    /// Ceiling on the launch **fee**, which is charged in the fee token (WETH) and is
    /// independent of whatever a drop is priced in. 0.1 WETH, so a fee change between a
    /// creator's approve and their launch can never pull more than that from an outstanding
    /// allowance. It is an 18-decimal figure because the fee token is 18-decimal; a drop priced
    /// in a 6- or 8-decimal quote does not move it (DQ3).
    uint256 public constant MAX_LAUNCH_FEE = 1e17;
    uint256 public constant MAX_ASSET_ORIGIN_BYTES = 128;

    /// The **fee** token, fixed for the life of this factory, and the default quote a drop
    /// settles in when its `CollectionParams.quote` is `address(0)`. It is not "the asset every
    /// drop is priced in" any more: read `Collection721.QUOTE()` for that. The name is kept
    /// because `QUOTE()` is deployed and read by the app, the keeper and the integration ABIs;
    /// `feeToken()` is the same address under the name that now describes it.
    IERC20 public immutable QUOTE;

    address public treasury;
    address public platformSigner;
    /// Each token of this ERC-721 waives one launch fee. Unset disables the waiver.
    address public feePassCollection;
    /// Origin serving the collection-level documents (ERC-7572), with no trailing slash. A
    /// collection reads it once at creation and keeps what it was born with, so changing it
    /// moves later drops only.
    string public assetOrigin;
    /// In the fee token (WETH), independent of a drop's quote.
    uint256 public launchFee = 5e14; // 0.0005 WETH
    uint96 public defaultProtocolFeeBps = 250;

    /// The asset allowlist both rails share, read at **create only** and never afterwards, so
    /// revoking a quote closes the door on new drops and can never reach one already trading
    /// (DQ1). Unset means closed: a drop may then only be created against the default quote.
    ///
    /// **A recorded deviation from the package task, which asked for
    /// `IQuoteRegistry public immutable QUOTE_REGISTRY`.** An immutable has to arrive as a
    /// constructor argument, and this constructor's four-argument signature is read by
    /// `script/Deploy.s.sol`, `script/verify.sh` and `test/StockLinkRegistry.t.sol`, none of
    /// which this package owns. Both factories therefore take the registry through an
    /// owner-only setter, `TokenLaunchFactory` included, so the two rails keep one shape and
    /// neither constructor's deployed bytecode or verify string changes. The read name
    /// `quoteRegistry()` is the frozen one either way (interfaces §2.3).
    ///
    /// What the setter costs, and how it is paid: the pointer stays mutable after the ownership
    /// handoff, and a factory deployed but not yet wired will refuse every named quote with
    /// `QuoteNotApproved` while the default still works. So `setQuoteRegistry` belongs in the
    /// **same pre-handoff window** as `setAssetOrigin` and `setGraduationHook` (deploy the
    /// registry, wire both factories, then transfer ownership), and `setQuoteRegistry(address)`
    /// plus `QuoteRegistrySet` have to appear in the frozen factory abis and in verify.sh.
    /// Both are filed as interface requests against RH-DEPLOY and IFACE-FREEZE.
    address public quoteRegistry;

    address[] public allCollections;
    mapping(address collection => bool) public isFromFactory;
    /// Scoped to the pass contract, so repointing `feePassCollection` cannot carry a spent
    /// flag onto a token of the same id in a different pass.
    mapping(address passCollection => mapping(uint256 passTokenId => bool)) public passConsumed;

    event CollectionCreated(
        address indexed creator, address indexed collection, CollectionParams p
    );
    event TreasurySet(address indexed treasury);
    event PlatformSignerSet(address indexed signer);
    event FeePassCollectionSet(address indexed collection);
    event AssetOriginSet(string origin);
    event FeePassConsumed(uint256 indexed passTokenId, address indexed creator);
    event LaunchFeeSet(uint256 fee);
    event QuoteRegistrySet(address indexed registry);
    /// A sweep of some asset other than the fee token, which the no-argument `withdrawFees`
    /// cannot name. Separate from `FeesWithdrawn` so that event keeps its deployed shape.
    event TokenFeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event DefaultProtocolFeeSet(uint96 bps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    /// A registry whose default quote is not this factory's own, so `address(0)` would mean
    /// two assets across the two rails that share it.
    error QuoteMismatch();
    error NotAContract();
    error FeeTooHigh();
    error RoyaltyTooHigh();
    error NoFeePass();
    error InvalidAssetOrigin();
    error FeePassConsumedAlready();
    error NothingToWithdraw();
    error WrongPayment();
    /// The named quote is not on the shared registry's list, or no registry is wired yet.
    error QuoteNotApproved();
    /// `priceQuote` is below the registry's floor for the chosen quote. Reserved for the price;
    /// the two curve reserves are the token rail's and are `QuoteEconomicsMismatch`.
    error PriceOutOfRange();
    /// Declared so every reader decoding a revert from either rail against the shared error
    /// table names it. Both belong to the registry and the token rail's reserves; the NFT rail
    /// has no reserves to mismatch and never raises them.
    error QuoteEconomicsMismatch();
    error QuoteDecimalsMismatch();

    constructor(address quote, address treasury_, address platformSigner_, address owner_)
        Ownable(owner_)
    {
        if (quote == address(0) || treasury_ == address(0) || platformSigner_ == address(0)) {
            revert ZeroAddress();
        }
        if (quote.code.length == 0) revert NotAContract();
        QUOTE = IERC20(quote);
        treasury = treasury_;
        platformSigner = platformSigner_;
    }

    function createCollection(CollectionParams calldata p) external nonReentrant returns (address) {
        uint256 fee = launchFee;
        if (fee != 0) _pullExact(msg.sender, fee);
        return _deploy(msg.sender, p);
    }

    /// @notice Launch against a fee pass the caller holds. Each pass token waives one
    ///         launch fee, so passing it on hands over a benefit that has been used.
    function createCollectionWithPass(uint256 passTokenId, CollectionParams calldata p)
        external
        nonReentrant
        returns (address)
    {
        if (!ownsPass(msg.sender, passTokenId)) revert NoFeePass();
        address pass = feePassCollection;
        if (passConsumed[pass][passTokenId]) revert FeePassConsumedAlready();
        passConsumed[pass][passTokenId] = true;
        emit FeePassConsumed(passTokenId, msg.sender);
        return _deploy(msg.sender, p);
    }

    /// @notice Sweep the launch fees. The fee is always in the fee token, so this is the sweep
    ///         the runbook uses; `withdrawFees(address)` exists for a residue in anything else.
    function withdrawFees() external nonReentrant {
        uint256 amount = QUOTE.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        _transferExact(QUOTE, treasury, amount);
        emit FeesWithdrawn(treasury, amount);
    }

    /// @notice Sweep one named asset to the treasury. With per-drop quotes this factory can end
    ///         up holding something other than the fee token (a mis-sent transfer, or a refund
    ///         from a create that was rolled back), and the no-argument sweep only ever reaches
    ///         WETH. Per token, so one paused asset or one issuer hold cannot stall the others.
    ///
    ///         Naming the fee token here is the same sweep as the no-argument one and reports
    ///         under the same topic: the topic follows the asset, not the entry point. Without
    ///         that, anyone could sweep launch-fee revenue under the residue topic and a revenue
    ///         reader keyed on `FeesWithdrawn` would count it as nothing.
    function withdrawFees(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        IERC20 asset = IERC20(token);
        uint256 amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        address to = treasury;
        _transferExact(asset, to, amount);
        if (token == address(QUOTE)) {
            emit FeesWithdrawn(to, amount);
        } else {
            emit TokenFeesWithdrawn(token, to, amount);
        }
    }

    /// @notice Refused. `Ownable2Step` exists so a handover cannot strand this contract, and a
    ///         renounce is the one door that leaves open: every owner-only setting would be gone
    ///         for good while creating launches kept working, so the break would stay invisible
    ///         until the first treasury rotation.
    function renounceOwnership() public pure override {
        revert();
    }

    /// @notice Point the factory at the shared quote registry. Read at create only, so this
    ///         never reaches a drop that already exists: a drop keeps the quote it was born
    ///         with even after that asset is revoked.
    ///
    ///         Call this in the deployment's pre-handoff window, beside `setAssetOrigin`: until
    ///         it is called, `quoteRegistry` is zero and every `createCollection` naming a quote
    ///         reverts `QuoteNotApproved`, leaving only the default quote usable. Zero is
    ///         accepted deliberately, as the switch that closes the door on new named quotes
    ///         without touching a drop that already trades.
    function setQuoteRegistry(address registry) external onlyOwner {
        if (registry != address(0) && registry.code.length == 0) revert NotAContract();
        // `address(0)` in a drop means this factory's own quote, and on the token rail it means
        // the registry's default. The two rails share one registry, so the two meanings have to
        // be one asset, or the same zero would settle in two assets depending on the entry point.
        if (registry != address(0) && IQuoteRegistry(registry).defaultQuote() != address(QUOTE)) {
            revert QuoteMismatch();
        }
        quoteRegistry = registry;
        emit QuoteRegistrySet(registry);
    }

    /// The asset the launch fee is charged in. Fixed, and independent of what a drop settles in:
    /// a creator launching a stock-priced drop approves two assets, with distinct captions.
    function feeToken() external view returns (address) {
        return address(QUOTE);
    }

    /// A pass contract that reverts or returns nothing reads as "no pass" rather than
    /// taking the launch flow down with it.
    function hasFeePass(address account) public view returns (bool) {
        address pass = feePassCollection;
        if (pass == address(0)) return false;
        try IERC721(pass).balanceOf(account) returns (uint256 balance) {
            return balance != 0;
        } catch {
            return false;
        }
    }

    function ownsPass(address account, uint256 passTokenId) public view returns (bool) {
        address pass = feePassCollection;
        if (pass == address(0)) return false;
        try IERC721(pass).ownerOf(passTokenId) returns (address holder) {
            return holder == account;
        } catch {
            return false;
        }
    }

    function collectionCount() external view returns (uint256) {
        return allCollections.length;
    }

    function collections(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = allCollections.length;
        if (offset >= total) return new address[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = allCollections[i];
        }
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setPlatformSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        platformSigner = signer;
        emit PlatformSignerSet(signer);
    }

    /// @notice Point later collections' ERC-7572 document at an origin. Empty publishes none.
    ///         A collection keeps the origin it was born with, so the shape is checked here
    ///         rather than left to be discovered on a marketplace: an HTTPS origin, no trailing
    ///         slash, because the collection appends its own path to it.
    function setAssetOrigin(string calldata origin) external onlyOwner {
        if (!_validAssetOrigin(origin)) revert InvalidAssetOrigin();
        assetOrigin = origin;
        emit AssetOriginSet(origin);
    }

    function _validAssetOrigin(string calldata origin) private pure returns (bool) {
        bytes calldata raw = bytes(origin);
        if (raw.length == 0) return true;
        if (raw.length > MAX_ASSET_ORIGIN_BYTES) return false;
        bytes memory scheme = "https://";
        if (raw.length <= scheme.length) return false;
        for (uint256 i = 0; i < scheme.length; i++) {
            if (raw[i] != scheme[i]) return false;
        }
        return raw[raw.length - 1] != "/";
    }

    function setFeePassCollection(address collection) external onlyOwner {
        if (collection != address(0) && collection.code.length == 0) revert NotAContract();
        feePassCollection = collection;
        emit FeePassCollectionSet(collection);
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        if (fee > MAX_LAUNCH_FEE) revert FeeTooHigh();
        launchFee = fee;
        emit LaunchFeeSet(fee);
    }

    function setDefaultProtocolFeeBps(uint96 bps) external onlyOwner {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        defaultProtocolFeeBps = bps;
        emit DefaultProtocolFeeSet(bps);
    }

    /// Both create entrypoints land here, so the pass path, which pulls no fee and is the one
    /// create that touches no ERC-20, is checked exactly as the paying one is.
    function _deploy(address creator, CollectionParams calldata p) private returns (address) {
        if (p.royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        // Copied to memory to resolve the quote, which the deployer library needs in memory
        // anyway. The event then carries the resolved address rather than the caller's zero, so
        // an indexer never has to know this factory's default to know what a drop settles in.
        CollectionParams memory np = p;
        np.quote = _resolveQuote(p.quote, p.priceQuote);
        // The collection's creation code lives in the deployer library, delegatecalled so it
        // still deploys from this factory: the collection reads this address as its factory,
        // exactly as an inline `new` would, and the factory stays well under the EIP-170 limit.
        address collection = CollectionDeployer.deploy(
            np, creator, defaultProtocolFeeBps, np.quote, treasury, platformSigner
        );
        allCollections.push(collection);
        isFromFactory[collection] = true;
        emit CollectionCreated(creator, collection, np);
        return collection;
    }

    /// `address(0)` is the factory's default quote and keeps every caller that predates this
    /// field correct without a change; it is never looked up, because it is not a quote the
    /// registry holds a row for. Any named asset is checked against the registry, and its price
    /// against that row's floor. The registry is never read again after this call.
    ///
    /// `priceQuote` is a floor, not an equality (DQ1 as amended): a mint price is a creator's
    /// choice within a band, and the exact-equality rule is for the two curve reserves on the
    /// token rail. The floor is what stops a 6-decimal drop being priced at dust.
    ///
    /// It is only the first half of §2.1's price rule. The second, `priceQuote *
    /// mintToCurveBps / 10_000 >= 1`, cannot be checked here, because `mintToCurveBps` is not
    /// in `CollectionParams`: it arrives later, at `linkToCurve`, from the token rail's
    /// `LinkedParams`. So it lives in `Collection721.linkToCurve`, the one place that sees both
    /// numbers, and reverts the same `PriceOutOfRange()`. A standalone drop has no routing and
    /// no second half to satisfy.
    function _resolveQuote(address quote, uint256 priceQuote) private view returns (address) {
        if (quote == address(0)) return address(QUOTE);
        IQuoteRegistry registry = IQuoteRegistry(quoteRegistry);
        if (address(registry) == address(0)) revert QuoteNotApproved();
        if (!registry.approvedQuote(quote)) revert QuoteNotApproved();
        if (priceQuote < registry.quoteEconomics(quote).minPriceQuote) revert PriceOutOfRange();
        return quote;
    }

    function _pullExact(address from, uint256 amount) private {
        uint256 fromBefore = QUOTE.balanceOf(from);
        uint256 balanceBefore = QUOTE.balanceOf(address(this));
        QUOTE.safeTransferFrom(from, address(this), amount);
        uint256 fromAfter = QUOTE.balanceOf(from);
        uint256 balanceAfter = QUOTE.balanceOf(address(this));
        if (
            fromAfter > fromBefore || fromBefore - fromAfter != amount
                || balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount
        ) revert WrongPayment();
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private {
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 toBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 toAfter = token.balanceOf(to);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || toAfter < toBefore || toAfter - toBefore != amount
        ) revert WrongPayment();
    }
}
