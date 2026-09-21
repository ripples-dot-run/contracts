// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// PREGEN drops ship a finished `baseURI`; LIVE drops mint against a placeholder and
/// are revealed one token at a time as generation completes.
enum Mode {
    PREGEN,
    LIVE
}

struct CollectionParams {
    string name;
    string symbol;
    uint256 priceQuote;
    uint256 maxSupply;
    uint256 perWalletCap;
    uint64 startTime;
    uint64 endTime;
    Mode mode;
    string baseURI;
    string placeholderURI;
    uint96 royaltyBps;
    /// The asset this drop is priced and settled in, **appended** so a caller that builds the
    /// eleven-field tuple keeps working. `address(0)` means the deploying factory's default
    /// quote, which is what every drop created before this field was born settles in. The
    /// factory resolves it, checks it against the shared `IQuoteRegistry` and hands the
    /// resolved address to the constructor; nothing re-reads the registry afterwards, so
    /// revoking a quote closes the door on new drops and never reaches a live one.
    /// `docs/plans/stock-pairing/02-decisions.md` DQ1/DQ2.
    address quote;
}

/// The deploying factory, read at withdrawal and rotation time so admin changes there
/// reach drops that are already live, and once at creation for the collection-document origin.
interface ILaunchpad {
    function owner() external view returns (address);
    function treasury() external view returns (address);
    function assetOrigin() external view returns (string memory);
}

/// The bonding curve a linked collection funds. `contribute` pulls the routed quote under the
/// curve's own balance-delta guard; `graduated` lets a mint fall back to plain revenue once
/// the curve has closed.
interface ICurveSink {
    function contribute(uint256 quoteIn) external;
    /// The asset the curve settles in. `linkToCurve` refuses a curve that does not agree with
    /// this collection's, because a linked launch is one market in one asset: a collection
    /// priced in a stock token wired to a WETH curve would approve one asset while `contribute`
    /// pulled another, and every linked mint would revert on the delta guard, for good.
    function QUOTE() external view returns (address);
    function graduated() external view returns (bool);
    function GRADUATION_QUOTE() external view returns (uint256);
    function realQuote() external view returns (uint256);
}

interface IAllocationRecorder {
    function recordContribution(address minter, uint256 amount) external;
}

/// The same credit, for a launch whose claim belongs to the piece. The ids do not exist yet
/// when a mint routes, so the range the mint is about to issue is passed instead of read.
interface IObjectRecorder {
    function recordContribution(uint256 startId, uint256 qty, uint256 amount) external;
}

/// @notice A single drop. Collectors approve the quote token and mint directly. Revenue is
///         split creator/protocol on withdrawal, and only quote pulled by a mint is splittable.
contract Collection721 is ERC721, ERC2981, Ownable2Step, ReentrancyGuard, IPullEscrow {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    uint256 public constant MAX_MINT_PER_TX = 20;
    uint96 public constant BPS_DENOMINATOR = 10_000;

    IERC20 public immutable QUOTE;
    /// The quote's own decimals, read once at construction and never again (DQ5). Every amount
    /// this contract holds is in raw units of that asset; this is the anchor that makes a bare
    /// integer mean something to a reader, and it cannot drift because the asset cannot change.
    /// A quote that does not answer `decimals()` is recorded as 18, the ERC-20 default.
    uint8 public immutable QUOTE_DECIMALS;
    address public immutable FACTORY;
    address public immutable CREATOR;
    /// Payout address at deployment. `treasury()` prefers the factory's current one.
    address public immutable TREASURY;
    uint256 public immutable PRICE_QUOTE;
    uint256 public immutable MAX_SUPPLY;
    uint256 public immutable PER_WALLET_CAP;
    uint64 public immutable START_TIME;
    uint64 public immutable END_TIME;
    uint96 public immutable PROTOCOL_FEE_BPS;
    Mode public immutable MODE;

    /// Rotatable by the platform itself, or by the factory owner if the signer key is lost or
    /// taken. Its only content privilege is one-shot reveal of LIVE tokens.
    address public platformSigner;

    string public baseURI;
    string public placeholderURI;
    /// ERC-7572: the collection-level document marketplaces read for the collection's own page,
    /// as opposed to any token's artwork. Set at creation from the deploying factory's origin
    /// and movable by the owner afterwards, including once the artwork is frozen.
    string public contractURI;
    bool public metadataFrozen;

    /// Linked-launch wiring, set once by the factory for a linked collection and zero for
    /// every standalone drop. When `curveSink` is zero the mint paths behave exactly as a
    /// standalone drop; when it is set, `mintToCurveBps` of each mint's quote is routed into
    /// the curve and recorded on `allocationVesting` before the rest becomes revenue.
    address public curveSink;
    address public allocationVesting;
    uint96 public mintToCurveBps;
    /// Whether the routed quote is credited to the piece rather than to the minter's wallet.
    /// Set with the link, and read on every mint to pick which recorder is called.
    bool public objectClaim;

    uint256 public totalSupply;
    mapping(address minter => uint256) public mintedBy;
    mapping(uint256 tokenId => string) private _tokenURIs;

    /// Quote a mint has claimed, at `PRICE_QUOTE` per token. Anything that lands here
    /// beyond this figure is an unmatched settlement, not revenue.
    uint256 public attributedReceipts;
    uint256 public creatorWithdrawn;
    uint256 public protocolWithdrawn;

    event Minted(address indexed to, uint256 indexed tokenId);
    event LinkedToCurve(
        address indexed curve, address indexed vesting, uint96 mintToCurveBps, bool objectClaim
    );
    event Revealed(uint256 indexed tokenId, string uri);
    event BaseURISet(string uri);
    event ContractURIUpdated();
    event PlaceholderURISet(string uri);
    event MetadataFrozen();
    event PlatformSignerSet(address indexed signer);
    event CreatorWithdrawal(address indexed to, uint256 amount);
    event ProtocolWithdrawal(address indexed to, uint256 amount);
    event UnattributedRecovered(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroSupply();
    error InvalidWindow();
    error InvalidQuantity();
    error NotStarted();
    error Ended();
    error SupplyExceeded();
    error WalletCapExceeded();
    error WrongPayment();
    error FeeTooHigh();
    error NotPlatformSigner();
    error NotTokenOwner();
    error NotRevealable();
    error AlreadyRevealed();
    error MetadataLocked();
    error EmptyURI();
    error NothingToWithdraw();
    error NotFactory();
    error NotAContract();
    error AlreadyLinked();
    error SlippageExceeded();
    /// The curve offered to `linkToCurve` settles in a different asset than this collection.
    error QuoteMismatch();
    /// The second half of the create-time price rule (interfaces §2.1, DQ1): a linked drop
    /// whose `PRICE_QUOTE * mintToCurveBps / 10_000` floors to zero. The factory holds
    /// `priceQuote` to the registry's floor for the chosen quote; this is the other bound, and
    /// it can only be checked where both numbers are known, which is here.
    error PriceOutOfRange();

    constructor(
        CollectionParams memory p,
        address creator,
        uint96 protocolFeeBps,
        address quote,
        address treasury_,
        address platformSigner_
    ) ERC721(p.name, p.symbol) Ownable(creator) {
        if (creator == address(0) || quote == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (quote.code.length == 0) revert NotAContract();
        if (platformSigner_ == address(0)) revert ZeroAddress();
        if (p.maxSupply == 0) revert ZeroSupply();
        if (protocolFeeBps > BPS_DENOMINATOR) revert FeeTooHigh();
        if (p.mode == Mode.LIVE && bytes(p.placeholderURI).length == 0) revert EmptyURI();

        uint64 start = p.startTime == 0 ? uint64(block.timestamp) : p.startTime;
        // The window has to be open after this block, not merely well ordered: a backdated start
        // with an equally past end would deploy a drop that charges its launch fee and then
        // refuses every mint.
        if (p.endTime != 0 && (p.endTime <= start || p.endTime <= block.timestamp)) {
            revert InvalidWindow();
        }

        QUOTE = IERC20(quote);
        QUOTE_DECIMALS = _quoteDecimals(quote);
        FACTORY = msg.sender;
        CREATOR = creator;
        TREASURY = treasury_;
        PRICE_QUOTE = p.priceQuote;
        MAX_SUPPLY = p.maxSupply;
        PER_WALLET_CAP = p.perWalletCap;
        START_TIME = start;
        END_TIME = p.endTime;
        PROTOCOL_FEE_BPS = protocolFeeBps;
        MODE = p.mode;
        platformSigner = platformSigner_;
        baseURI = p.baseURI;
        placeholderURI = p.placeholderURI;
        contractURI = _initialContractURI();

        _setDefaultRoyalty(creator, p.royaltyBps);
    }

    /// @notice Wire this collection to its launch's bonding curve, once, at deploy time. Only
    ///         the deploying factory can call, and every existing standalone drop leaves this
    ///         unset, so their mint paths are unchanged. `mintToCurveBps` of each mint's quote
    ///         is then routed into the curve and recorded for the vested allocation.
    ///
    ///         `objectClaim_` picks which vesting contract is on the other end and therefore
    ///         who the allocation belongs to: the wallet that minted, or the piece it minted.
    ///         The launch declares it at create, it is wired here once, and no call moves it.
    function linkToCurve(
        address curveSink_,
        address vesting_,
        uint96 mintToCurveBps_,
        bool objectClaim_
    ) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (curveSink != address(0)) revert AlreadyLinked();
        if (curveSink_ == address(0) || vesting_ == address(0)) revert ZeroAddress();
        if (curveSink_.code.length == 0 || vesting_.code.length == 0) revert NotAContract();
        if (mintToCurveBps_ > BPS_DENOMINATOR) revert FeeTooHigh();
        // A price and a routing share that floor to nothing together would make the link a lie:
        // `_settle` routes `mulDiv(due, mintToCurveBps, 10_000)`, so at one raw unit of a
        // 6-decimal quote and 2_000 bps every mint routes zero. The curve is never funded, no
        // minter accrues a vested allocation, and the launch can never graduate on mint revenue,
        // while the creator keeps the whole price. The link is one-shot, so this is refused at
        // wiring rather than degrading silently for the life of the drop. Rounding *within* a
        // multi-token mint is still fine and still conserves; only a drop that can never route a
        // single unit is rejected.
        if (Math.mulDiv(PRICE_QUOTE, mintToCurveBps_, BPS_DENOMINATOR) == 0) {
            revert PriceOutOfRange();
        }
        // One market, one asset. Today a linked launch is wired by a factory that hands the same
        // resolved quote to the curve and to the collection, so this can only fire on a wiring
        // mistake, which is exactly when it is worth having, because the link is one-shot.
        if (ICurveSink(curveSink_).QUOTE() != address(QUOTE)) revert QuoteMismatch();
        curveSink = curveSink_;
        allocationVesting = vesting_;
        mintToCurveBps = mintToCurveBps_;
        objectClaim = objectClaim_;
        emit LinkedToCurve(curveSink_, vesting_, mintToCurveBps_, objectClaim_);
    }

    /// @notice Mint by approving the quote first. Credits only the quote the balance actually
    ///         rises by, so a token that reports success without moving funds mints nothing.
    ///         `minRoutedTotal` is the floor on quote routed into the linked curve. Graduation is
    ///         permissionless and the routed amount is capped by what the curve still needs, so
    ///         without a floor a mint can land after either and silently buy no allocation.
    function mint(uint256 qty, uint256 minRoutedTotal) external nonReentrant {
        _checkWindow(msg.sender, qty);
        // Named `due` rather than `owed`: `owed(address,address)` is this contract's pull-escrow
        // read, and a local of the same name would shadow the function.
        uint256 due = PRICE_QUOTE * qty;
        uint256 routed;
        if (due != 0) {
            _pullExact(msg.sender, due);
            routed = _attribute(msg.sender, due, qty);
        }
        if (routed < minRoutedTotal) revert SlippageExceeded();
        _issue(msg.sender, qty);
    }

    function creatorWithdraw() external nonReentrant {
        if (_creatorWithdraw() == 0) revert NothingToWithdraw();
    }

    function protocolWithdraw() external nonReentrant {
        if (_protocolWithdraw() == 0) revert NothingToWithdraw();
    }

    // IPullEscrow, as adapters over the share accounting above.
    //
    // There is no second ledger here and no push fallback, deliberately (DQ4 as amended).
    // `attributedReceipts` / `creatorWithdrawn` / `protocolWithdrawn` / `_claimable` already are
    // a pull escrow: each side's claim is derived from the live balance, a blocked recipient's
    // withdraw reverts inside the token and their money stays claimable, and neither side can
    // reach the other's share. A `mapping(token => account => uint256)` beside a balance-derived
    // split would double-count every mint and would let `recoverUnattributed` hand the creator
    // the treasury's cut. So `owed` answers from the split, and `claim` / `claimFor` are the
    // existing withdrawals under the shared vocabulary.
    //
    // Only `QUOTE` is ever owed. Anything else that reaches this address is not revenue and is
    // not escrowed either; it is recovered to the creator by `recoverUnattributed`, which stays
    // a plain push to a fixed recipient.
    //
    // One consequence for indexers, and it is the asymmetry the adapters buy: **this collection
    // never emits `Credited`.** It inherits the event from `IPullEscrow` so the ABI carries it,
    // but there is no moment at which money is "recorded": `owed` is derived from the live
    // balance on every read, so a mint credits both sides implicitly. `Claimed` *is* emitted, by
    // `_creatorWithdraw` and `_protocolWithdraw`. An indexer that totals
    // `sum(Credited) - sum(Claimed)` here reads zero owed on every collection and goes negative
    // after the first claim; read `owed(QUOTE, account)` and `totalOwed(QUOTE)` live instead.

    /// @inheritdoc IPullEscrow
    function owed(address token, address account) public view returns (uint256 amount) {
        if (token != address(QUOTE)) return 0;
        // Written as two independent tests rather than an if/else so a deployment whose creator
        // *is* the treasury is owed both halves rather than silently half of what it holds.
        if (account == CREATOR) amount = creatorClaimable();
        if (account == treasury()) amount += protocolClaimable();
    }

    /// @inheritdoc IPullEscrow
    function totalOwed(address token) public view returns (uint256) {
        if (token != address(QUOTE)) return 0;
        return creatorClaimable() + protocolClaimable();
    }

    /// @inheritdoc IPullEscrow
    function claim(address token) external nonReentrant returns (uint256 amount) {
        return _claimTo(token, msg.sender);
    }

    /// @inheritdoc IPullEscrow
    function claimFor(address token, address account) external nonReentrant returns (uint256) {
        return _claimTo(token, account);
    }

    /// @notice Move quote sent outside `mint` to the immutable creator. Anyone may clear it,
    ///         but the recipient is fixed and the bound excludes creator/protocol revenue.
    function recoverUnattributed() external nonReentrant returns (uint256 amount) {
        amount = unattributedBalance();
        if (amount == 0) revert NothingToWithdraw();
        _transferExact(CREATOR, amount);
        emit UnattributedRecovered(CREATOR, amount);
    }

    /// Quote still held plus mint revenue already paid out. Recovered unmatched transfers are
    /// intentionally excluded so they cannot be swept twice into attributed revenue.
    function receiptsSettled() public view returns (uint256) {
        return QUOTE.balanceOf(address(this)) + creatorWithdrawn + protocolWithdrawn;
    }

    /// The splittable part of that: quote a mint has claimed. A settlement that arrives
    /// before its mint is counted the moment the mint lands, and never before.
    function lifetimeReceipts() public view returns (uint256) {
        uint256 settled = receiptsSettled();
        uint256 attributed = attributedReceipts;
        return settled < attributed ? settled : attributed;
    }

    /// Quote sent directly to this contract without a mint. It is never treated as revenue.
    function unattributedBalance() public view returns (uint256) {
        uint256 unmatched = receiptsSettled() - lifetimeReceipts();
        uint256 balance = QUOTE.balanceOf(address(this));
        return unmatched < balance ? unmatched : balance;
    }

    function protocolShare() public view returns (uint256) {
        return Math.mulDiv(lifetimeReceipts(), PROTOCOL_FEE_BPS, BPS_DENOMINATOR);
    }

    function creatorShare() public view returns (uint256) {
        return lifetimeReceipts() - protocolShare();
    }

    /// Clamped at both ends: an issuer clawback on this address shrinks the shares, and
    /// a side that has already drawn past its new share has nothing left to take.
    function creatorClaimable() public view returns (uint256) {
        return _claimable(creatorShare(), creatorWithdrawn);
    }

    function protocolClaimable() public view returns (uint256) {
        return _claimable(protocolShare(), protocolWithdrawn);
    }

    /// @notice Attach the generated piece to a LIVE-mode token. One shot: a revealed
    ///         token can never be re-pointed. The platform reveals any token; the
    ///         creator only tokens they still hold, so a sold piece cannot be pinned
    ///         out from under its collector.
    function setTokenURI(uint256 tokenId, string calldata uri) external {
        if (MODE != Mode.LIVE) revert NotRevealable();
        address holder = _requireOwned(tokenId);
        if (msg.sender != platformSigner) {
            if (msg.sender != owner()) revert NotPlatformSigner();
            if (holder != msg.sender) revert NotTokenOwner();
        }
        if (bytes(uri).length == 0) revert EmptyURI();
        if (bytes(_tokenURIs[tokenId]).length != 0) revert AlreadyRevealed();
        _tokenURIs[tokenId] = uri;
        emit Revealed(tokenId, uri);
    }

    /// @notice Point a PREGEN drop at its metadata once the set is generated and uploaded.
    function setBaseURI(string calldata uri) external onlyOwner {
        if (MODE != Mode.PREGEN) revert NotRevealable();
        if (metadataFrozen) revert MetadataLocked();
        if (bytes(uri).length == 0) revert EmptyURI();
        baseURI = uri;
        emit BaseURISet(uri);
    }

    /// @notice Repoint the collection-level document (ERC-7572). The factory points it at the
    ///         collection's document on the Ripples API at creation; a creator hosting their own
    ///         can move it here at any time.
    /// @dev    Deliberately outside `freezeMetadata`. Freezing is the promise a collector holds:
    ///         the artwork links every token resolves through stop moving. This pointer carries
    ///         the collection's marketplace page rather than any token's artwork, and freezing it
    ///         would buy no immutability, because whoever serves the URL can still change the
    ///         document behind it.
    function setContractURI(string calldata uri) external onlyOwner {
        if (bytes(uri).length == 0) revert EmptyURI();
        contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice Repoint what an unrevealed LIVE token shows. Revealed tokens are unaffected.
    function setPlaceholderURI(string calldata uri) external onlyOwner {
        if (MODE != Mode.LIVE) revert NotRevealable();
        if (metadataFrozen) revert MetadataLocked();
        if (bytes(uri).length == 0) revert EmptyURI();
        placeholderURI = uri;
        emit PlaceholderURISet(uri);
    }

    /// @notice Give up the right to move the artwork links, permanently: `baseURI` for a PREGEN
    ///         drop and `placeholderURI` for a LIVE one. Per-token reveals stay available, since
    ///         those are already one-shot, and so does `contractURI`, which points at the
    ///         collection's marketplace page rather than at any token's artwork.
    function freezeMetadata() external onlyOwner {
        if (MODE == Mode.PREGEN && bytes(baseURI).length == 0) revert EmptyURI();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function setPlatformSigner(address signer) external {
        if (msg.sender != platformSigner && msg.sender != factoryOwner()) {
            revert NotPlatformSigner();
        }
        if (signer == address(0)) revert ZeroAddress();
        platformSigner = signer;
        emit PlatformSignerSet(signer);
    }

    /// Follows the factory so a treasury rotation reaches drops that are already live.
    /// A call into a codeless FACTORY reverts on the extcodesize check ahead of the call,
    /// which `try` cannot catch, so a drop deployed straight from an EOA falls back here
    /// instead of bricking its protocol payout.
    function treasury() public view returns (address) {
        if (FACTORY.code.length == 0) return TREASURY;
        try ILaunchpad(FACTORY).treasury() returns (address current) {
            if (current != address(0)) return current;
        } catch { }
        return TREASURY;
    }

    function factoryOwner() public view returns (address) {
        if (FACTORY.code.length == 0) return address(0);
        try ILaunchpad(FACTORY).owner() returns (address current) {
            return current;
        } catch {
            return address(0);
        }
    }

    function isRevealed(uint256 tokenId) external view returns (bool) {
        return bytes(_tokenURIs[tokenId]).length != 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (MODE == Mode.PREGEN) return string.concat(baseURI, tokenId.toString());
        string memory uri = _tokenURIs[tokenId];
        return bytes(uri).length == 0 ? placeholderURI : uri;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// The deploying factory publishes the origin its collection documents are served from, so a
    /// drop carries an ERC-7572 pointer from birth without the creator setting one. A factory
    /// that publishes no origin, and a drop deployed straight from an EOA, leave it unset rather
    /// than point at nothing.
    function _initialContractURI() private view returns (string memory) {
        if (msg.sender.code.length == 0) return "";
        try ILaunchpad(msg.sender).assetOrigin() returns (string memory origin) {
            if (bytes(origin).length == 0) return "";
            return string.concat(
                origin,
                "/v1/collection-assets/",
                Strings.toHexString(address(this)),
                "/contract.json?chainId=",
                Strings.toString(block.chainid)
            );
        } catch {
            return "";
        }
    }

    /// Credit `owed` quote. Standalone: the whole amount is revenue to split. Linked: route
    /// `mintToCurveBps` into the curve and record it for the minter's allocation, then attribute
    /// only the remainder as revenue, since the routed quote has left for the curve. Once the
    /// curve has graduated it can take no more, so a late mint credits the full amount as revenue.
    /// The routed amount is capped at what the curve still needs to graduate: the pool is seeded
    /// at the curve's own price, so quote past that ceiling would never reach the pool and would
    /// be swept to the treasury instead. Anything truncated stays ordinary mint revenue.
    function _attribute(address minter, uint256 due, uint256 qty) private returns (uint256 routed) {
        if (due == 0) return 0;
        address sink = curveSink;
        if (sink == address(0)) {
            attributedReceipts += due;
            return 0;
        }
        routed = Math.mulDiv(due, mintToCurveBps, BPS_DENOMINATOR);
        if (routed != 0 && !ICurveSink(sink).graduated()) {
            uint256 raised = ICurveSink(sink).realQuote();
            uint256 target = ICurveSink(sink).GRADUATION_QUOTE();
            uint256 remaining = target > raised ? target - raised : 0;
            if (routed > remaining) routed = remaining;
        } else {
            routed = 0;
        }
        if (routed == 0) {
            attributedReceipts += due;
            return 0;
        }
        uint256 before = QUOTE.balanceOf(address(this));
        if (before < routed) revert WrongPayment();
        QUOTE.forceApprove(sink, routed);
        ICurveSink(sink).contribute(routed);
        QUOTE.forceApprove(sink, 0);
        if (QUOTE.balanceOf(address(this)) != before - routed) revert WrongPayment();
        // The ids this mint is about to issue start one past the supply, and `_issue` is the
        // only thing that moves it, so the range is settled here and minted a line later.
        if (objectClaim) {
            IObjectRecorder(allocationVesting).recordContribution(totalSupply + 1, qty, routed);
        } else {
            IAllocationRecorder(allocationVesting).recordContribution(minter, routed);
        }
        attributedReceipts += due - routed;
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

    function _transferExact(address to, uint256 amount) private {
        uint256 balanceBefore = QUOTE.balanceOf(address(this));
        uint256 toBefore = QUOTE.balanceOf(to);
        QUOTE.safeTransfer(to, amount);
        uint256 balanceAfter = QUOTE.balanceOf(address(this));
        uint256 toAfter = QUOTE.balanceOf(to);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || toAfter < toBefore || toAfter - toBefore != amount
        ) revert WrongPayment();
    }

    /// Both destinations are fixed (the immutable creator and the factory's current treasury),
    /// so `claimFor` can be permissionless without being able to redirect a penny. A caller who
    /// names neither is owed nothing, which is `NothingOwed`, not a failed transfer.
    function _claimTo(address token, address account) private returns (uint256 amount) {
        if (token != address(QUOTE)) revert NothingOwed();
        if (account == CREATOR) amount = _creatorWithdraw();
        if (account == treasury()) amount += _protocolWithdraw();
        if (amount == 0) revert NothingOwed();
    }

    /// Returns what was paid rather than reverting at zero, so the two entrypoints above can
    /// give their own answer: `NothingToWithdraw` for the original withdrawals, `NothingOwed`
    /// for the escrow vocabulary.
    function _creatorWithdraw() private returns (uint256 amount) {
        amount = creatorClaimable();
        if (amount == 0) return 0;
        creatorWithdrawn += amount;
        _transferExact(CREATOR, amount);
        emit CreatorWithdrawal(CREATOR, amount);
        emit Claimed(address(QUOTE), CREATOR, amount);
    }

    function _protocolWithdraw() private returns (uint256 amount) {
        amount = protocolClaimable();
        if (amount == 0) return 0;
        address to = treasury();
        protocolWithdrawn += amount;
        _transferExact(to, amount);
        emit ProtocolWithdrawal(to, amount);
        emit Claimed(address(QUOTE), to, amount);
    }

    /// A quote that does not answer `decimals()` is not something this collection can price
    /// against sensibly, but refusing to deploy over a read is worse than recording the ERC-20
    /// default: the figure is for display, and every amount on chain is raw either way.
    function _quoteDecimals(address quote) private view returns (uint8) {
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _claimable(uint256 share, uint256 taken) private view returns (uint256) {
        if (share <= taken) return 0;
        uint256 due = share - taken;
        uint256 balance = QUOTE.balanceOf(address(this));
        return due < balance ? due : balance;
    }

    function _checkWindow(address to, uint256 qty) private view {
        if (qty == 0 || qty > MAX_MINT_PER_TX) revert InvalidQuantity();
        if (block.timestamp < START_TIME) revert NotStarted();
        if (END_TIME != 0 && block.timestamp > END_TIME) revert Ended();
        if (totalSupply + qty > MAX_SUPPLY) revert SupplyExceeded();
        if (PER_WALLET_CAP != 0 && mintedBy[to] + qty > PER_WALLET_CAP) revert WalletCapExceeded();
    }

    /// Counters settle before `_safeMint`, whose receiver hook is the only untrusted
    /// call on the path; `nonReentrant` on every entrypoint closes the rest.
    function _issue(address to, uint256 qty) private {
        uint256 startId = totalSupply;
        totalSupply = startId + qty;
        mintedBy[to] += qty;
        for (uint256 i = 1; i <= qty; i++) {
            uint256 tokenId = startId + i;
            _safeMint(to, tokenId);
            emit Minted(to, tokenId);
        }
    }
}
