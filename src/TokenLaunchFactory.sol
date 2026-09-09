// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { Collection721, CollectionParams } from "./Collection721.sol";
import { AllocationVesting } from "./AllocationVesting.sol";
import { LPLocker } from "./LPLocker.sol";
import { CollectionDeployer } from "./libraries/CollectionDeployer.sol";
import { VestingDeployer } from "./libraries/VestingDeployer.sol";
import { PoolDeployer } from "./libraries/PoolDeployer.sol";
import { TokenDeployer } from "./libraries/TokenDeployer.sol";
import { TokenSocials } from "./AgentToken.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";
import { ILaunchHook, SeedPlan } from "./hook/interfaces/ILaunchHook.sol";

struct LaunchParams {
    string name;
    string symbol;
    uint256 curveSupply;
    uint256 lpTokenSupply;
    uint256 vQuoteInit;
    uint256 vTokenInit;
    uint256 graduationQuote;
    uint64 lpUnlockAt;
    /// The creator's own charge on top of the platform's trade fee, in basis points, paid to the
    /// creator in full. Zero is the default and is what most launches ship with.
    ///
    /// It sits after `lpUnlockAt` rather than where `tradeFeeBps` used to, so this tuple does not
    /// encode to the same signature the previous one did. Those two fields were the same widths
    /// in the other order, and a scanner keyed on `LaunchCreated`'s topic would otherwise read a
    /// creator's tax as the market's trade fee and report a 0% market wherever a creator set no
    /// tax at all.
    uint96 creatorTaxBps;
    /// The asset this launch settles in: its market, its opening buy and its pool.
    /// `address(0)` means the factory's default quote. The launch *fee* is not this asset: it is
    /// `FEE_TOKEN`, and a creator launching against a stock token approves two assets with two
    /// captions (DQ3).
    address quote;
    // ------------------------------------------------------------------ identity
    //
    // What the launch writes into its token forever, so a market terminal can show the image,
    // the blurb and the links without anybody filing anything anywhere. The token's own
    // `logo()`, `description()` and `socials()` answer these, and nothing can change them after
    // the launch transaction.
    //
    // They sit after every v4 field, so this is the v5 tuple and it hashes to a topic of its
    // own. `contracts/test/Interfaces.t.sol` pins that topic beside the four before it.
    //
    /// URI of the token's image. Required: the image is the reason this data is here at all.
    string logo;
    /// Free text, may be empty.
    string description;
    // The five links, in the order the launcher rail terminals already index publishes them.
    // Any of them may be empty; a reader shows the ones that are set.
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// One launch, as a third party enumerates it with no indexer and no log history:
/// `launchCount()` then `launches(offset, limit)`, and `isFromFactory(locker)` to check one.
///
/// `locker` is the per-launch contract and the subject every other record keys on: the address
/// `isFromFactory` answers for, the one `StockLinkRegistry` links a stock token to, and the one
/// that answers `poolId()`. It replaced the bonding curve in that role when the curve became a
/// pool: the pool is a 32-byte id rather than an address, and `hook` is a singleton shared by
/// every launch, so neither can identify one.
struct Launch {
    address token;
    address locker;
    address hook;
    address creator;
}

/// The linked-launch coupling: the token supply reserved for NFT minters, the share of each
/// NFT mint's quote routed into the curve, and the vesting schedule for the reserved slice.
struct LinkedParams {
    uint96 nftAllocationBps;
    uint96 mintToCurveBps;
    uint64 vestDuration;
    uint64 vestCliff;
}

/// The creator's launch-time options that outlive the params proper: an atomic first buy the
/// factory runs for the creator (`initialBuy` quote with an `minTokensOut` floor, 0 to skip),
/// and the wallets that pay no snipe tax. The creator is always exempt so their dev buy is not
/// taxed at `t=0`. Empty across the board is the plain launch, unchanged.
struct DevBuyParams {
    uint256 initialBuy;
    uint256 minTokensOut;
    address[] snipeExempt;
}

/// The one call `setLaunchHook` needs beyond the address itself.
interface IHookPoolManager {
    // solhint-disable-next-line func-name-mixedcase
    function POOL_MANAGER() external view returns (address);
}

/// @notice Registry and deployer for agent token launches. Creators pay the launch fee in the
///         fee token, and each launch is a full deploy: the token, its LP locker, and a real
///         Uniswap v4 pool opened and seeded inside the same transaction. No proxies, so every
///         contract verifies on Blockscout directly.
///
///         **The launch is a pool from its first block.** There is no separate curve contract
///         holding reserves any more. `LaunchHook` (one singleton, mined once, shared by every
///         launch) is the bonding curve, and a launch's market is a v4 pool keyed to it. That is
///         the whole point: a standalone curve contract is invisible to the two largest indexers
///         (GeckoTerminal prices one at `NaN`, DexScreener answers `pairs: null`), while a pool
///         is read by everything that watches the PoolManager, with no submission and nobody's
///         permission.
contract TokenLaunchFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Ceiling on the launch fee, so a fee change between a creator's approve and their launch
    /// can never pull more than 0.1 of an outstanding `FEE_TOKEN` allowance. The fee is charged
    /// in `FEE_TOKEN` (WETH) whatever a launch settles in, so this bound is in WETH.
    uint256 public constant MAX_LAUNCH_FEE = 1e17;
    uint96 public constant BPS_DENOMINATOR = 10_000;
    uint96 public constant MAX_NFT_PROTOCOL_FEE_BPS = 1_000;
    /// Ceiling on what a linked launch's collection can charge on secondary sales, matching
    /// the NFT factory so the two deployment paths list the same kind of drop.
    uint96 public constant MAX_ROYALTY_BPS = 1_000;
    /// What every market this factory opens charges on a trade, and what none of them can be
    /// opened charging instead. It used to be a field of `LaunchParams`, bounded only by
    /// `MAX_TRADE_FEE_BPS`, which meant anyone calling the factory directly could open a market
    /// that charged nothing for its whole life: no treasury revenue, no creator income, and no
    /// buy-and-burn, on a rail where every market opened through the form charges 1%. The rate is
    /// the platform's and it is stated here, once, for every launch.
    uint96 public constant TRADE_FEE_BPS = 100;
    /// The ceiling the rate above is held to, kept because it is what a reader checks the
    /// platform's own rate against.
    uint96 public constant MAX_TRADE_FEE_BPS = 1_000;
    /// The most a creator may charge on top of the trade fee. The hook holds the same ceiling and
    /// the combined bound behind it, so a launch that slipped past this one still cannot register.
    uint96 public constant MAX_CREATOR_TAX_BPS = 1_000;
    /// The creator's share of the fees their market earns, from its first trade and for the rest
    /// of its life. Fixed for every launch and registered on the hook when the pool opens, so it
    /// is a property of the launch rather than something an owner can change afterwards. The pool
    /// itself charges nothing: the hook takes the trade fee in `afterSwap` and splits it on this
    /// share, which at 1% of a trade leaves the creator 0.70% of everything that trades.
    uint96 public constant LP_FEE_CREATOR_BPS = 7_000;
    /// The opening tax at `t = 0` and how long it takes to decay to nothing. The figures the
    /// curve rail charged, moved to where the swap now happens.
    uint96 public constant SNIPE_MAX_BPS = 9_900;
    uint64 public constant SNIPE_WINDOW = 3 seconds;
    /// The graduation seed price (raise / LP tokens) must sit within this band of the curve's
    /// marginal price at the graduation threshold, so the permanent position opens where the
    /// market last traded and there is no free arbitrage at the handoff.
    uint256 public constant MIN_SEED_RATIO_BPS = 8_000;
    uint256 public constant MAX_SEED_RATIO_BPS = 12_500;
    /// Ceilings on the NFT-holder vesting schedule, so a creator cannot push the cliff or the
    /// linear release so far out that the reserved slice is never claimable.
    uint64 public constant MAX_VEST_CLIFF = 365 days;
    uint64 public constant MAX_VEST_DURATION = 1_460 days;
    uint256 public constant MAX_ASSET_ORIGIN_BYTES = 128;
    /// Bounds on the identity a launch freezes into its token. Wide enough for a hosted image
    /// URI and a paragraph of copy, narrow enough that a launch cannot park arbitrary data in a
    /// contract every terminal on the chain fetches. Checked before anything is deployed,
    /// because after that the strings are permanent.
    uint256 public constant MAX_LOGO_BYTES = 512;
    uint256 public constant MAX_DESCRIPTION_BYTES = 2_048;
    uint256 public constant MAX_SOCIAL_BYTES = 256;
    /// A Uniswap V4 hook's low 14 bits encode its permissions. `LaunchHook` must carry exactly
    /// `beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap |
    /// afterSwapReturnsDelta`, and the PoolManager refuses a pool keyed to anything else.
    uint160 public constant LAUNCH_HOOK_FLAGS = 0x2AC4;
    uint160 private constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    /// The two probe addresses a create-time plan is checked at: the launch token does not exist
    /// yet, and which side of the pool key it lands on depends on an address nobody has chosen.
    /// Below every quote and above every quote covers both orderings.
    address private constant PROBE_BELOW = address(1);
    address private constant PROBE_ABOVE = address(type(uint160).max);

    /// The asset the launch **fee** is charged in. WETH, and it stays WETH whatever a launch
    /// settles in (DQ3). Named for what it is: it is no longer the asset a market trades in.
    IERC20 public immutable FEE_TOKEN;
    IPoolManager public immutable POOL_MANAGER;

    address public treasury;
    /// The shared `IQuoteRegistry` a launch's settlement asset is admitted against, wired once
    /// after deployment the same way the graduation hook is. Read at **create only**: the locker
    /// captures its quote at construction and the hook fixes it at registration, so revoking a
    /// quote here closes the door on new launches and cannot reach a live market.
    ///
    /// Zero until it is wired, and a factory in that state launches in `FEE_TOKEN` alone,
    /// exactly what a v1 factory does. A v1 factory has no such function at all and reverts the
    /// call, which a caller reads as "this factory predates per-launch quotes".
    address public quoteRegistry;
    address public platformSigner;
    /// The singleton hook every launch's pool is keyed to, and the contract that is the bonding
    /// curve. Set once, after the hook is deployed at its mined address. Until it is set this
    /// factory cannot create a launch at all: a launch without a pool is the thing this release
    /// exists to stop shipping.
    address public launchHook;
    /// Each token of this ERC-721 waives one launch fee. Unset disables the waiver.
    address public feePassCollection;
    /// Origin serving the collection-level documents (ERC-7572) of linked launches, with no
    /// trailing slash. A collection reads it once at creation and keeps what it was born with,
    /// so changing it moves later launches only.
    string public assetOrigin;
    uint256 public launchFee = 5e14; // 0.0005 WETH
    /// Protocol fee bps stamped on a linked launch's collection, mirroring the NFT factory's
    /// default. Standalone token launches never deploy a collection and are unaffected.
    uint96 public nftProtocolFeeBps = 250;

    Launch[] public allLaunches;
    /// A locker this factory deployed. The subject every other on-chain record keys a launch on.
    mapping(address locker => bool) public isFromFactory;
    /// The launch token a factory-deployed locker holds the liquidity for.
    mapping(address locker => address token) public lockerToken;
    /// Scoped to the pass contract, so repointing `feePassCollection` cannot carry a spent
    /// flag onto a token of the same id in a different pass.
    mapping(address passCollection => mapping(uint256 passTokenId => bool)) public passConsumed;

    /// The third generation of this event, and the first that carries a pool id. A launch used
    /// to be a curve contract, so the third topic was its address; it is now a v4 pool, so the
    /// third topic is `keccak256(abi.encode(poolKey))`, the same id the PoolManager's own
    /// `Initialize` and `Swap` carry, which is what lets a scanner join our record to the
    /// market's price and volume with nothing in between.
    ///
    /// The two earlier signatures are still live on testnet, so a scanner needs the union of all
    /// three; `contracts/test/Interfaces.t.sol` pins them side by side and the freeze there is
    /// append only.
    event LaunchCreated(
        address indexed creator,
        address indexed token,
        bytes32 indexed poolId,
        address locker,
        address hook,
        LaunchParams p
    );
    event LinkedLaunchCreated(
        address indexed creator,
        address indexed token,
        address locker,
        address collection,
        address vesting
    );
    event QuoteRegistrySet(address indexed registry);
    event NftProtocolFeeSet(uint96 bps);
    event TreasurySet(address indexed treasury);
    event PlatformSignerSet(address indexed signer);
    event LaunchHookSet(address indexed hook);
    event FeePassCollectionSet(address indexed collection);
    event AssetOriginSet(string origin);
    event FeePassConsumed(uint256 indexed passTokenId, address indexed creator);
    event LaunchFeeSet(uint256 fee);
    event FeesWithdrawn(address indexed to, uint256 amount);
    /// A named asset swept to the treasury. With per-launch quotes the factory can end up
    /// holding a residue in something other than the fee token (a dev buy that unwound, a
    /// stray transfer), and `FeesWithdrawn` would misreport it as launch-fee revenue. The hole
    /// runs the other way too, so it is closed at the source: `withdrawFees(address)` emits
    /// `FeesWithdrawn` when the named asset *is* the fee token. Exactly one topic ever carries
    /// launch-fee revenue, and a revenue reader keyed on it cannot be routed around.
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotAContract();
    error HookAlreadySet();
    error HookNotWired();
    error HookPoolManagerMismatch();
    error SeedSupplyTooThin();
    /// A launch created as standalone came back from the hook with a contributor registered.
    /// Unreachable, and checked anyway: the standalone profile is admitted without the check
    /// that sizes a launch for contributions, so a standalone launch that could take one would
    /// be a market whose permanent position cannot hold its own raise.
    error NotStandalone();
    error InvalidLockWindow();
    error HookFlagsInvalid();
    error FeeTooHigh();
    error RoyaltyTooHigh();
    error NoFeePass();
    error InvalidAssetOrigin();
    error FeePassConsumedAlready();
    error NothingToWithdraw();
    error InvalidSupply();
    error InvalidReserves();
    error InvalidGraduation();
    error CreatorTaxTooHigh();
    /// The launch declared an identity a terminal cannot use: no logo at all, or a field long
    /// enough to break the readers that fetch it.
    error InvalidTokenIdentity();
    error SeedPriceOutOfBand();
    error InvalidAllocation();
    error InvalidVesting();
    error WrongPayment();
    /// The launch named an asset the registry does not admit. Raised at create, never at trade.
    error QuoteNotApproved();
    /// `vQuoteInit` or `graduationQuote` does not equal the approved row. Reserved for the two
    /// reserves: they fix the shape of the curve, and a mismatch there is a mispriced market
    /// rather than a preference. A mint price under the row's floor is `PriceOutOfRange`.
    error QuoteEconomicsMismatch();
    /// The asset's own `decimals()` is not what the registry recorded, or it does not answer at
    /// all. Every figure here is in raw units, so a launch cannot proceed without this anchor.
    error QuoteDecimalsMismatch();
    /// A linked launch whose collection and curve would settle in different assets.
    error QuoteMismatch();
    /// A collection price below the approved row's floor, or one whose routed share rounds away
    /// to nothing at the quote's decimals.
    error PriceOutOfRange();

    /// @param feeToken_ The asset the launch fee is charged in, and the default settlement
    ///        asset until a quote registry is wired. Historically called `quote`, and still the
    ///        first argument so every existing deployment recipe reads the same.
    constructor(
        address feeToken_,
        address poolManager,
        address treasury_,
        address platformSigner_,
        address owner_
    ) Ownable(owner_) {
        if (
            feeToken_ == address(0) || poolManager == address(0) || treasury_ == address(0)
                || platformSigner_ == address(0)
        ) revert ZeroAddress();
        if (feeToken_.code.length == 0 || poolManager.code.length == 0) revert NotAContract();
        FEE_TOKEN = IERC20(feeToken_);
        POOL_MANAGER = IPoolManager(poolManager);
        treasury = treasury_;
        platformSigner = platformSigner_;
    }

    /// @notice The asset a launch settles in when it names none. The registry's `defaultQuote()`
    ///         once one is wired, and the fee token before that, which is what every launch on
    ///         this factory settled in before per-launch quotes existed. Kept under the historic
    ///         name so `verify.sh`, the deployment record and every existing reader still work.
    function QUOTE() public view returns (address) {
        address registry = quoteRegistry;
        return registry == address(0) ? address(FEE_TOKEN) : IQuoteRegistry(registry).defaultQuote();
    }

    /// @notice The asset the launch fee is charged in. Never the launch's quote (DQ3).
    function feeToken() external view returns (address) {
        return address(FEE_TOKEN);
    }

    /// @notice Launch: mint the token, open its Uniswap v4 pool and seed the curve position,
    ///         all inside this transaction.
    /// @return token The launch's ERC-20.
    /// @return locker The launch's per-launch contract, which holds the position and is the
    ///         address every other record keys this launch on. `LPLocker.poolId()` is the market.
    function createLaunch(LaunchParams calldata p)
        external
        nonReentrant
        returns (address token, address locker)
    {
        _collectFee();
        DevBuyParams memory none;
        return _deploy(msg.sender, p, none);
    }

    /// @notice Launch and run the creator's opening buy in the same transaction. The creator
    ///         funds the launch fee and `d.initialBuy`, and receives the tokens from that buy.
    ///
    ///         Carrying the first trade inside the launch transaction is not a convenience. A
    ///         discovery feed on this chain covers under three minutes, so a pool that appears
    ///         without a trade can fall off the new-pairs list before one arrives.
    function createLaunch(LaunchParams calldata p, DevBuyParams calldata d)
        external
        nonReentrant
        returns (address token, address locker)
    {
        _collectFee();
        return _deploy(msg.sender, p, d);
    }

    /// @notice Launch against a fee pass the caller holds. Each pass token waives one
    ///         launch fee, so passing it on hands over a benefit that has been used.
    function createLaunchWithPass(uint256 passTokenId, LaunchParams calldata p)
        external
        nonReentrant
        returns (address token, address locker)
    {
        if (!ownsPass(msg.sender, passTokenId)) revert NoFeePass();
        address pass = feePassCollection;
        if (passConsumed[pass][passTokenId]) revert FeePassConsumedAlready();
        passConsumed[pass][passTokenId] = true;
        emit FeePassConsumed(passTokenId, msg.sender);
        DevBuyParams memory none;
        return _deploy(msg.sender, p, none);
    }

    /// @notice Launch a linked agent: a token and its market, a collection, and the allocation
    ///         vesting, cross-linked so NFT mints fund the raise and NFT minters vest a token
    ///         slice at graduation. Same flat fee as a standalone launch.
    function createLinkedLaunch(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp
    )
        external
        nonReentrant
        returns (address token, address locker, address collection, address vesting)
    {
        _collectFee();
        DevBuyParams memory none;
        return _deployLinked(msg.sender, tp, np, lp, none);
    }

    /// @notice Linked launch with the creator's opening buy in the same transaction.
    function createLinkedLaunch(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d
    )
        external
        nonReentrant
        returns (address token, address locker, address collection, address vesting)
    {
        _collectFee();
        return _deployLinked(msg.sender, tp, np, lp, d);
    }

    function withdrawFees() external nonReentrant {
        uint256 amount = FEE_TOKEN.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        address to = treasury;
        _transferExact(FEE_TOKEN, to, amount);
        emit FeesWithdrawn(to, amount);
    }

    /// @notice Sweep one named asset to the treasury. The no-argument sweep only ever reaches
    ///         the fee token, and with per-launch quotes the factory can hold a residue in
    ///         something else entirely: a dev buy that unwound, an unsolicited transfer. It
    ///         moves the whole balance, because this contract never holds anything on anyone's
    ///         behalf: fees and dev buys are pulled and spent inside the same transaction.
    ///
    ///         Both sweeps are permissionless, so naming the fee token here would otherwise let
    ///         anyone route real launch-fee revenue out under `TokenWithdrawn` and leave a
    ///         `FeesWithdrawn` reader under-reporting with nothing on chain to explain the gap.
    ///         That case emits `FeesWithdrawn` instead: the topic follows the asset, not the
    ///         entry point.
    function withdrawFees(address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        IERC20 asset = IERC20(token);
        uint256 amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        address to = treasury;
        _transferExact(asset, to, amount);
        if (token == address(FEE_TOKEN)) {
            emit FeesWithdrawn(to, amount);
        } else {
            emit TokenWithdrawn(token, to, amount);
        }
    }

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

    function launchCount() external view returns (uint256) {
        return allLaunches.length;
    }

    function launches(uint256 offset, uint256 limit) external view returns (Launch[] memory page) {
        uint256 total = allLaunches.length;
        if (offset >= total) return new Launch[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new Launch[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = allLaunches[i];
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

    /// @notice Wire the launch hook, once. It is the singleton that is the bonding curve: every
    ///         launch this factory creates registers against it and opens a pool keyed to it.
    ///
    ///         One-shot, because a launch's pool key carries the hook address and cannot be
    ///         changed afterwards. Repointing this would leave every live market keyed to a hook
    ///         the factory no longer knows about, which is worse than a factory redeploy. And a
    ///         factory redeploy is what a wrong value here costs, which is cheap while
    ///         `launchCount()` is zero and is exactly when it would be caught.
    ///
    ///         Two checks, both of which a wrong hook fails silently otherwise: the address must
    ///         encode the permission bitmap the PoolManager will look for, and the hook must have
    ///         been mined against the same PoolManager this factory is bound to.
    ///
    ///         The hook has its own owner and its own `setLaunchpad`, so wiring is two calls on
    ///         two contracts. This one does not and cannot admit the factory to the hook.
    function setLaunchHook(address hook) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        if (hook.code.length == 0) revert NotAContract();
        if (uint160(hook) & HOOK_FLAG_MASK != LAUNCH_HOOK_FLAGS) revert HookFlagsInvalid();
        if (IHookPoolManager(hook).POOL_MANAGER() != address(POOL_MANAGER)) {
            revert HookPoolManagerMismatch();
        }
        if (launchHook != address(0)) revert HookAlreadySet();
        launchHook = hook;
        emit LaunchHookSet(hook);
    }

    /// @notice The hook a launch's pool is keyed to, under the name `ITokenLaunchpad` froze. It
    ///         is now the launch hook rather than a separate graduation gate, because graduation
    ///         no longer creates a pool: it settles the one the launch has been trading in.
    function graduationHook() external view returns (address) {
        return launchHook;
    }

    /// @notice Refused. `Ownable2Step` exists so a handover cannot strand this contract, and a
    ///         renounce is the one door that leaves open: every owner-only setting would be gone
    ///         for good while creating launches kept working, so the break would stay invisible
    ///         until the first treasury rotation.
    function renounceOwnership() public pure override {
        revert();
    }

    /// @notice Wire the shared quote registry. Deployed separately and shared with the NFT
    ///         factory, so it is set here rather than taken in the constructor, in the same
    ///         window before the ownership handoff as the graduation hook and the asset origin.
    ///         Until it is set every launch settles in the fee token, which is exactly what this
    ///         factory did before per-launch quotes.
    ///
    ///         Unlike the graduation hook this is **not** one-shot, deliberately. A one-shot
    ///         binding is worth having where a wrong value is unrecoverable: a hook the
    ///         PoolManager would reject bricks graduation for every launch, with the raise
    ///         stranded behind it. A wrong registry here is not: it is read at create only, so it
    ///         can only ever refuse the *next* launch, and locking it in would make a
    ///         mis-wired deploy a full factory redeploy instead of one owner call. And the guard
    ///         would protect nothing: the owner of this factory owns the registry too, so anyone
    ///         who could re-point it can already `approveQuote` on the one it points at.
    ///
    ///         The registry's `feeToken()` must be this factory's, because the two records are
    ///         read together: a registry that disagreed would publish an allowlist against a fee
    ///         asset nobody is charged in. `QuoteRegistrySet` records every change on chain.
    function setQuoteRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        if (registry.code.length == 0) revert NotAContract();
        if (IQuoteRegistry(registry).feeToken() != address(FEE_TOKEN)) revert QuoteMismatch();
        quoteRegistry = registry;
        emit QuoteRegistrySet(registry);
    }

    /// @notice Point later linked collections' ERC-7572 document at an origin. Empty publishes
    ///         none. Standalone token launches deploy no collection and are unaffected. A
    ///         collection keeps the origin it was born with, so the shape is checked here: an
    ///         HTTPS origin, no trailing slash, because the collection appends its own path.
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

    function setNftProtocolFeeBps(uint96 bps) external onlyOwner {
        if (bps > MAX_NFT_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        nftProtocolFeeBps = bps;
        emit NftProtocolFeeSet(bps);
    }

    /// The launch fee, always in `FEE_TOKEN`. A creator launching against a stock token
    /// approves this asset for the factory and the launch's own quote for the dev buy: two
    /// approvals, two captions, and neither one can be spent as the other (DQ3).
    function _collectFee() private {
        uint256 fee = launchFee;
        if (fee != 0) _pullExact(FEE_TOKEN, msg.sender, fee);
    }

    /// The creator's opening buy, routed through the launch's own locker.
    ///
    /// It has to be the locker rather than this factory or a router. The hook charges the opening
    /// tax against the address that calls the PoolManager, which is the only address `afterSwap`
    /// ever sees, and the locker is the address `PoolDeployer` named exempt at registration. A
    /// buy sent from anywhere else would be taxed at the opening rate, which is most of it.
    ///
    /// The buy is placed with a price limit at the far end of the curve's range, so a buy bigger
    /// than the launch can fill takes the launch to its cap and hands the rest straight back
    /// instead of reverting a launch that is otherwise complete. `minTokensOut` is still the
    /// creator's floor and still unwinds the whole transaction if the fill misses it.
    function _devBuy(address creator, address locker, DevBuyParams memory d) private {
        if (d.initialBuy == 0) return;
        // The opening buy is in the launch's own quote, not the fee token. Read off the locker
        // this factory just deployed, so there is one place the resolved asset is decided.
        IERC20 quote = IERC20(LPLocker(locker).QUOTE());
        _pullExact(quote, creator, d.initialBuy);
        _transferExact(quote, locker, d.initialBuy);
        LPLocker(locker).openingBuy(d.initialBuy, d.minTokensOut, creator);
    }

    /// Pull `amount` of `token` and prove it landed by weighing both sides. A quote that
    /// reports success without moving funds, or one that takes a cut on transfer, is caught
    /// here rather than a block later.
    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 fromAfter = token.balanceOf(from);
        uint256 balanceAfter = token.balanceOf(address(this));
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

    /// A standalone launch, end to end: resolve the quote, mint the supply, open the pool and
    /// seed it, record the launch, run the opening buy.
    function _deploy(address creator, LaunchParams calldata p, DevBuyParams memory d)
        private
        returns (address token, address locker)
    {
        // The launch carries the asset it actually settles in, not the zero a caller may have
        // written for "whatever the factory's default is". An indexer reading `LaunchCreated`
        // never has to resolve it a second time.
        LaunchParams memory ep = p;
        (ep.quote,) = _admitLaunchQuote(p);
        _validate(p, ep.quote, false);

        uint256 total = p.curveSupply + p.lpTokenSupply;
        token = _mint(p, total);
        PoolDeployer.Opened memory opened = _open(creator, token, ep, total, d.snipeExempt, false);
        locker = opened.locker;
        // What the hook actually registered, rather than the flag this function passed one line
        // above. `_validate` admitted this launch without the contribution check, and the whole
        // reason that is sound is that nothing can route it quote; the hook fixes the contributor
        // at registration and has no setter, so this is the block where that becomes permanent
        // and the block to prove it in.
        if (_contributorOf(opened.poolId) != address(0)) revert NotStandalone();
        _record(creator, token, opened, ep);
        _devBuy(creator, locker, d);
    }

    function _deployLinked(
        address creator,
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams memory d
    ) private returns (address token, address locker, address collection, address vesting) {
        LaunchParams memory ep = tp;
        (ep.quote,) = _admitLinkedQuote(tp, np, lp);
        // The collection settles in the market's asset, and its price is read in that asset's
        // decimals. A drop that named a different asset would be priced in one and settled in
        // another, and since the price is immutable and the link is one-shot, the launch would
        // be dead with every contract already deployed and the fee spent. Zero means "the same".
        if (np.quote != address(0) && np.quote != ep.quote) revert QuoteMismatch();
        _validate(tp, ep.quote, true);
        _validateLinked(lp);
        if (np.royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();

        // Reserve the slice so it is `nftAllocationBps` of the full minted supply: with the
        // curve+LP tokens fixed, slice = base * bps / (denominator - bps).
        uint256 seedable = tp.curveSupply + tp.lpTokenSupply;
        uint256 slice =
            Math.mulDiv(seedable, lp.nftAllocationBps, BPS_DENOMINATOR - lp.nftAllocationBps);
        if (slice == 0) revert InvalidAllocation();

        // The slice is withheld before the pool is seeded, because there is no reserve-holding
        // curve left to pay it out of afterwards: the position takes what it needs out of what
        // the locker is given, and everything else is either the permanent position's or burned.
        token = _mint(tp, seedable + slice);
        PoolDeployer.Opened memory opened = _open(creator, token, ep, seedable, d.snipeExempt, true);
        locker = opened.locker;
        _record(creator, token, opened, ep);

        // The locker is the linked launch's curve in every sense the collection and the vesting
        // care about: it takes the routed quote, answers the raise, funds the slice and stamps
        // the clock. `LaunchHook` owns the price and holds no money, so it cannot be either.
        vesting = VestingDeployer.deploy(token, locker, lp.vestDuration, lp.vestCliff);
        // One resolved quote for both halves of a linked launch: the collection routes a share
        // of each mint into the raise, and two assets there would be two markets.
        collection = CollectionDeployer.deploy(
            np, creator, nftProtocolFeeBps, ep.quote, treasury, platformSigner
        );
        Collection721(collection).linkToCurve(locker, vesting, lp.mintToCurveBps);
        AllocationVesting(vesting).setCollection(collection);
        LPLocker(locker).setAllocation(vesting, collection, slice);
        _transferExact(IERC20(token), locker, slice);

        emit LinkedLaunchCreated(creator, token, locker, collection, vesting);
        _devBuy(creator, locker, d);
    }

    /// Deploy the locker, register the launch on the hook, open the pool at the registered price
    /// and put the curve position in it. One delegatecalled library, because the factory's
    /// runtime had 1,833 bytes of EIP-170 margin and this does not fit in them.
    function _open(
        address creator,
        address token,
        LaunchParams memory p,
        uint256 seedable,
        address[] memory snipeExempt,
        bool linked
    ) private returns (PoolDeployer.Opened memory) {
        uint64 unlockAt = p.lpUnlockAt == 0 ? type(uint64).max : p.lpUnlockAt;
        if (unlockAt <= block.timestamp) revert InvalidLockWindow();
        return PoolDeployer.open(
            PoolDeployer.OpenParams({
                hook: launchHook,
                token: token,
                quote: p.quote,
                creator: creator,
                treasury: treasury,
                seedable: seedable,
                vQuoteInit: p.vQuoteInit,
                vTokenInit: p.vTokenInit,
                graduationQuote: p.graduationQuote,
                tradeFeeBps: TRADE_FEE_BPS,
                creatorFeeBps: LP_FEE_CREATOR_BPS,
                creatorTaxBps: p.creatorTaxBps,
                snipeMaxBps: SNIPE_MAX_BPS,
                snipeWindow: SNIPE_WINDOW,
                unlockAt: unlockAt,
                linked: linked,
                snipeExempt: snipeExempt
            })
        );
    }

    /// The three writes that make a launch enumerable, and the event that announces it. Shared by
    /// both paths so the registry stays identical whichever one ran.
    function _record(
        address creator,
        address token,
        PoolDeployer.Opened memory opened,
        LaunchParams memory p
    ) private {
        allLaunches.push(
            Launch({ token: token, locker: opened.locker, hook: launchHook, creator: creator })
        );
        isFromFactory[opened.locker] = true;
        lockerToken[opened.locker] = token;
        emit LaunchCreated(creator, token, opened.poolId, opened.locker, launchHook, p);
    }

    /// The address the hook admitted to this launch's contribution accounting: zero for every
    /// standalone launch, and the launch's own locker for a linked one.
    function _contributorOf(bytes32 poolId) private view returns (address) {
        return ILaunchHook(launchHook).configOf(PoolId.wrap(poolId)).contributor;
    }

    /// A standalone launch's quote: resolved, admitted, and its reserves held to the row's
    /// standalone profile.
    function _admitLaunchQuote(LaunchParams calldata p)
        private
        view
        returns (address resolved, uint8 quoteDecimals)
    {
        IQuoteRegistry.QuoteEconomics memory e;
        bool exact;
        (resolved, quoteDecimals, e, exact) = _admitQuote(p.quote);
        if (exact) _requireReserves(p, e, false);
    }

    /// A linked launch's quote. The curve's two reserves are exact equalities and the
    /// collection's mint price is a floor: a creator picks what a drop costs within a band,
    /// while the reserves fix the shape of the curve (DQ1, amended).
    function _admitLinkedQuote(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp
    ) private view returns (address resolved, uint8 quoteDecimals) {
        IQuoteRegistry.QuoteEconomics memory e;
        bool exact;
        (resolved, quoteDecimals, e, exact) = _admitQuote(tp.quote);
        if (!exact) return (resolved, quoteDecimals);
        _requireReserves(tp, e, true);
        if (np.priceQuote < e.minPriceQuote) revert PriceOutOfRange();
        // A price whose routed share rounds away at this quote's decimals funds the curve with
        // nothing while the minter still pays, which is the one way a legal-looking price is a
        // broken market.
        if (Math.mulDiv(np.priceQuote, lp.mintToCurveBps, BPS_DENOMINATOR) == 0) {
            revert PriceOutOfRange();
        }
    }

    /// Resolve the launch's settlement asset and admit it. Read at **create only**, and the
    /// only place in this system that reads the registry at all.
    ///
    /// `address(0)` means the factory's default quote, and naming it explicitly is the same
    /// thing. Its row binds exactly like any other asset's: the default quote is on the
    /// allowlist, and its row is what the two launch profiles are sized against, so a launch
    /// settling in it does not choose its own curve either. Leaving it exempt let a launch in the
    /// one asset almost every launch settles in declare any shape it liked, including shapes
    /// whose graduation cannot pair their own raise.
    ///
    /// Only a deployment with no registry, or one whose default quote has no row, keeps the
    /// caller's figures. That is how a factory deployed before the registry stays correct.
    ///
    /// @return resolved The asset the launch settles in, never zero.
    /// @return quoteDecimals Its own `decimals()`, read here to hold the registry's row against
    ///         the live asset. Nothing keeps it: both call sites discard it.
    /// @return e The approved row, zeroed when the launch settles in the default quote.
    /// @return exact Whether `e` binds. True for every non-default quote.
    function _admitQuote(address quote)
        private
        view
        returns (
            address resolved,
            uint8 quoteDecimals,
            IQuoteRegistry.QuoteEconomics memory e,
            bool exact
        )
    {
        address registry = quoteRegistry;
        address fallbackQuote =
            registry == address(0) ? address(FEE_TOKEN) : IQuoteRegistry(registry).defaultQuote();
        resolved = quote == address(0) ? fallbackQuote : quote;
        bool approved = registry != address(0) && IQuoteRegistry(registry).approvedQuote(resolved);
        // An asset that is not the default has to be on the list. The default does not, because a
        // deployment may carry no registry at all, but where it does have a row that row binds.
        if (resolved != fallbackQuote && !approved) revert QuoteNotApproved();
        exact = approved;
        if (exact) e = IQuoteRegistry(registry).quoteEconomics(resolved);
        quoteDecimals = _quoteDecimals(resolved);
        // The row is what the reserves were sized against. An asset whose live decimals have
        // drifted from it would launch a market a factor of a thousand off its intended size.
        if (exact && e.decimals != quoteDecimals) revert QuoteDecimalsMismatch();
    }

    /// The reserves are exact equalities: they fix the shape of the curve, and a launch that
    /// declared its own would be a differently priced market wearing an approved asset's name.
    ///
    /// The row carries a pricing reserve per profile and the profile is the entry point the
    /// creator used, so which reserve binds is not a field anyone can set. The target is the
    /// same figure for both: a launch graduates at one raise on this asset whatever shape it
    /// opened in.
    function _requireReserves(
        LaunchParams calldata p,
        IQuoteRegistry.QuoteEconomics memory e,
        bool linked
    ) private pure {
        uint256 phantom = linked ? e.phantomQuote : e.standalonePhantomQuote;
        if (p.vQuoteInit != phantom || p.graduationQuote != e.graduationThreshold) {
            revert QuoteEconomicsMismatch();
        }
    }

    /// An asset that will not say what its smallest unit means cannot be settled in: every
    /// figure in this system is raw, and there is no normalisation anywhere to fall back on.
    function _quoteDecimals(address quote) private view returns (uint8) {
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            return d;
        } catch {
            revert QuoteDecimalsMismatch();
        }
    }

    function _validateLinked(LinkedParams calldata lp) private pure {
        if (lp.nftAllocationBps == 0 || lp.nftAllocationBps >= BPS_DENOMINATOR) {
            revert InvalidAllocation();
        }
        if (lp.mintToCurveBps == 0 || lp.mintToCurveBps > BPS_DENOMINATOR) {
            revert InvalidAllocation();
        }
        // The only upside a minter gets for funding the curve is the vested slice, so a cliff
        // or duration set out to the far future would strand it while the creator keeps the
        // revenue. Bound both to a sane horizon.
        if (lp.vestCliff > MAX_VEST_CLIFF || lp.vestDuration > MAX_VEST_DURATION) {
            revert InvalidVesting();
        }
    }

    /// What a launch has to be true of before a token is minted for it.
    ///
    /// Three things are checked here and nowhere else, because after this point the launch is
    /// on chain and irreversible: the supply covers both the position the hook will demand and
    /// the raise graduation will pair into the permanent one, the seed price of that permanent
    /// position tracks the curve it closed on, and the curve the launch declared is one the tick
    /// grid can actually carry.
    ///
    /// `linked` is the launch profile, and it is the entry point the creator called rather than
    /// anything they can set. It selects which worst case the supply is held to: see below.
    function _validate(LaunchParams calldata p, address quote, bool linked) private view {
        address hook = launchHook;
        if (hook == address(0)) revert HookNotWired();
        if (p.curveSupply == 0 || p.lpTokenSupply == 0) revert InvalidSupply();
        if (p.vTokenInit <= p.curveSupply) revert InvalidReserves();
        if (p.vQuoteInit == 0) revert InvalidReserves();
        if (p.graduationQuote == 0) revert InvalidGraduation();
        if (p.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert CreatorTaxTooHigh();
        _validateIdentity(p);

        uint256 total = p.curveSupply + p.lpTokenSupply;

        // The launch token the raise buys at the price the curve closes at, which is what
        // graduation pays to pair that raise into the permanent position. Both checks below are
        // statements about that one figure.
        uint256 vQuoteRef = p.vQuoteInit + p.graduationQuote;
        uint256 seedAtClose = Math.mulDiv(
            p.graduationQuote, Math.mulDiv(p.vTokenInit, p.vQuoteInit, vQuoteRef), vQuoteRef
        );

        // Graduation pairs the whole raise into the permanent position, and what that costs in
        // launch token depends on how the raise arrived. Refuse a launch that could not open
        // that position rather than find out at graduation, after the money is in: the
        // settlement runs once, and what it cannot pair is credited to the treasury, which is
        // the creator's raise leaving the market it was raised for.
        //
        // The two profiles are funded differently, so they are held to different worst cases,
        // and that is the whole difference between them.
        //
        // A linked raise can arrive entirely as an NFT collection's routed mint revenue. The
        // pool never traded, so nothing was sold and the price is still the launch price, and
        // pairing the whole raise there costs the most token a graduation can ever cost.
        //
        // A standalone launch registers no contributor, so no collection can route it a wei and
        // its raise can only arrive through the pool, one trade at a time, moving the price on
        // every one. Its worst case is the far end of the same curve: the traverse is paid for
        // in launch token that is now in buyers' hands, so what pairs the raise is the supply
        // the curve position never took. Holding it to the linked case instead would force it to
        // open within a quarter of its graduation price, which is why the standalone profile
        // exists.
        //
        // What keeps the two apart is that a standalone launch stays standalone. The hook fixes
        // the contributor at registration and has no setter for it, `recordContribution` refuses
        // a launch whose contributor is zero, and `LPLocker.contribute` refuses a caller that is
        // not the collection the factory bound on the linked path. `_deploy` reads the
        // registration back and refuses to return a standalone launch that has one.
        uint256 seedable = total;
        if (linked) {
            if (Math.mulDiv(p.graduationQuote, p.vTokenInit, p.vQuoteInit) > total) {
                revert SeedSupplyTooThin();
            }
        } else {
            if (seedAtClose > total) revert SeedSupplyTooThin();
            seedable = total - seedAtClose;
        }

        // The designed end: `lpTokenSupply` against the full raise, which is what a launch filled
        // entirely by buying produces. Require that price to track the curve's marginal price at
        // the threshold, so the permanent position opens where the market last traded and there
        // is no free arbitrage at the handoff. Both sides are quote-per-token ratios, and the
        // band is `lpTokenSupply` held within a fifth or a quarter of `seedAtClose`.
        uint256 ratioBps = Math.mulDiv(seedAtClose, 10_000, p.lpTokenSupply);
        if (ratioBps < MIN_SEED_RATIO_BPS || ratioBps > MAX_SEED_RATIO_BPS) {
            revert SeedPriceOutOfBand();
        }

        // The curve position itself, asked of the hook rather than re-derived here. It reverts on
        // a band the tick grid cannot hold and on liquidity that would not fit the pool, and it
        // answers how much of the supply the position consumes. Asking it against `seedable`
        // rather than the whole mint is what holds a standalone launch to the paragraph above:
        // the position is sized off the launch's own reserves, so this is the launch's actual
        // traverse rather than a closed form standing in for it. Both currency orderings are
        // checked because the launch token's address does not exist yet and nobody chooses which
        // side of the quote it lands on.
        _requirePlanFits(hook, quote, p, seedable, PROBE_BELOW);
        _requirePlanFits(hook, quote, p, seedable, PROBE_ABOVE);
    }

    /// The identity is frozen by the token's constructor, so this is the last block in which it
    /// can be refused. An empty logo is refused rather than defaulted: a launch that lists with
    /// no image is the failure this data exists to prevent, and it cannot be repaired afterwards.
    /// An empty description and empty link slots are fine, and are what most launches ship with.
    function _validateIdentity(LaunchParams calldata p) private pure {
        uint256 logoBytes = bytes(p.logo).length;
        if (logoBytes == 0 || logoBytes > MAX_LOGO_BYTES) revert InvalidTokenIdentity();
        if (bytes(p.description).length > MAX_DESCRIPTION_BYTES) revert InvalidTokenIdentity();
        if (
            bytes(p.twitter).length > MAX_SOCIAL_BYTES
                || bytes(p.telegram).length > MAX_SOCIAL_BYTES
                || bytes(p.discord).length > MAX_SOCIAL_BYTES
                || bytes(p.website).length > MAX_SOCIAL_BYTES
                || bytes(p.farcaster).length > MAX_SOCIAL_BYTES
        ) revert InvalidTokenIdentity();
    }

    /// Mint the launch's whole supply to this factory, with the identity the launch declared
    /// written into the token for good. One function for both profiles, and its own frame: the
    /// linked path is already at the compiler's stack limit, and the identity is seven strings.
    function _mint(LaunchParams calldata p, uint256 supply) private returns (address) {
        TokenSocials memory s = TokenSocials({
            twitter: p.twitter,
            telegram: p.telegram,
            discord: p.discord,
            website: p.website,
            farcaster: p.farcaster
        });
        return TokenDeployer.deployToken(
            p.name, p.symbol, address(this), supply, p.logo, p.description, s
        );
    }

    function _requirePlanFits(
        address hook,
        address quote,
        LaunchParams calldata p,
        uint256 seedable,
        address probe
    ) private view {
        SeedPlan memory plan = ILaunchHook(hook)
            .planFor(probe, quote, p.vQuoteInit, p.vTokenInit, p.graduationQuote);
        if (plan.tokenAmount > seedable) revert SeedSupplyTooThin();
    }
}
