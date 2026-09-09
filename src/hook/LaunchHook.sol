// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { ITokenLaunchpad } from "../interfaces/ITokenLaunchpad.sol";
import { HookFeeMath } from "../libraries/HookFeeMath.sol";
import { PoolMath } from "../libraries/PoolMath.sol";
import { SeedMath } from "../libraries/SeedMath.sol";
import {
    ILaunchHook,
    LaunchConfig,
    LaunchState,
    Phase,
    RegisterParams,
    SeedPlan
} from "./interfaces/ILaunchHook.sol";

/// The one call the hook makes into a locker, to learn when its principal is allowed to leave.
interface ILockerUnlockTime {
    function UNLOCK_AT() external view returns (uint64);
}

/// @notice The bonding curve as a Uniswap v4 hook, so a Ripples launch is a real pool from its
///         first block and every indexer that watches the PoolManager can price it immediately.
///
/// Read `docs/plans/2026-09-05-pool-curve-design.md` for the arithmetic and the measured price
/// table. The short version, and the four properties this contract exists to hold:
///
/// 1. **The pool opens where the launch said it would.** `register` computes the position from the
///    launch's own curve parameters and stores it; `beforeInitialize` refuses any price but that
///    one and `beforeAddLiquidity` refuses any position but that one. Neither the launchpad nor
///    the locker can open a Ripples pool at a price of its choosing.
/// 2. **Only the launch's own liquidity is ever in it.** Outside LPs are refused before and after
///    graduation. So the reserves an indexer computes from the position are the reserves the
///    launch put there, which is what makes the adapter's numbers checkable against chain state.
/// 3. **The price never leaves the curve.** A bounded position has ends, and beyond them v4 moves
///    the price for free because there is no liquidity to charge. `afterSwap` refuses a swap that
///    would end outside the range, which is the same refusal the curve rail made when a buy
///    exceeded the curve supply, and it is what stops a terminal from ever showing a price no one
///    could trade at.
/// 4. **A trade cannot be blocked by anyone's payout.** The fee and the opening tax are settled as
///    ERC-6909 claims inside the PoolManager and credited to a pull-escrow ledger. No token moves
///    to any address during a swap, so a treasury an issuer has blocked, or a hook address an
///    issuer has blocked, cannot revert somebody else's trade. It is `IPullEscrow`'s rule, applied
///    where it now bites hardest.
contract LaunchHook is ILaunchHook, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// The pool charges nothing; the hook charges everything. Static, not dynamic: a dynamic fee
    /// would be one more thing an indexer has to read to price a trade.
    uint24 public constant POOL_FEE = 0;
    /// 200, matching the v4 pools already indexed on this chain, and the only spacing a Ripples
    /// pool uses. The design doc records what its 2% grid costs the opening price.
    int24 public constant TICK_SPACING = 200;
    /// Where an opening tax taken in the launch token goes. Claiming it performs the burn.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    uint96 internal constant BPS_DENOMINATOR = 10_000;
    uint96 internal constant MAX_TRADE_FEE_BPS = 1_000;
    /// The ceiling on a creator's own charge, and the ceiling on what the two of them together
    /// can take out of one trade. The second is the one a trader cares about: whatever a future
    /// owner does to the trade fee, a Ripples market can never charge more than 20% of a swap.
    uint96 internal constant MAX_CREATOR_TAX_BPS = 1_000;
    uint96 internal constant MAX_TOTAL_TRADE_FEE_BPS = 2_000;
    uint96 internal constant MAX_SNIPE_BPS = 9_900;
    /// A ceiling on how long a launch may tax its opening, so a launchpad cannot register a
    /// market that taxes forever.
    uint64 internal constant MAX_SNIPE_WINDOW = 1 days;

    IPoolManager public immutable POOL_MANAGER;

    /// Launchpads permitted to register launches. The hook is mined once and outlives every
    /// factory that uses it, so a factory redeploy is an entry here rather than a new hook.
    mapping(address launchpad => bool allowed) public allowedLaunchpad;

    mapping(PoolId poolId => LaunchConfig) private _configs;
    mapping(PoolId poolId => SeedPlan) private _plans;
    mapping(PoolId poolId => LaunchState) private _states;
    mapping(PoolId poolId => mapping(address account => bool)) private _snipeExempt;
    mapping(address token => PoolId poolId) private _poolIdOfToken;

    /// The pull-escrow ledger, in the currencies the fee actually landed in. A buy's fee is in
    /// the launch token and a sell's is in the quote, so both keys are live on every launch.
    mapping(address token => mapping(address account => uint256 amount)) public owed;
    mapping(address token => uint256 amount) public totalOwed;

    /// Guards the one unlock this contract ever opens, the same shape `LPLocker` uses.
    bytes32 private _callbackHash;

    error NotPoolManager();
    error NotLaunchpad();
    error NotLocker();
    error NotContributor();
    error NotCreator();
    error NotOurPool();
    error AlreadyRegistered();
    error UnknownPool();
    error WrongOpeningPrice();
    error WrongSeedPosition();
    error LiquidityClosed();
    error StillLocked();
    error NotTrading();
    error ExactOutputClosed();
    error CurveRangeExceeded();
    error AlreadyGraduated();
    error BelowThreshold();
    error SnipeWindowOpen();
    error InvalidConfig();
    error ZeroAddress();
    error NotAContract();
    error InvalidCallback();
    error CallbackNotConsumed();

    constructor(IPoolManager poolManager, address owner_) Ownable(owner_) {
        if (address(poolManager) == address(0)) revert ZeroAddress();
        if (address(poolManager).code.length == 0) revert NotAContract();
        POOL_MANAGER = poolManager;
        // Reverts unless this contract's address encodes exactly the permissions below, which is
        // what makes a mis-mined deploy fail here rather than at the first launch.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// The permission bitmap, and the low 14 bits the hook's address must carry: `0x2AC4`.
    ///
    /// `beforeInitialize` refuses a pool that is not a registered launch and refuses to open a
    /// registered one at any price but its own. `beforeAddLiquidity` and `beforeRemoveLiquidity`
    /// keep every LP but the launch's locker out, permanently. `afterSwap` with
    /// `afterSwapReturnsDelta` is the only way a v4 hook may charge, and `beforeSwap` is what
    /// refuses a trade before the launch's liquidity is in place: without it the window between
    /// `initialize` and the seed is a window in which anyone can set the opening price, and the
    /// opening price is the whole point of being visible from block one.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setLaunchpad(address launchpad, bool allowed) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        allowedLaunchpad[launchpad] = allowed;
        emit LaunchpadSet(launchpad, allowed);
    }

    /// @inheritdoc ILaunchHook
    function register(RegisterParams calldata params)
        external
        returns (PoolKey memory key, SeedPlan memory plan)
    {
        if (!allowedLaunchpad[msg.sender]) revert NotLaunchpad();
        _validate(params);

        key = poolKeyFor(params.token, params.quote);
        PoolId poolId = key.toId();
        if (_configs[poolId].token != address(0)) revert AlreadyRegistered();
        if (PoolId.unwrap(_poolIdOfToken[params.token]) != bytes32(0)) revert AlreadyRegistered();

        plan = _plan(
            params.vQuoteInit,
            params.vTokenInit,
            params.graduationQuote,
            Currency.unwrap(key.currency0) == params.token
        );
        _plans[poolId] = plan;

        _configs[poolId] = LaunchConfig({
            token: params.token,
            quote: params.quote,
            locker: params.locker,
            creator: params.creator,
            contributor: params.contributor,
            launchpad: msg.sender,
            treasury: _launchpadTreasury(msg.sender),
            tradeFeeBps: params.tradeFeeBps,
            creatorFeeBps: params.creator == address(0) ? 0 : params.creatorFeeBps,
            creatorTaxBps: params.creator == address(0) ? 0 : params.creatorTaxBps,
            creatorFeeRecipient: params.creator,
            snipeMaxBps: params.snipeMaxBps,
            snipeWindow: params.snipeWindow,
            registeredAt: uint64(block.timestamp),
            // The opening tax and the graduation window run from the moment trading opens, which
            // is the seed, not this call. `beforeAddLiquidity` sets it.
            launchedAt: 0,
            graduationQuote: params.graduationQuote
        });
        _states[poolId].phase = Phase.Registered;
        _poolIdOfToken[params.token] = poolId;

        if (params.creator != address(0)) _snipeExempt[poolId][params.creator] = true;
        for (uint256 i = 0; i < params.snipeExempt.length; i++) {
            if (params.snipeExempt[i] != address(0)) {
                _snipeExempt[poolId][params.snipeExempt[i]] = true;
            }
        }

        emit LaunchRegistered(
            poolId,
            params.token,
            params.quote,
            params.locker,
            params.creator,
            params.graduationQuote,
            plan.sqrtPriceX96,
            plan.tickLower,
            plan.tickUpper,
            plan.liquidity
        );
    }

    function _validate(RegisterParams calldata p) private view {
        if (p.token == address(0) || p.locker == address(0)) revert ZeroAddress();
        if (p.token == p.quote) revert InvalidConfig();
        if (p.token.code.length == 0 || p.locker.code.length == 0) revert NotAContract();
        if (p.quote != address(0) && p.quote.code.length == 0) revert NotAContract();
        if (p.tradeFeeBps > MAX_TRADE_FEE_BPS) revert InvalidConfig();
        if (p.creatorFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (p.creatorTaxBps > MAX_CREATOR_TAX_BPS) revert InvalidConfig();
        if (p.tradeFeeBps + p.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) revert InvalidConfig();
        if (p.snipeMaxBps > MAX_SNIPE_BPS) revert InvalidConfig();
        if (p.snipeWindow > MAX_SNIPE_WINDOW) revert InvalidConfig();
    }

    /// The launchpad's payout address at registration, kept as the fallback for a launchpad that
    /// later stops answering. `treasury()` prefers the live answer, so rotating the treasury
    /// reaches launches that are already trading.
    function _launchpadTreasury(address launchpad) private view returns (address) {
        try ITokenLaunchpad(launchpad).treasury() returns (address current) {
            if (current != address(0)) return current;
        } catch { }
        revert InvalidConfig();
    }

    /// @inheritdoc ILaunchHook
    function poolKeyFor(address token, address quote) public view returns (PoolKey memory) {
        (address currency0, address currency1) = token < quote ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    /// @inheritdoc ILaunchHook
    function planFor(
        address token,
        address quote,
        uint256 vQuoteInit,
        uint256 vTokenInit,
        uint256 targetQuote
    ) external pure returns (SeedPlan memory) {
        return _plan(vQuoteInit, vTokenInit, targetQuote, token < quote);
    }

    function _plan(
        uint256 vQuoteInit,
        uint256 vTokenInit,
        uint256 targetQuote,
        bool tokenIsCurrency0
    ) private pure returns (SeedPlan memory plan) {
        (
            uint160 sqrtPriceX96,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 tokenAmount
        ) = SeedMath.plan(vQuoteInit, vTokenInit, targetQuote, TICK_SPACING, tokenIsCurrency0);
        plan = SeedPlan({
            sqrtPriceX96: sqrtPriceX96,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokenAmount: tokenAmount
        });
    }

    /// @dev Only a registered launch may open a pool keyed to this hook, only its locker or its
    ///      launchpad may open it, and only at the price the launch was registered with.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (address(key.hooks) != address(this)) revert NotOurPool();
        PoolId poolId = key.toId();
        LaunchConfig storage config = _config(poolId);
        if (_states[poolId].phase != Phase.Registered) revert AlreadyRegistered();
        if (sender != config.locker && sender != config.launchpad) revert NotLocker();
        if (sqrtPriceX96 != _plans[poolId].sqrtPriceX96) revert WrongOpeningPrice();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Two positions are ever admitted, both from the launch's own locker: the curve, once,
    ///      at exactly the registered ticks and liquidity; and after graduation the permanent
    ///      full-range position, once, after the curve position has been retired.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        PoolId poolId = key.toId();
        LaunchConfig storage config = _config(poolId);
        if (sender != config.locker) revert NotLocker();

        LaunchState storage state = _states[poolId];
        if (state.phase == Phase.Registered) {
            SeedPlan storage plan = _plans[poolId];
            if (
                params.tickLower != plan.tickLower || params.tickUpper != plan.tickUpper
                    || params.salt != bytes32(0)
                    || params.liquidityDelta != int256(uint256(plan.liquidity))
            ) revert WrongSeedPosition();
            state.phase = Phase.Trading;
            state.liquidity = plan.liquidity;
            // The launch clock starts here, because this is where trading starts. Registering in
            // one block and seeding in a later one would otherwise ship a launch whose opening
            // tax had already decayed and whose graduation window was already satisfied.
            config.launchedAt = uint64(block.timestamp);
            emit LaunchSeeded(poolId, plan.liquidity, plan.tickLower, plan.tickUpper);
        } else if (state.phase == Phase.Graduated) {
            (int24 fullLower, int24 fullUpper) = PoolMath.fullRangeTicks(TICK_SPACING);
            if (
                state.liquidity != 0 || params.tickLower != fullLower
                    || params.tickUpper != fullUpper || params.salt != bytes32(0)
                    || params.liquidityDelta <= 0
            ) revert WrongSeedPosition();
            uint128 liquidity = uint256(params.liquidityDelta).toUint128();
            state.phase = Phase.Locked;
            state.liquidity = liquidity;
            emit GraduationSettled(poolId, liquidity);
        } else {
            revert LiquidityClosed();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Nobody removes liquidity from a Ripples pool while it is a curve. The locker retires
    ///      the curve position in the graduation settlement, and after that the only exit is the
    ///      locker's own unlock time, which a permanent lock never reaches.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        PoolId poolId = key.toId();
        LaunchConfig storage config = _config(poolId);
        if (sender != config.locker) revert NotLocker();

        LaunchState storage state = _states[poolId];
        if (params.liquidityDelta > 0) revert WrongSeedPosition();
        if (state.phase == Phase.Graduated) {
            // The curve position comes out whole or not at all. A partial retirement would leave
            // the market trading a curve nobody registered, which is the one thing every guard
            // above exists to prevent.
            SeedPlan storage plan = _plans[poolId];
            if (
                params.tickLower != plan.tickLower || params.tickUpper != plan.tickUpper
                    || params.salt != bytes32(0)
                    || uint256(-params.liquidityDelta) != state.liquidity
            ) revert WrongSeedPosition();
            // The raise, recorded off the position that is about to leave rather than off the
            // reading `graduate` took. This is the quote the locker is about to receive, at the
            // price and the liquidity the removal itself will settle at, so what the launch says
            // it raised and what the locker has in hand are the same number.
            state.raisedQuote = realQuote(poolId);
            emit GraduationRaiseSettled(poolId, state.raisedQuote);
        } else if (state.phase == Phase.Locked) {
            uint64 unlockAt = _lockerUnlockAt(config.locker);
            if (unlockAt == type(uint64).max || block.timestamp < unlockAt) revert StillLocked();
        } else {
            revert StillLocked();
        }

        uint256 removed = uint256(-params.liquidityDelta);
        // The cast only runs when `removed` is below `state.liquidity`, which is a `uint128`.
        // forge-lint: disable-next-line(unsafe-typecast)
        state.liquidity = removed >= state.liquidity ? 0 : state.liquidity - uint128(removed);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev A launch trades from the block its liquidity lands in until the raise closes, and
    ///      again from the block the permanent position lands in. A swap at any other moment is
    ///      refused, and there are three of them.
    ///
    ///      Before the seed: an initialized pool with no position in it has no price anyone paid
    ///      for, and one swap would set it.
    ///
    ///      Between `graduate` and the locker's settlement: the curve position is still in the
    ///      pool, but the raise is closed and the position's quote is already spoken for. A sell
    ///      in that window takes quote out of the amount the locker is on its way to collect.
    ///      Only the launch's own locker may close the raise and it settles in the same
    ///      transaction, so the window is that transaction and nothing longer.
    ///
    ///      With the position out and its replacement not yet in: an empty range moves its price
    ///      for free, because there is no liquidity to charge. The swap consumes nothing, delivers
    ///      nothing, and every terminal watching prints whatever limit the caller passed.
    ///
    ///      One further trade is refused, for a reason that is about the opening tax rather than
    ///      about the position: an exact-output buy while that tax is live. `_taxedBuy` says why.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external view returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        PoolId poolId = key.toId();
        LaunchState storage state = _states[poolId];
        Phase phase = state.phase;
        // An empty pool is not a market in either phase. On the curve that is the state before
        // the launch is seeded; under a permanent position it is what a timed lock looks like
        // after its owner has withdrawn the whole thing. Letting a swap through then would move
        // a price with nothing funding it, and every terminal reads that price as a trade.
        if (phase == Phase.Trading || phase == Phase.Locked) {
            if (state.liquidity == 0) revert NotTrading();
        } else {
            revert NotTrading();
        }
        // A positive `amountSpecified` is v4's exact-output swap: the caller names what they
        // receive and the pool decides what they pay.
        if (params.amountSpecified > 0 && _taxedBuy(poolId, key, sender, params.zeroForOne)) {
            revert ExactOutputClosed();
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Whether this swap is a buy the opening tax would charge: quote into the pool and launch
    /// token out, by a caller the launch did not exempt, at a moment the rate is still above zero.
    /// The same three conditions `_charge` applies, read one step earlier.
    ///
    /// It is the test an exact-output buy is refused on, and the reason is the constraint that
    /// shapes `afterSwap`. A hook may take its delta only out of the swap's unspecified side, so
    /// the opening tax falls on the tokens an exact-input buy receives and on the quote an
    /// exact-output buy pays. The same rate on those two legs is not the same penalty. A buyer
    /// who names the tokens walks away with every one of them and pays a surcharge on a quote leg
    /// the curve priced nonlinearly, which at the opening rate is worth many times what the same
    /// budget buys the other way, and choosing between the two modes takes no privileged role.
    /// Charging an equivalent rate would mean inverting the curve across two fee currencies, so
    /// the mode is closed instead, for exactly as long as the tax would bite. A sell is never
    /// taxed and is never refused here, an exempt caller's opening buy is untouched, and exact
    /// output reopens by itself in the second the rate reaches zero.
    function _taxedBuy(PoolId poolId, PoolKey calldata key, address sender, bool zeroForOne)
        private
        view
        returns (bool)
    {
        LaunchConfig storage config = _configs[poolId];
        bool quoteIsCurrency0 = Currency.unwrap(key.currency0) == config.quote;
        if (zeroForOne != quoteIsCurrency0 || _snipeExempt[poolId][sender]) return false;
        return HookFeeMath.snipeBps(
            config.launchedAt, config.snipeWindow, config.snipeMaxBps, block.timestamp
        ) != 0;
    }

    /// @dev The fee and the opening tax, taken out of the swap's unspecified side because that is
    ///      the only side v4 lets a hook take, and the range guard.
    ///
    ///      Which side that is, plainly. On an exact-input buy the unspecified side is the launch
    ///      token, so the fee arrives in the token and the buyer receives the pool's output less
    ///      the fee. On a sell it is the quote, exactly as the curve rail charged. On an
    ///      exact-output swap it is the input, so the swapper pays the fee on top. The tax is
    ///      charged first and the fee on what is left, which is the order the curve used.
    ///      `beforeSwap` refuses an exact-output buy for as long as the tax is live, so the tax
    ///      itself only ever comes out of the tokens a buy releases.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        PoolId poolId = key.toId();
        _config(poolId);
        _requireInRange(poolId, _states[poolId].phase);

        (bool isCurrency1, uint256 amount) =
            HookFeeMath.unspecified(delta, params.amountSpecified, params.zeroForOne);
        if (amount == 0) return (IHooks.afterSwap.selector, int128(0));

        bool quoteIsCurrency0 = Currency.unwrap(key.currency0) == _configs[poolId].quote;
        uint256 total = _charge(
            poolId,
            sender,
            isCurrency1 ? key.currency1 : key.currency0,
            params.zeroForOne == quoteIsCurrency0,
            amount
        );
        return (IHooks.afterSwap.selector, total.toInt128());
    }

    /// The whole of what a swap owes the launch, in the one currency v4 allows: the opening tax
    /// first, then the trade fee and the creator's tax on what is left, which is the order the
    /// curve rail applied. The fee and the tax are charged on the same base, so a creator moving
    /// their slider changes what a trader pays and nothing else.
    /// @param isBuy Whether the swap moved quote into the pool and the launch token out.
    function _charge(PoolId poolId, address sender, Currency currency, bool isBuy, uint256 amount)
        private
        returns (uint256 total)
    {
        LaunchConfig storage config = _configs[poolId];

        uint256 taxBps = isBuy && !_snipeExempt[poolId][sender]
            ? HookFeeMath.snipeBps(
                config.launchedAt, config.snipeWindow, config.snipeMaxBps, block.timestamp
            )
            : 0;
        uint256 tax = HookFeeMath.share(amount, taxBps);
        uint256 fee = HookFeeMath.share(amount - tax, config.tradeFeeBps);
        uint256 creatorTax = HookFeeMath.share(amount - tax, config.creatorTaxBps);
        total = tax + fee + creatorTax;
        if (total == 0) return 0;

        // Settled as a claim rather than a transfer: nothing leaves the PoolManager during a
        // swap, so no recipient's token can revert somebody else's trade.
        POOL_MANAGER.mint(address(this), currency.toId(), total);
        _settle(poolId, config, Currency.unwrap(currency), tax, taxBps, creatorTax, fee);
    }

    /// Every leg of a charge, credited off one resolution of the launch's payout addresses.
    ///
    /// All three run through here rather than the tax keeping a path of its own, because
    /// `treasury` reaches into the launchpad on every call and asking it twice in one swap pays
    /// for the same answer twice. The opening tax still lands where it always did: on the burn
    /// sink when it came out of the launch token, which is every case a buy can produce, and on
    /// the treasury in the currency case the exact-output refusal keeps a taxed buy out of.
    ///
    /// The creator's tax is credited whole and never reaches the split below it. That is the
    /// point of it: the trade fee is the platform's charge and the creator takes a share, and
    /// this is the creator's own charge and the platform takes none of it.
    function _settle(
        PoolId poolId,
        LaunchConfig storage config,
        address currencyToken,
        uint256 tax,
        uint256 taxBps,
        uint256 creatorTax,
        uint256 fee
    ) private {
        address treasuryTo = treasury(poolId);
        if (tax != 0) {
            address to = currencyToken == config.token ? BURN_SINK : treasuryTo;
            _credit(currencyToken, to, tax);
            emit SnipeTaxCharged(poolId, currencyToken, to, tax, taxBps);
        }
        address creatorTo = config.creatorFeeRecipient;
        if (creatorTax != 0) {
            _credit(currencyToken, creatorTo, creatorTax);
            emit CreatorTaxCharged(poolId, currencyToken, creatorTo, creatorTax);
        }
        if (fee == 0) return;

        // The creator is paid from the launch's first trade and for the rest of its life. A
        // creator who earns nothing until graduation earns nothing on the launches that never
        // reach it, which is most of them, and the curve is where their work actually happens.
        uint256 creatorShare = HookFeeMath.share(fee, config.creatorFeeBps);
        if (creatorShare != 0) {
            _credit(currencyToken, creatorTo, creatorShare);
            emit TradeFeeCharged(poolId, currencyToken, creatorTo, creatorShare);
        }
        uint256 treasuryShare = fee - creatorShare;
        if (treasuryShare != 0) {
            _credit(currencyToken, treasuryTo, treasuryShare);
            emit TradeFeeCharged(poolId, currencyToken, treasuryTo, treasuryShare);
        }
    }

    /// A bounded position has ends, and v4 moves the price past them for free because there is no
    /// liquidity there to charge. A swap that would end outside the curve is refused, so the
    /// price a terminal reads is always one somebody paid.
    function _requireInRange(PoolId poolId, Phase phase) private view {
        if (phase != Phase.Trading && phase != Phase.Graduated) return;
        SeedPlan storage plan = _plans[poolId];
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (
            sqrtPriceX96 < TickMath.getSqrtPriceAtTick(plan.tickLower)
                || sqrtPriceX96 > TickMath.getSqrtPriceAtTick(plan.tickUpper)
        ) revert CurveRangeExceeded();
    }

    /// @inheritdoc ILaunchHook
    function graduate(PoolId poolId) external {
        LaunchConfig storage config = _config(poolId);
        // Closing the raise and settling it are one decision, so they are one caller. Swaps are
        // refused from this call until the permanent position lands and there is no way back to
        // `Trading`, so a stranger who could close the raise on its own could shut a market for
        // everyone whenever the settlement is unavailable: a stock quote whose issuer has blocked
        // the locker leaves the market tradeable and the settlement impossible. The locker's
        // `settleGraduation` stays open to anyone and reverts whole when the settlement fails, so
        // finishing a graduation is still nobody's privilege; leaving one half done is no longer
        // anybody's option.
        if (msg.sender != config.locker) revert NotLocker();
        LaunchState storage state = _states[poolId];
        if (state.phase != Phase.Trading) revert AlreadyGraduated();
        // The tax counts toward nothing here, but the window still has to close before the raise
        // is called done: a launch whose opening minute is taxed at 99% has not found its price.
        if (block.timestamp < uint256(config.launchedAt) + config.snipeWindow) {
            revert SnipeWindowOpen();
        }
        uint256 raised = realQuote(poolId);
        if (raised < config.graduationQuote) revert BelowThreshold();

        // Swaps stop here and reopen when the permanent position lands. `raised` is what the
        // position holds at this price; `beforeRemoveLiquidity` records it again off the removal
        // itself, and with trading closed between the two they agree.
        state.phase = Phase.Graduated;
        state.raisedQuote = raised;
        emit Graduated(poolId, raised, config.graduationQuote);
    }

    /// @inheritdoc ILaunchHook
    function recordContribution(PoolId poolId, uint256 amount) external {
        LaunchConfig storage config = _config(poolId);
        if (msg.sender != config.contributor || config.contributor == address(0)) {
            revert NotContributor();
        }
        LaunchState storage state = _states[poolId];
        if (state.phase != Phase.Registered && state.phase != Phase.Trading) {
            revert AlreadyGraduated();
        }
        uint256 total = state.contributedQuote + amount;
        state.contributedQuote = total;
        emit ContributionRecorded(poolId, msg.sender, amount, total);
    }

    /// @notice Take what this hook owes you. `NothingOwed()` at zero.
    function claim(address token) external nonReentrant returns (uint256 amount) {
        return _claim(token, msg.sender);
    }

    /// @notice Take what this hook owes `account` and pay it to `account`. Permissionless, and
    ///         it never pays anyone but `account`, which is how the treasury's fees are swept
    ///         without the treasury holding a key that touches a launch, and how the opening
    ///         tax reaches the burn sink.
    function claimFor(address token, address account)
        external
        nonReentrant
        returns (uint256 amount)
    {
        return _claim(token, account);
    }

    function _claim(address token, address account) private returns (uint256 amount) {
        amount = owed[token][account];
        if (amount == 0) revert NothingOwed();
        owed[token][account] = 0;
        totalOwed[token] -= amount;
        bytes memory raw = abi.encode(token, account, amount);
        _callbackHash = keccak256(raw);
        POOL_MANAGER.unlock(raw);
        if (_callbackHash != bytes32(0)) revert CallbackNotConsumed();
        emit Claimed(token, account, amount);
    }

    /// @dev The one unlock this contract opens: burn the claim the fee was settled as, and take
    ///      the underlying straight to the account it is owed to. A recipient whose issuer has
    ///      blocked them reverts here, in their own transaction, and their balance stays owed.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        bytes32 expected = _callbackHash;
        if (expected == bytes32(0) || keccak256(raw) != expected) revert InvalidCallback();
        delete _callbackHash;

        (address token, address account, uint256 amount) =
            abi.decode(raw, (address, address, uint256));
        Currency currency = Currency.wrap(token);
        POOL_MANAGER.burn(address(this), currency.toId(), amount);
        POOL_MANAGER.take(currency, account, amount);
        return "";
    }

    function _credit(address token, address account, uint256 amount) private {
        owed[token][account] += amount;
        totalOwed[token] += amount;
        emit Credited(token, account, amount);
    }

    /// @notice The payout address for this launch: the launchpad's current one, or the one
    ///         recorded at registration if the launchpad no longer answers.
    function treasury(PoolId poolId) public view returns (address) {
        LaunchConfig storage config = _configs[poolId];
        address launchpad = config.launchpad;
        if (launchpad.code.length != 0) {
            try ITokenLaunchpad(launchpad).treasury() returns (address current) {
                if (current != address(0)) return current;
            } catch { }
        }
        return config.treasury;
    }

    function configOf(PoolId poolId) external view returns (LaunchConfig memory) {
        return _configs[poolId];
    }

    function planOf(PoolId poolId) external view returns (SeedPlan memory) {
        return _plans[poolId];
    }

    function stateOf(PoolId poolId) external view returns (LaunchState memory) {
        return _states[poolId];
    }

    /// @inheritdoc ILaunchHook
    function realQuote(PoolId poolId) public view returns (uint256) {
        LaunchState storage state = _states[poolId];
        if (state.phase == Phase.None) return 0;
        if (state.phase == Phase.Locked) return state.raisedQuote;
        if (state.phase == Phase.Registered) return state.contributedQuote;
        // The curve position has been retired and the settled figure recorded. There is no
        // geometry left to read the raise off, so the record is the answer from here on.
        if (state.phase == Phase.Graduated && state.liquidity == 0) return state.raisedQuote;

        SeedPlan storage plan = _plans[poolId];
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        bool quoteIsCurrency0 = _configs[poolId].quote < _configs[poolId].token;
        uint256 held = SeedMath.quoteHeld(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(plan.tickLower),
            TickMath.getSqrtPriceAtTick(plan.tickUpper),
            state.liquidity,
            quoteIsCurrency0
        );
        return held + state.contributedQuote;
    }

    function graduationQuote(PoolId poolId) external view returns (uint256) {
        return _configs[poolId].graduationQuote;
    }

    function graduationReady(PoolId poolId) external view returns (bool) {
        LaunchConfig storage config = _configs[poolId];
        if (_states[poolId].phase != Phase.Trading) return false;
        if (block.timestamp < uint256(config.launchedAt) + config.snipeWindow) return false;
        return realQuote(poolId) >= config.graduationQuote;
    }

    function snipeTaxBps(PoolId poolId) external view returns (uint256) {
        LaunchConfig storage config = _configs[poolId];
        return HookFeeMath.snipeBps(
            config.launchedAt, config.snipeWindow, config.snipeMaxBps, block.timestamp
        );
    }

    function snipeExempt(PoolId poolId, address account) external view returns (bool) {
        return _snipeExempt[poolId][account];
    }

    function poolIdOfToken(address token) external view returns (PoolId) {
        return _poolIdOfToken[token];
    }

    /// @inheritdoc ILaunchHook
    function setCreatorFeeRecipient(PoolId poolId, address recipient) external {
        LaunchConfig storage config = _config(poolId);
        // Only the address the income is going to may redirect it, which for a launch nobody has
        // moved yet is the creator. A launch registered with no creator has nobody holding that
        // right, and no transaction comes from the zero address, so its fee stays whole to the
        // treasury for good.
        if (msg.sender != config.creatorFeeRecipient) revert NotCreator();
        if (recipient == address(0)) revert ZeroAddress();
        config.creatorFeeRecipient = recipient;
        // A recipient the launch trades through would otherwise pay the opening tax on the
        // launch's own routing, which is the same reason the creator is exempted at registration.
        _snipeExempt[poolId][recipient] = true;
        emit CreatorFeeRecipientSet(poolId, msg.sender, recipient);
    }

    function _config(PoolId poolId) private view returns (LaunchConfig storage config) {
        config = _configs[poolId];
        if (config.token == address(0)) revert UnknownPool();
    }

    function _lockerUnlockAt(address locker) private view returns (uint64) {
        try ILockerUnlockTime(locker).UNLOCK_AT() returns (uint64 unlockAt) {
            return unlockAt;
        } catch {
            return type(uint64).max;
        }
    }

    /// No other hook callback is enabled by this contract's address, so none is ever invoked.
    /// A call to any other selector is not part of a Ripples launch and is refused.
    fallback() external {
        revert NotOurPool();
    }
}
