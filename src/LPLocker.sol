// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolMath } from "./libraries/PoolMath.sol";
import { PoolDeployer } from "./libraries/PoolDeployer.sol";
import { ITokenLaunchpad } from "./interfaces/ITokenLaunchpad.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";
import { ILaunchHook, LaunchState, Phase } from "./hook/interfaces/ILaunchHook.sol";

/// The vesting contract a linked launch reserves a token slice for. Funded and stamped once,
/// at graduation, by the launch's own custodian, which is this contract.
interface IAllocationVesting {
    function onGraduation(uint256 slice) external;
    function totalContribution() external view returns (uint256);
}

/// @notice A launch's liquidity, from its first block to its last.
///
/// In Uniswap V4 a position belongs to whichever address opened it, so this contract *is* the
/// position. It opens the launch's curve position inside the launch transaction, holds the
/// supply that has not been sold, and at graduation retires the curve position and opens the
/// permanent full-range one in a single call. Principal cannot leave before `UNLOCK_AT` (a
/// permanent lock by default); trading fees can be swept while it stays, split between the
/// launch's creator and the treasury at the share fixed here when the launch was created.
///
/// **What changed when the curve became a pool.** There is no longer a separate contract holding
/// the launch's reserves: the reserves are the position, and this contract holds it from block
/// one rather than from graduation. So this contract also inherited the three jobs the curve rail
/// did outside the pool: custody the supply the position has not taken, custody a linked
/// collection's routed quote, and hand the reserved slice to the vesting contract at graduation.
/// `LaunchHook` owns everything that touches a price.
///
/// **Both halves of the fee split are credited, never pushed** (DQ4, amended). This is Pons'
/// lesson stated in code: a stock token's issuer can block an address, and under a push a blocked
/// creator would strand the treasury's half of every collection alongside their own, and a
/// blocked treasury would strand the creator's. Each side takes its own money with `claim`, and
/// neither can hold the other's hostage. `free(token)` (the balance less what is owed and less
/// what the launch has reserved) is the only balance a sweep is allowed to move.
contract LPLocker is IUnlockCallback, IPullEscrow, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint96 internal constant BPS_DENOMINATOR = 10_000;
    /// Where the supply a launch never sold goes. The same sink the curve rail burned to.
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    IPoolManager public immutable POOL_MANAGER;
    /// The singleton hook that is this launch's bonding curve. It fixes the pool's opening
    /// price, its one admissible position and its fee schedule, and this contract is the only
    /// address it will accept liquidity from.
    address public immutable HOOK;
    address public immutable FACTORY;
    /// The launch's own ERC-20. Held here in two parts: the supply the curve position has not
    /// taken, and the slice a linked launch reserved for its minters.
    address public immutable TOKEN;
    /// The asset the launch settles in.
    address public immutable QUOTE;
    /// Payout address baked in at deploy; `treasury()` prefers the factory's current one.
    address public immutable TREASURY;
    /// The launch's creator, paid `CREATOR_FEE_BPS` of every fee collection. Zero means the
    /// treasury takes the whole sweep.
    address public immutable CREATOR;
    /// The creator's share of collected pool fees, fixed when the launch was created. It
    /// applies to fees only; principal is never split.
    uint96 public immutable CREATOR_FEE_BPS;
    /// Principal stays put until this timestamp. `type(uint64).max` is a permanent lock.
    uint64 public immutable UNLOCK_AT;

    bool public seeded;
    /// The graduation settlement has run: the curve position is retired and the permanent
    /// full-range position is in place.
    bool public settled;
    /// The creator's opening buy has run. One per launch, inside the launch transaction.
    bool public openingBought;
    /// The pull-escrow ledger. Keyed by token because a pool has two currencies and both can
    /// earn fees; keyed by account because the creator's share and the treasury's are separate
    /// claims that must not be able to block each other.
    mapping(address token => mapping(address account => uint256 amount)) public owed;
    mapping(address token => uint256 amount) public totalOwed;
    PoolKey private _key;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    /// The launch supply held here rather than in the pool: what the curve position did not
    /// take. It funds the permanent position at graduation and whatever is left of it is burned.
    /// Excluded from `free`, so no sweep can reach it.
    uint256 public tokenReserve;
    /// A linked launch's reserved slice, set once beside the collection and the vesting. Also
    /// excluded from `free`.
    uint256 public allocationSlice;
    /// Quote a linked collection routed out of its mints, held here until the settlement puts it
    /// into the permanent position. It is the minters' raise the whole time it sits here, so it
    /// is excluded from `free` until then. Mirrors `ILaunchHook.stateOf(poolId).contributedQuote`
    /// and is kept locally because `free` is read on every sweep and every settlement.
    uint256 public contributedQuote;
    address public allocationVesting;
    address public linkedCollection;
    bytes32 private _callbackHash;

    /// Which shape of work an unlock is doing. One enum rather than four callback entry points,
    /// because the PoolManager calls back into whoever opened the unlock and there is only one
    /// of those.
    enum Job {
        Liquidity,
        Settle,
        Buy
    }

    struct CallbackData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        uint256 amount0Limit;
        uint256 amount1Limit;
        address receiver;
    }

    /// The graduation settlement, in one unlock: retire the curve position, push in the reserve
    /// and whatever quote a linked collection routed, open the permanent position, and take back
    /// what the permanent position could not pair.
    struct SettleData {
        PoolKey key;
        int24 curveLower;
        int24 curveUpper;
        uint128 curveLiquidity;
        int24 fullLower;
        int24 fullUpper;
        uint256 tokenIn;
        uint256 quoteIn;
    }

    struct BuyData {
        PoolKey key;
        bool quoteIsCurrency0;
        uint256 quoteIn;
        uint256 minTokensOut;
        address recipient;
    }

    event Seeded(bytes32 indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// The permanent position is open and the launch's liquidity is closed for good. `burned` is
    /// the supply that was never sold and never needed to pair the raise, which is the figure the
    /// curve rail's own burn event carried.
    event GraduationSettled(
        bytes32 indexed poolId, uint128 liquidity, uint256 raisedQuote, uint256 burned
    );
    event AllocationSet(address indexed vesting, address indexed collection, uint256 slice);
    event Contributed(address indexed from, uint256 quoteIn);
    event OpeningBuy(address indexed recipient, uint256 quoteIn, uint256 tokensOut);
    /// The amounts here are what was **credited** to each side, not what was paid out: since the
    /// DQ4 amendment neither half of the split leaves this contract until its owner claims it.
    /// Each credit also emits `Credited(token, account, amount)`; this event stays because it is
    /// the one place both currencies and both recipients appear together.
    event FeesCollected(
        address indexed creator,
        address indexed treasury,
        uint256 creatorAmount0,
        uint256 creatorAmount1,
        uint256 treasuryAmount0,
        uint256 treasuryAmount1
    );
    event Unlocked(address indexed to, uint128 liquidity, uint256 amount0, uint256 amount1);
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    error NotFactory();
    error NotCollection();
    error NotPoolManager();
    error NotAContract();
    error AlreadySeeded();
    error NotSeeded();
    error AlreadySettled();
    error NotGraduated();
    error StillLocked();
    error NotAuthorized();
    error ZeroLiquidity();
    error SlippageExceeded();
    error UnexpectedDebt();
    error InvalidCallback();
    error CallbackNotConsumed();
    error TransferMismatch();
    error NothingToSweep();
    error NothingToCollect();
    error InvalidFeeSplit();
    error AllocationAlreadySet();
    error AllocationUnset();
    error AlreadyBought();
    error InsufficientOutput();

    constructor(
        IPoolManager poolManager_,
        address hook_,
        address factory_,
        address token_,
        address quote_,
        address treasury_,
        address creator_,
        uint96 creatorFeeBps_,
        uint64 unlockAt_
    ) {
        if (
            address(poolManager_) == address(0) || hook_ == address(0) || factory_ == address(0)
                || token_ == address(0) || quote_ == address(0) || treasury_ == address(0)
        ) revert NotAuthorized();
        if (
            address(poolManager_).code.length == 0 || hook_.code.length == 0
                || factory_.code.length == 0 || token_.code.length == 0 || quote_.code.length == 0
        ) revert NotAContract();
        if (creatorFeeBps_ > BPS_DENOMINATOR) revert InvalidFeeSplit();
        POOL_MANAGER = poolManager_;
        HOOK = hook_;
        FACTORY = factory_;
        TOKEN = token_;
        QUOTE = quote_;
        TREASURY = treasury_;
        CREATOR = creator_;
        CREATOR_FEE_BPS = creator_ == address(0) ? 0 : creatorFeeBps_;
        UNLOCK_AT = unlockAt_;
    }

    /// @notice Open the pool and put the launch's curve position in it, in that order and in one
    ///         call. The factory has already registered the launch on the hook and sent this
    ///         contract the supply; `liquidity_` is the hook's own registered plan, passed
    ///         through rather than re-derived, because the hook refuses anything but the plan to
    ///         the unit and the periphery's `forAmounts` inverts v4's deposit math with the
    ///         opposite rounding.
    ///
    ///         Initializing and seeding inside the same external call is what closes the window
    ///         a v4 pool is otherwise open in: between `initialize` and the first position, one
    ///         swap would set the price every terminal then prints. The hook refuses a swap
    ///         before its liquidity lands as well, so the guard is held twice.
    /// @return seededLiquidity The position's liquidity, which is `liquidity_`.
    function seedExact(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tickLower_,
        int24 tickUpper_,
        uint128 liquidity_,
        uint256 amount0Max,
        uint256 amount1Max
    ) external nonReentrant returns (uint128 seededLiquidity) {
        if (msg.sender != FACTORY) revert NotFactory();
        if (seeded) revert AlreadySeeded();
        seeded = true;
        if (liquidity_ == 0) revert ZeroLiquidity();
        // No liquidity or amount ceiling is re-derived here. `SeedMath.plan` already refuses a
        // position whose liquidity does not fit `uint128` or whose token side does not fit the
        // `int128` leg of a balance delta, and the PoolManager enforces its own per-tick cap. A
        // third copy of the same arithmetic would be a third place to get it wrong.
        _key = key;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        liquidity = liquidity_;
        seededLiquidity = liquidity_;

        POOL_MANAGER.initialize(key, sqrtPriceX96);
        bytes memory res = _execute(
            Job.Liquidity,
            abi.encode(
                CallbackData({
                    key: key,
                    tickLower: tickLower_,
                    tickUpper: tickUpper_,
                    liquidityDelta: int256(uint256(liquidity_)),
                    amount0Limit: amount0Max,
                    amount1Limit: amount1Max,
                    receiver: address(this)
                })
            )
        );
        (uint256 used0, uint256 used1) = abi.decode(res, (uint256, uint256));

        // Whatever the position did not take is the launch's reserve: it funds the permanent
        // position at graduation and whatever is still left of it then is burned. Measured off
        // the balance rather than off the arithmetic, so it is what this contract actually holds.
        tokenReserve = IERC20(TOKEN).balanceOf(address(this));
        emit Seeded(PoolId.unwrap(key.toId()), liquidity_, used0, used1);
    }

    /// @notice Run the creator's opening buy, inside the launch transaction, with quote the
    ///         factory has already sent here. The launch's first trade has to be in the same
    ///         transaction as its pool: a discovery feed on this chain covers under three minutes,
    ///         so a pool that appears without a trade can be gone from it before one arrives.
    ///
    ///         The hook's opening tax keys on the address that calls the PoolManager, which is
    ///         this contract, and the factory named it exempt at registration. That is why the
    ///         buy is routed here rather than sent from the factory to a router.
    function openingBuy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != FACTORY) revert NotFactory();
        if (!seeded) revert NotSeeded();
        if (openingBought) revert AlreadyBought();
        openingBought = true;
        if (quoteIn == 0 || recipient == address(0)) revert NotAuthorized();

        PoolKey memory key = _key;
        bool quoteIsCurrency0 = Currency.unwrap(key.currency0) == QUOTE;
        bytes memory res = _execute(
            Job.Buy,
            abi.encode(
                BuyData({
                    key: key,
                    quoteIsCurrency0: quoteIsCurrency0,
                    quoteIn: quoteIn,
                    minTokensOut: minTokensOut,
                    recipient: recipient
                })
            )
        );
        tokensOut = abi.decode(res, (uint256));
        emit OpeningBuy(recipient, quoteIn, tokensOut);
    }

    /// @notice Bind the linked collection, its vesting contract and the token slice reserved for
    ///         its minters. Set once, by the factory, in the launch transaction. The slice is
    ///         held here and excluded from `free`, exactly as the curve held it.
    function setAllocation(address vesting, address collection, uint256 slice) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (allocationVesting != address(0)) revert AllocationAlreadySet();
        if (vesting == address(0) || collection == address(0) || slice == 0) {
            revert AllocationUnset();
        }
        if (vesting.code.length == 0 || collection.code.length == 0) revert NotAContract();
        linkedCollection = collection;
        allocationVesting = vesting;
        allocationSlice = slice;
        emit AllocationSet(vesting, collection, slice);
    }

    /// @notice Take quote the linked collection routed out of a mint and record it against the
    ///         raise. It releases no launch token and never moves the pool price, which is what a
    ///         contribution did on the curve rail; the minters' upside is the vested slice.
    ///
    ///         The quote stays here until graduation, where it goes into the permanent position
    ///         alongside what the curve position raised. The hook keeps the accounting and holds
    ///         no money, so the two have to be the same contract, and this is it.
    function contribute(uint256 quoteIn) external nonReentrant {
        if (msg.sender != linkedCollection || linkedCollection == address(0)) {
            revert NotCollection();
        }
        if (settled) revert AlreadySettled();
        _pullExact(IERC20(QUOTE), msg.sender, quoteIn);
        contributedQuote += quoteIn;
        ILaunchHook(HOOK).recordContribution(_key.toId(), quoteIn);
        emit Contributed(msg.sender, quoteIn);
    }

    /// @notice Whether the raise has closed. Read by a linked collection, which stops routing
    ///         mint revenue into a launch that no longer takes it.
    function graduated() external view returns (bool) {
        Phase phase = ILaunchHook(HOOK).stateOf(_key.toId()).phase;
        return phase == Phase.Graduated || phase == Phase.Locked;
    }

    /// @notice The raise that graduates this launch, in the quote's own smallest unit.
    // solhint-disable-next-line func-name-mixedcase
    function GRADUATION_QUOTE() external view returns (uint256) {
        return ILaunchHook(HOOK).graduationQuote(_key.toId());
    }

    /// @notice The raise so far: what the curve position holds in quote at the live price, plus
    ///         everything a linked collection routed in.
    function realQuote() external view returns (uint256) {
        return ILaunchHook(HOOK).realQuote(_key.toId());
    }

    /// @notice Close the raise and put the permanent position in the pool, in one transaction.
    ///
    ///         Permissionless, and it has to be one transaction rather than two. The hook refuses
    ///         swaps from the moment the raise closes until the permanent position lands, because
    ///         between those two points the curve position's quote is already spoken for and a
    ///         sell would take the raise apart. A settlement split across two transactions would
    ///         halt the market between them and, worse, leave a block in which the pool holds no
    ///         liquidity at all: a range with nothing in it moves its price for free, and every
    ///         terminal watching would print whatever a stranger's dust trade asked for.
    ///
    ///         What happens, in order: retire the curve position whole; add the reserve and any
    ///         quote a linked collection routed to what came out of it; open the permanent
    ///         full-range position with as much of that as it can pair; hand the linked launch's
    ///         reserved slice to its vesting contract; burn what is left of the supply.
    /// @return permanentLiquidity The liquidity of the position that is now locked for good.
    /// @return burned The supply that was never sold and was not needed to pair the raise.
    function settleGraduation()
        external
        nonReentrant
        returns (uint128 permanentLiquidity, uint256 burned)
    {
        if (!seeded) revert NotSeeded();
        if (settled) revert AlreadySettled();
        settled = true;

        PoolKey memory key = _key;
        PoolId poolId = key.toId();
        // `graduate` checks the threshold and the opening-tax window, and this contract is the
        // only address the hook will accept it from. Making it part of this transaction is what
        // keeps the window the hook opens exactly one transaction long, and this function's own
        // permissionless entry is what keeps finishing a graduation open to anyone.
        if (ILaunchHook(HOOK).stateOf(poolId).phase == Phase.Trading) {
            ILaunchHook(HOOK).graduate(poolId);
        }
        if (ILaunchHook(HOOK).stateOf(poolId).phase != Phase.Graduated) revert NotGraduated();

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == TOKEN;
        (int24 fullLower, int24 fullUpper) = PoolMath.fullRangeTicks(key.tickSpacing);
        uint256 reserve = tokenReserve;
        tokenReserve = 0;

        bytes memory res = _execute(
            Job.Settle,
            abi.encode(
                SettleData({
                    key: key,
                    curveLower: tickLower,
                    curveUpper: tickUpper,
                    curveLiquidity: liquidity,
                    fullLower: fullLower,
                    fullUpper: fullUpper,
                    tokenIn: reserve,
                    quoteIn: free(QUOTE)
                })
            )
        );
        (uint256 fitted, uint256 left0, uint256 left1) =
            abi.decode(res, (uint256, uint256, uint256));
        // `PoolDeployer.fitLiquidity`, which `_fitFullRange` calls, never returns more than a
        // uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        permanentLiquidity = uint128(fitted);

        tickLower = fullLower;
        tickUpper = fullUpper;
        liquidity = permanentLiquidity;

        // Quote the permanent position could not pair is the treasury's, credited rather than
        // pushed: a blocked treasury must not be able to revert a launch's one-shot graduation.
        uint256 leftQuote = tokenIsCurrency0 ? left1 : left0;
        if (leftQuote != 0) _creditOwed(QUOTE, treasury(), leftQuote);

        _payAllocationSlice();

        // Everything still here that is not owed to someone and not the minters' slice was never
        // sold and is not needed to price the market. It leaves circulation, which is what the
        // curve rail did with the same remainder.
        burned = free(TOKEN);
        if (burned != 0) _transferExact(IERC20(TOKEN), BURN_SINK, burned);

        emit GraduationSettled(
            PoolId.unwrap(poolId),
            permanentLiquidity,
            ILaunchHook(HOOK).stateOf(poolId).raisedQuote,
            burned
        );
    }

    /// The minters' slice, or nothing when no minter contributed and it would be unclaimable.
    /// Gated on the vesting's own minter total rather than on the raise, so a slice with no
    /// beneficiaries falls through to the burn instead of sitting in a dead contract.
    function _payAllocationSlice() private {
        address vesting = allocationVesting;
        uint256 slice = allocationSlice;
        allocationSlice = 0;
        if (vesting == address(0) || slice == 0) return;
        if (IAllocationVesting(vesting).totalContribution() == 0) return;
        _transferExact(IERC20(TOKEN), vesting, slice);
        IAllocationVesting(vesting).onGraduation(slice);
    }

    /// @notice Sweep accrued swap fees without touching principal. A poke with zero liquidity
    ///         change credits only the fees the position has earned. The sweep lands here
    ///         first so it can be divided: the creator takes `CREATOR_FEE_BPS`, the treasury
    ///         the rest, and a launch with no creator sends everything to the treasury.
    ///         Anyone may call it; neither destination is chosen by the caller.
    ///
    ///         A Ripples pool charges no pool fee (the hook charges instead, and pays the
    ///         creator's share out of its own escrow), so this normally collects nothing. It
    ///         stays because the position is real and a pool that ever earned one would
    ///         otherwise have no way to divide it.
    function collectFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!seeded) revert NotSeeded();
        if (liquidity == 0) revert NothingToCollect();
        return _collectFees();
    }

    /// Collect and divide whatever the position has earned. Split out so `unlock` can settle the
    /// creator's share before principal leaves, without reentering the guard.
    function _collectFees() private returns (uint256 amount0, uint256 amount1) {
        // Fees are counted from what this contract actually receives, so a token that takes a
        // cut on transfer cannot make the split pay out more than arrived.
        uint256 before0 = _balanceOf(_key.currency0, address(this));
        uint256 before1 = _balanceOf(_key.currency1, address(this));
        bytes memory res = _execute(
            Job.Liquidity,
            abi.encode(
                CallbackData({
                    key: _key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    amount0Limit: 0,
                    amount1Limit: 0,
                    receiver: address(this)
                })
            )
        );
        (amount0, amount1) = abi.decode(res, (uint256, uint256));
        _verifyReceived(_key.currency0, address(this), before0, amount0);
        _verifyReceived(_key.currency1, address(this), before1, amount1);

        address to = treasury();
        (uint256 creator0, uint256 treasury0) = _payOut(_key.currency0, to, amount0);
        (uint256 creator1, uint256 treasury1) = _payOut(_key.currency1, to, amount1);
        emit FeesCollected(CREATOR, to, creator0, creator1, treasury0, treasury1);
    }

    /// @notice Withdraw principal once the lock has expired. Only the treasury may call,
    ///         and only after `UNLOCK_AT`; a permanent lock never reaches this. Fees the
    ///         position earned are collected and split first, so the withdrawal moves
    ///         principal alone.
    function unlock(uint128 amount, uint256 minAmount0, uint256 minAmount1, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (!seeded) revert NotSeeded();
        if (msg.sender != treasury()) revert NotAuthorized();
        if (UNLOCK_AT == type(uint64).max || block.timestamp < UNLOCK_AT) revert StillLocked();
        if (receiver == address(0)) revert NotAuthorized();
        if (amount == 0 || amount > liquidity) revert ZeroLiquidity();

        // Removing liquidity credits the position's uncollected fees along with its principal, so
        // sweep them first. Otherwise the receiver the treasury names would also take the
        // creator's share of fees the pool had already earned.
        _collectFees();

        uint256 before0 = _balanceOf(_key.currency0, receiver);
        uint256 before1 = _balanceOf(_key.currency1, receiver);
        liquidity -= amount;
        bytes memory res = _execute(
            Job.Liquidity,
            abi.encode(
                CallbackData({
                    key: _key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(amount)),
                    amount0Limit: minAmount0,
                    amount1Limit: minAmount1,
                    receiver: receiver
                })
            )
        );
        (amount0, amount1) = abi.decode(res, (uint256, uint256));
        _verifyReceived(_key.currency0, receiver, before0, amount0);
        _verifyReceived(_key.currency1, receiver, before1, amount1);
        emit Unlocked(receiver, amount, amount0, amount1);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        bytes32 expected = _callbackHash;
        if (expected == bytes32(0) || keccak256(raw) != expected) revert InvalidCallback();
        delete _callbackHash;

        (Job job, bytes memory payload) = abi.decode(raw, (Job, bytes));
        if (job == Job.Liquidity) return _runLiquidity(abi.decode(payload, (CallbackData)));
        if (job == Job.Settle) return _runSettle(abi.decode(payload, (SettleData)));
        return _runBuy(abi.decode(payload, (BuyData)));
    }

    function _runLiquidity(CallbackData memory data) private returns (bytes memory) {
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            data.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: data.tickLower,
                tickUpper: data.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );

        if (data.liquidityDelta > 0) {
            uint256 owed0 = _debt(delta.amount0());
            uint256 owed1 = _debt(delta.amount1());
            if (owed0 > data.amount0Limit || owed1 > data.amount1Limit) revert SlippageExceeded();
            _settleCurrency(data.key.currency0, owed0);
            _settleCurrency(data.key.currency1, owed1);
            return abi.encode(owed0, owed1);
        }

        uint256 amount0 = _credit(delta.amount0());
        uint256 amount1 = _credit(delta.amount1());
        if (amount0 < data.amount0Limit || amount1 < data.amount1Limit) revert SlippageExceeded();
        if (amount0 > 0) POOL_MANAGER.take(data.key.currency0, data.receiver, amount0);
        if (amount1 > 0) POOL_MANAGER.take(data.key.currency1, data.receiver, amount1);
        return abi.encode(amount0, amount1);
    }

    /// The whole graduation, inside one unlock. Nothing is taken out and paid back in between
    /// the two `modifyLiquidity` calls: what the curve position hands back stays as a credit
    /// against the manager and is spent straight into the permanent position.
    function _runSettle(SettleData memory d) private returns (bytes memory) {
        (uint256 avail0, uint256 avail1) = _retireCurve(d);
        uint128 fitted = _fitFullRange(d, avail0, avail1);
        (uint256 left0, uint256 left1) = _openPermanent(d, fitted, avail0, avail1);
        return abi.encode(uint256(fitted), left0, left1);
    }

    /// Take the curve position out whole and add everything this contract was holding to what it
    /// handed back. The hook refuses a partial retirement, so this is all of it.
    function _retireCurve(SettleData memory d) private returns (uint256 avail0, uint256 avail1) {
        (BalanceDelta removed,) = POOL_MANAGER.modifyLiquidity(
            d.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: d.curveLower,
                tickUpper: d.curveUpper,
                liquidityDelta: -int256(uint256(d.curveLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        avail0 = _credit(removed.amount0());
        avail1 = _credit(removed.amount1());

        bool tokenIsCurrency0 = Currency.unwrap(d.key.currency0) == TOKEN;
        uint256 in0 = tokenIsCurrency0 ? d.tokenIn : d.quoteIn;
        uint256 in1 = tokenIsCurrency0 ? d.quoteIn : d.tokenIn;
        _settleCurrency(d.key.currency0, in0);
        _settleCurrency(d.key.currency1, in1);
        avail0 += in0;
        avail1 += in1;
    }

    function _fitFullRange(SettleData memory d, uint256 avail0, uint256 avail1)
        private
        view
        returns (uint128 fitted)
    {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(d.key.toId());
        fitted = PoolDeployer.fitLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(d.fullLower),
            TickMath.getSqrtPriceAtTick(d.fullUpper),
            avail0,
            avail1,
            d.key.tickSpacing
        );
        if (fitted == 0) revert ZeroLiquidity();
    }

    function _openPermanent(SettleData memory d, uint128 fitted, uint256 avail0, uint256 avail1)
        private
        returns (uint256 left0, uint256 left1)
    {
        (BalanceDelta added,) = POOL_MANAGER.modifyLiquidity(
            d.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: d.fullLower,
                tickUpper: d.fullUpper,
                liquidityDelta: int256(uint256(fitted)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 owed0 = _debt(added.amount0());
        uint256 owed1 = _debt(added.amount1());
        if (owed0 > avail0 || owed1 > avail1) revert SlippageExceeded();
        left0 = avail0 - owed0;
        left1 = avail1 - owed1;
        if (left0 > 0) POOL_MANAGER.take(d.key.currency0, address(this), left0);
        if (left1 > 0) POOL_MANAGER.take(d.key.currency1, address(this), left1);
    }

    /// The creator's opening buy: exact input, with the price limit at the far end of the curve's
    /// own range so an oversized buy fills to the top and leaves the rest unspent rather than
    /// reverting the whole launch.
    function _runBuy(BuyData memory d) private returns (bytes memory) {
        BalanceDelta delta = POOL_MANAGER.swap(
            d.key,
            IPoolManager.SwapParams({
                zeroForOne: d.quoteIsCurrency0,
                amountSpecified: -int256(d.quoteIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(
                    d.quoteIsCurrency0 ? tickLower : tickUpper
                )
            }),
            ""
        );
        (int128 quoteSide, int128 tokenSide) = d.quoteIsCurrency0
            ? (delta.amount0(), delta.amount1())
            : (delta.amount1(), delta.amount0());
        uint256 spent = _debt(quoteSide);
        uint256 tokensOut = _credit(tokenSide);
        if (tokensOut < d.minTokensOut) revert InsufficientOutput();

        Currency quoteCurrency = d.quoteIsCurrency0 ? d.key.currency0 : d.key.currency1;
        Currency tokenCurrency = d.quoteIsCurrency0 ? d.key.currency1 : d.key.currency0;
        _settleCurrency(quoteCurrency, spent);
        if (tokensOut > 0) POOL_MANAGER.take(tokenCurrency, d.recipient, tokensOut);
        // The price limit can leave part of the buy unspent. It goes straight back to the
        // address that receives the tokens, which is the address that funded it; nothing about
        // it is ever the launch's money.
        if (spent < d.quoteIn) {
            _transferExact(IERC20(QUOTE), d.recipient, d.quoteIn - spent);
        }
        return abi.encode(tokensOut);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() external view returns (bytes32) {
        return PoolId.unwrap(_key.toId());
    }

    /// @notice Forward any token held directly by the locker to the treasury. V4 LP principal
    ///         lives in the PoolManager position, so direct balances are only seed dust or
    ///         unsolicited transfers and are not part of the locked position.
    function sweepToken(IERC20 token) external nonReentrant returns (uint256 amount) {
        // `free`, not the raw balance: a credited fee split is already promised to the creator
        // and the treasury, the launch's unsold supply is promised to the permanent position and
        // the burn, and the minters' slice is promised to them. Everything a sweep can reach is
        // genuinely unattributed.
        amount = free(address(token));
        if (amount == 0) revert NothingToSweep();
        address to = treasury();
        _transferExact(token, to, amount);
        emit TokenSwept(address(token), to, amount);
    }

    /// The only balance a whole-balance read here may touch: what is held, less what is owed and
    /// less what the launch has already promised somewhere.
    ///
    /// On the quote side the promise is the minters' raise: between a linked collection's first
    /// mint and the settlement, everything routed in belongs to the permanent position, and
    /// without this a `sweepToken(QUOTE)` in that window would hand the whole raise to the
    /// treasury. The settlement clears the promise before it reads `free(QUOTE)`, which is how
    /// the raise reaches the pool.
    ///
    /// Clamped at zero because a stock quote's issuer can seize from this contract, and a balance
    /// below what is promised must degrade `sweepToken` and the settlement rather than panic. The
    /// unpaid credit stays on the ledger and `_claim` reverts inside the token, which is the hold.
    function free(address token) public view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 promised = totalOwed[token];
        if (token == TOKEN) promised += tokenReserve + allocationSlice;
        if (token == QUOTE && !settled) promised += contributedQuote;
        return bal > promised ? bal - promised : 0;
    }

    /// @notice Take what this locker owes you: your share of the pool fees it has collected,
    ///         and the graduation surplus if you are the treasury. `NothingOwed()` at zero.
    function claim(address token) external nonReentrant returns (uint256 amount) {
        return _claim(token, msg.sender);
    }

    /// @notice Take what this locker owes `account` and pay it to `account`. Permissionless,
    ///         and it never pays anyone but `account`.
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
        _transferExact(IERC20(token), account, amount);
        emit Claimed(token, account, amount);
    }

    function treasury() public view returns (address) {
        if (FACTORY.code.length == 0) return TREASURY;
        try ITokenLaunchpad(FACTORY).treasury() returns (address current) {
            if (current != address(0)) return current;
        } catch { }
        return TREASURY;
    }

    function _execute(Job job, bytes memory payload) private returns (bytes memory result) {
        bytes memory raw = abi.encode(job, payload);
        _callbackHash = keccak256(raw);
        result = POOL_MANAGER.unlock(raw);
        if (_callbackHash != bytes32(0)) revert CallbackNotConsumed();
    }

    function _settleCurrency(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        POOL_MANAGER.sync(currency);
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(address(POOL_MANAGER), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance > before || before - afterBalance != amount) revert TransferMismatch();
        if (POOL_MANAGER.settle() != amount) revert TransferMismatch();
    }

    /// Divide one currency's collected fees. The creator's share rounds down, so the odd unit of
    /// the quote's smallest denomination stays with the treasury and nothing is left unassigned
    /// in the locker. Both halves are credited: neither side's issuer-imposed block can stop the
    /// other being recorded, and each takes its own money with `claim`.
    function _payOut(Currency currency, address treasuryTo, uint256 amount)
        private
        returns (uint256 creatorAmount, uint256 treasuryAmount)
    {
        if (amount == 0) return (0, 0);
        creatorAmount = (amount * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        treasuryAmount = amount - creatorAmount;
        address token = Currency.unwrap(currency);
        if (creatorAmount > 0) _creditOwed(token, CREATOR, creatorAmount);
        if (treasuryAmount > 0) _creditOwed(token, treasuryTo, treasuryAmount);
    }

    function _creditOwed(address token, address account, uint256 amount) private {
        owed[token][account] += amount;
        totalOwed[token] += amount;
        emit Credited(token, account, amount);
    }

    function _balanceOf(Currency currency, address account) private view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    function _verifyReceived(Currency currency, address receiver, uint256 before, uint256 expected)
        private
        view
    {
        uint256 afterBalance = _balanceOf(currency, receiver);
        if (afterBalance < before || afterBalance - before != expected) revert TransferMismatch();
    }

    /// Pull `amount` and prove it landed by weighing both sides. A quote that reports success
    /// without moving funds, or one that takes a cut on transfer, is caught here.
    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(from);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 fromAfter = token.balanceOf(from);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (
            fromAfter > fromBefore || fromBefore - fromAfter != amount
                || balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount
        ) revert TransferMismatch();
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private {
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 receiverAfter = token.balanceOf(to);
        if (senderAfter > senderBefore || senderBefore - senderAfter != amount) {
            revert TransferMismatch();
        }
        if (receiverAfter < receiverBefore || receiverAfter - receiverBefore != amount) {
            revert TransferMismatch();
        }
    }

    function _debt(int128 amount) private pure returns (uint256) {
        if (amount > 0) revert UnexpectedDebt();
        // amount is non-positive here, so -amount is a non-negative int128 that fits uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(-amount));
    }

    function _credit(int128 amount) private pure returns (uint256) {
        if (amount < 0) revert UnexpectedDebt();
        // amount is non-negative here, so the narrowing to uint128 is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(amount));
    }
}
