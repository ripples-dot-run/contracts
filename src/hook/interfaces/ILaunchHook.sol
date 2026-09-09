// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IPullEscrow } from "../../interfaces/IPullEscrow.sol";
import { ILaunchHookEvents } from "./ILaunchHookEvents.sol";

/// Where a launch is in its life. The order is the only order: a phase never goes backwards and
/// never skips. `None` is an unregistered pool id, which is every pool id but ours.
enum Phase {
    None,
    /// Registered by a launchpad. The pool key is fixed and the seed plan is computed, but the
    /// pool does not exist yet and nothing may trade.
    Registered,
    /// Initialized at the launch price and seeded with the curve position. Trading is open.
    Trading,
    /// The raise cleared the target. The fee split does not move, and the locker is admitted,
    /// once, to retire the curve position and open the permanent one. Swaps are refused until it
    /// does, so this phase lasts one transaction.
    Graduated,
    /// The permanent position is in place. Liquidity is closed for good.
    Locked
}

/// What a launchpad hands the hook to claim a pool id. Every field is fixed at registration and
/// nothing here can be changed afterwards, by anyone, including the hook's owner.
struct RegisterParams {
    /// The launch token. Its whole tradeable supply funds the curve position.
    address token;
    /// The settlement asset. `address(0)` is native ETH, which v4 sorts as `currency0` always.
    address quote;
    /// The only address this pool will ever accept liquidity from.
    address locker;
    /// Paid `creatorFeeBps` of the trade fee from the launch's first trade. Zero sends the
    /// whole fee to the treasury for the launch's whole life.
    address creator;
    /// A linked launch's collection, permitted to call `recordContribution`. Zero for a
    /// standalone launch, and a standalone launch's `contributedQuote` is zero forever.
    address contributor;
    /// The curve's virtual quote reserve, in the quote's own smallest unit. With `vTokenInit` it
    /// fixes the launch price; the pool opens at the tick that price falls in.
    uint256 vQuoteInit;
    /// The curve's virtual token reserve, in the token's smallest unit (always 18 decimals here).
    uint256 vTokenInit;
    /// The raise that graduates the launch, in the quote's own smallest unit. It fixes the top of
    /// the position's range: the position is pure quote exactly when this much has come in.
    uint256 graduationQuote;
    /// The fee the hook takes out of every swap, in basis points of the swap's unspecified side.
    uint96 tradeFeeBps;
    /// The creator's share of the trade fee, in basis points, on every trade the launch ever
    /// takes. The rest is the treasury's. Neither graduation nor anything else moves it.
    uint96 creatorFeeBps;
    /// A second charge on top of the trade fee, in basis points, paid to the creator in full and
    /// never split with the treasury. Zero on a launch whose creator did not ask for one, which
    /// is what most launches are. `tradeFeeBps + creatorTaxBps` is what a trader actually pays.
    uint96 creatorTaxBps;
    /// The opening tax at `t = 0`, halving fourteen times across `snipeWindow`.
    uint96 snipeMaxBps;
    /// How long the opening tax lasts, in seconds.
    uint64 snipeWindow;
    /// Addresses that pay no opening tax. The creator is added automatically. These are matched
    /// against the address that calls the PoolManager, so a launch's atomic first buy must be
    /// routed by an address named here: for the factory's own dev buy, the factory.
    address[] snipeExempt;
}

/// The launch as it was registered. Read by the keeper, the indexer and the web rail.
struct LaunchConfig {
    address token;
    address quote;
    address locker;
    address creator;
    address contributor;
    /// The launchpad that registered it. `treasury()` is read from it live, so rotating the
    /// treasury reaches launches that are already trading.
    address launchpad;
    /// The launchpad's payout address at registration, kept as the fallback for a launchpad that
    /// later stops answering. `ILaunchHook.treasury` prefers the live one.
    address treasury;
    uint96 tradeFeeBps;
    uint96 creatorFeeBps;
    uint96 snipeMaxBps;
    uint64 snipeWindow;
    /// The block timestamp `register` ran in. Kept for readers that want the moment a launchpad
    /// claimed the pool id; nothing in the hook's arithmetic uses it.
    uint64 registeredAt;
    /// The block timestamp trading opened in, which is the seed rather than the registration.
    /// The opening tax decays from here and the graduation window is measured from here. Zero
    /// until the launch's liquidity is in the pool.
    uint64 launchedAt;
    /// The creator's own charge on top of the trade fee, paid to them in full. It sits here
    /// rather than beside `creatorFeeBps` because the two timestamps above leave sixteen spare
    /// bytes in their slot, so a launch that sets one pays for no extra storage.
    uint96 creatorTaxBps;
    /// Where the creator's two legs are actually paid. It starts as `creator` and only the
    /// address currently named here can move it, so a creator can hand their income to a wallet
    /// they control better, to a team's multisig, or to a contract that splits it among holders.
    /// `creator` never changes, so who launched a market stays readable after the money moves.
    address creatorFeeRecipient;
    uint256 graduationQuote;
}

/// The position the launch opens, computed once at registration and enforced on every call that
/// could change it. The pool may only be initialized at `sqrtPriceX96` and may only ever hold
/// this one position, so a launch's opening price and its curve are properties of the hook rather
/// than of whatever transaction happened to open it.
struct SeedPlan {
    /// The opening price, exactly the price at `tickLower` (or at `tickUpper` when the token is
    /// `currency1`), so the position is single sided and needs no quote.
    uint160 sqrtPriceX96;
    int24 tickLower;
    int24 tickUpper;
    /// The position's liquidity, sized so that traversing the range from end to end takes in
    /// exactly `graduationQuote` of the quote.
    uint128 liquidity;
    /// The launch token the locker must hold to open the position. The rest of the supply is not
    /// this hook's business.
    uint256 tokenAmount;
}

/// The mutable part: what a reader has to poll.
struct LaunchState {
    Phase phase;
    /// The live position's liquidity: the curve's while trading, zero between the seed's
    /// retirement and the settlement, and the permanent full-range position's from settlement
    /// on. A reader pairing this with the curve's planned ticks after settlement is reading a
    /// position that no longer exists; the locker carries the live range.
    uint128 liquidity;
    /// Quote a linked collection routed into the raise. Counts toward the target, never moves
    /// the price.
    uint256 contributedQuote;
    /// The raise, in the quote's smallest unit. Zero before `graduate`, which records what the
    /// curve position held at that price, and rewritten once by the settlement with what the
    /// position actually carried out of the pool. Swaps are refused between the two, so they
    /// agree. Once the curve position is gone there is no geometry left to read the raise off,
    /// so this is what `realQuote` answers from then on.
    uint256 raisedQuote;
}

/// Everything one pool id answers in a single call, so an off-chain reader needs one multicall
/// entry per launch rather than four. It is assembled by `LaunchLens`, which reads it back out of
/// the hook's own public views: the batch reader lives beside the hook rather than in it, because
/// the encoder for an array of these grows with every field `LaunchConfig` gains and the hook is
/// the one contract here that cannot afford it.
struct LaunchView {
    PoolId poolId;
    LaunchConfig config;
    SeedPlan plan;
    LaunchState state;
    /// The quote side of the curve position at the live price, plus `contributedQuote`. This is
    /// the figure the raise is measured in and the one `graduate` tests.
    uint256 realQuote;
    /// The live pool price, or zero before the pool is initialized.
    uint160 sqrtPriceX96;
    /// The opening tax right now, in basis points, on a swap by a non-exempt caller.
    uint256 snipeTaxBps;
}

/// @notice The bonding curve, stated as a Uniswap v4 hook.
///
/// A Ripples launch used to be a standalone contract holding its own reserves, which is the shape
/// every launchpad on this chain ships and the shape the two largest indexers cannot price:
/// GeckoTerminal carries a curve address with a null price and DexScreener answers `pairs: null`.
/// A launch that is a real v4 pool from its first block is read by every indexer that watches the
/// PoolManager, with no submission and nobody's permission.
///
/// **One hook, every launch.** A hook's permissions are the low 14 bits of its address, so a hook
/// has to be mined, and mining one inside a launch transaction is not possible. This contract is
/// therefore a singleton with a `mapping(PoolId => …)`, deployed once at a mined address and
/// registered against by every launchpad the owner allows. The pool key is derived from the token
/// and the quote alone, so a pool id is computable off chain from a launch's two addresses.
///
/// **The pool is the curve, exactly.** A v4 position over a bounded range is a constant-product
/// curve with virtual reserves. Choose the range's ends as the launch price and the graduation
/// price and give it `liquidity = sqrt(vQuoteInit * vTokenInit)`, and the position's price
/// schedule is the same schedule the curve rail computed from its `vQuote / vToken`, to the last
/// wei the tick grid allows. `contracts/src/libraries/SeedMath.sol` derives it and
/// `docs/plans/2026-09-05-pool-curve-design.md` carries the numbers.
///
/// **The money moves the way it already moved.** The trade fee and the opening tax are taken in
/// `afterSwap` out of the swap's unspecified side and credited to the pull escrow this repo
/// already speaks: `IPullEscrow`, credited never pushed, because a blocked treasury must not be
/// able to revert every trade on a launch. The hook settles them as ERC-6909 claims inside the
/// PoolManager rather than as transfers, so a swap moves no token to any address the hook does not
/// control and an issuer who blocks the hook cannot halt the market either.
interface ILaunchHook is ILaunchHookEvents, IPullEscrow {
    /// The pool fee every Ripples pool carries: none. The pool charges nothing and the hook
    /// charges everything, so a fee change is a hook decision rather than a new pool.
    function POOL_FEE() external view returns (uint24);

    /// The tick spacing every Ripples pool carries.
    function TICK_SPACING() external view returns (int24);

    /// Where an opening tax that lands in the launch token is credited. Claiming it sends the
    /// tokens there, which is the burn.
    function BURN_SINK() external view returns (address);

    /// @notice Claim a pool id for a launch and fix its curve. Only a launchpad the owner has
    ///         allowed may call it, and only once per pool id.
    /// @return key The pool key the launch must be initialized with, and nothing else.
    /// @return plan The one position the pool will accept.
    function register(RegisterParams calldata params)
        external
        returns (PoolKey memory key, SeedPlan memory plan);

    /// @notice The pool key a token and a quote produce. Pure: a caller can derive a launch's
    ///         pool id before the launch exists, which is what lets a launchpad emit it.
    function poolKeyFor(address token, address quote) external view returns (PoolKey memory key);

    /// @notice The position a set of curve parameters produces, without registering anything.
    ///         A launchpad calls this at create to refuse a configuration whose position would
    ///         not fit the supply it is about to mint, rather than discovering it at launch.
    function planFor(
        address token,
        address quote,
        uint256 vQuoteInit,
        uint256 vTokenInit,
        uint256 graduationQuote
    ) external view returns (SeedPlan memory plan);

    /// @notice Close the raise, once, when the position's quote side plus any contributions reach
    ///         the target and the opening tax window has closed. It creates no pool and moves no
    ///         liquidity: the locker is admitted to settle. Swaps are refused from this call until
    ///         the locker's settlement lands, so the raise cannot be drained between the two.
    ///
    ///         Only the launch's registered locker may call it, because the phase it leaves
    ///         behind has no exit but a settlement. Graduating a launch is still open to anyone
    ///         through `LPLocker.settleGraduation`, which closes the raise and settles it in one
    ///         transaction and reverts as a whole if the settlement cannot complete.
    function graduate(PoolId poolId) external;

    /// @notice Record quote a linked collection routed into the raise. Only the launch's
    ///         registered contributor may call it. The quote itself is the caller's to custody;
    ///         this is the accounting the target is measured against.
    function recordContribution(PoolId poolId, uint256 amount) external;

    /// @notice Allow or stop a launchpad from registering launches. Owner only.
    function setLaunchpad(address launchpad, bool allowed) external;

    function configOf(PoolId poolId) external view returns (LaunchConfig memory);
    function planOf(PoolId poolId) external view returns (SeedPlan memory);
    function stateOf(PoolId poolId) external view returns (LaunchState memory);

    /// @notice The raise so far: the quote side of the curve position at the live price, plus
    ///         contributions. This is what replaced the curve rail's own raise figure, and it
    ///         is the only figure `graduate` tests.
    function realQuote(PoolId poolId) external view returns (uint256);

    /// @notice The raise that graduates this launch.
    function graduationQuote(PoolId poolId) external view returns (uint256);

    /// @notice Whether `graduate` would succeed right now.
    function graduationReady(PoolId poolId) external view returns (bool);

    /// @notice The opening tax right now, in basis points. Zero once the window has closed.
    function snipeTaxBps(PoolId poolId) external view returns (uint256);

    /// @notice Whether `account` pays no opening tax on this launch.
    function snipeExempt(PoolId poolId, address account) external view returns (bool);

    /// @notice Send this launch's creator income to a different address from now on. Only the
    ///         address currently receiving it may call this, and it takes effect immediately:
    ///         nobody else, including the hook's owner and the launchpad that registered the
    ///         launch, can move a creator's payout.
    ///
    ///         Balances already owed stay owed to the address that earned them, so a move never
    ///         hands anyone somebody else's unclaimed income. The new recipient stops paying the
    ///         opening tax, which matters when it is a contract the launch itself trades through.
    ///
    ///         Pointing a launch at a contract that has no way to move it again is what makes a
    ///         routing permanent. There is no flag for that and there does not need to be.
    function setCreatorFeeRecipient(PoolId poolId, address recipient) external;

    /// @notice The pool id of a launch token, or zero for an address that never launched here.
    ///         One token launches once, so this is a bijection over registered launches.
    function poolIdOfToken(address token) external view returns (PoolId);
}
