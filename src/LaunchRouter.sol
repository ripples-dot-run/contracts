// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { ILaunchHook, Phase, SeedPlan } from "./hook/interfaces/ILaunchHook.sol";
import { IAllowanceTransfer } from "./interfaces/IAllowanceTransfer.sol";
import { ILaunchRouter } from "./interfaces/ILaunchRouter.sol";

/// @notice The router a Ripples market is traded through, so an oversized buy fills to the end of
///         the curve instead of reverting.
///
/// `ILaunchRouter` carries the reason a wide price limit fails on a bounded curve, why the range
/// end is the limit that turns that refusal into a partial fill, and what `minAmountOut` means
/// over an order the curve only part-filled. `contracts/test/SnipeAdversarial.t.sol` proves both
/// halves against the pool itself.
///
/// **Why the money is settled off the PoolManager's books.** The hook takes its cut in
/// `afterSwap`, out of the swap's unspecified side, so the delta a swapper actually owes or is
/// owed is not the delta the pool priced. This router reads its own `currencyDelta` back from the
/// manager after the swap and settles that, which is the figure the hook already adjusted. It
/// pulls the input straight from the caller into the PoolManager for exactly what was consumed,
/// so the unfilled part of an order is never moved at all: there is no refund leg, because there
/// is nothing to refund.
///
/// **What it is not.** It has no owner, no pause, no fee and no allowlist, it never holds a
/// balance between calls, and it serves one hook. Anyone may call it, for anyone's pool on that
/// hook, and there is nothing in it for an operator to switch off.
contract LaunchRouter is ILaunchRouter, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;
    /// The one hook this router serves. A foreign pool is refused, because the price limit is
    /// read out of this hook's plan for the pool id and applying one launch's range to another
    /// pool's price would be a guess.
    ILaunchHook public immutable HOOK;
    IAllowanceTransfer public immutable PERMIT2;

    /// The order, carried across the manager's unlock. `amountSpecified` is negative because a
    /// Ripples launch only trades exact input: the hook refuses an exact-output buy for as long
    /// as the opening tax would charge, and this router never asks for one. `poolId` rides along
    /// so the hash of the key is taken once for the whole call.
    struct Job {
        PoolKey key;
        PoolId poolId;
        address sender;
        address recipient;
        bool zeroForOne;
        int256 amountSpecified;
    }

    constructor(IPoolManager poolManager, ILaunchHook hook, IAllowanceTransfer permit2) {
        if (
            address(poolManager) == address(0) || address(hook) == address(0)
                || address(permit2) == address(0)
        ) revert ZeroAddress();
        POOL_MANAGER = poolManager;
        HOOK = hook;
        PERMIT2 = permit2;
    }

    /// @inheritdoc ILaunchRouter
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 spent, uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        // No owner and no sweep, so a fill taken to the router never comes out of it again.
        if (recipient == address(this)) revert RecipientIsRouter();
        if (address(key.hooks) != address(HOOK)) revert NotOurPool();
        // A Permit2 allowance moves ERC-20 balances and nothing else, and this router takes no
        // value, so a native input has nothing to fund it. The pool key alone settles that, so it
        // is settled before the unlock, where the revert still reaches the caller unwrapped.
        if (Currency.unwrap(zeroForOne ? key.currency0 : key.currency1) == address(0)) {
            revert NativeInputUnsupported();
        }

        PoolId poolId = key.toId();
        (spent, amountOut) = abi.decode(
            POOL_MANAGER.unlock(
                abi.encode(
                    Job({
                        key: key,
                        poolId: poolId,
                        sender: msg.sender,
                        recipient: recipient,
                        zeroForOne: zeroForOne,
                        // Bounded before the unlock too, so an impossible size reverts unwrapped.
                        amountSpecified: -int256(amountIn.toInt128())
                    })
                )
            ),
            (uint256, uint256)
        );

        // `ILaunchRouter` says what `minAmountOut` means. Written as
        // `spent * minAmountOut > amountIn * amountOut` this is the same test, and the rounding
        // is against the caller so a fill that ties passes.
        if (amountOut < FullMath.mulDivRoundingUp(minAmountOut, spent, amountIn)) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        emit Filled(poolId, msg.sender, recipient, zeroForOne, amountIn, spent, amountOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        // The manager only ever calls back the address that unlocked it, and the only unlock this
        // contract opens is the one above, which is `nonReentrant`.
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Job memory job = abi.decode(raw, (Job));

        (Currency inCurrency, Currency outCurrency) = job.zeroForOne
            ? (job.key.currency0, job.key.currency1)
            : (job.key.currency1, job.key.currency0);

        POOL_MANAGER.swap(
            job.key,
            IPoolManager.SwapParams({
                zeroForOne: job.zeroForOne,
                amountSpecified: job.amountSpecified,
                sqrtPriceLimitX96: _priceLimit(job.poolId, job.zeroForOne)
            }),
            ""
        );

        // Read back rather than taken from the returned delta: the hook's `afterSwap` charges its
        // fee out of the swap's unspecified side, and what the router owes and is owed after that
        // charge is what the manager's own books say.
        int256 inDelta = POOL_MANAGER.currencyDelta(address(this), inCurrency);
        int256 outDelta = POOL_MANAGER.currencyDelta(address(this), outCurrency);
        if (inDelta > 0 || outDelta < 0) revert UnexpectedDelta();
        // Both signs are settled on the line above, so neither cast can wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 spent = uint256(-inDelta);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = uint256(outDelta);
        // The pre-swap check above leaves room, so a fill of nothing means the room was smaller
        // than one wei of the input. Same answer as reaching the end, and better than charging
        // gas for a trade that moved nothing.
        if (spent == 0) revert CurveEndReached();

        POOL_MANAGER.sync(inCurrency);
        PERMIT2.transferFrom(
            job.sender, address(POOL_MANAGER), spent.toUint160(), Currency.unwrap(inCurrency)
        );
        // An asset that reports a transfer it did not make settles short here, and the whole swap
        // unwinds. Nothing is left behind for the next caller to pay for.
        if (POOL_MANAGER.settle() != spent) revert UnexpectedDelta();

        if (amountOut != 0) POOL_MANAGER.take(outCurrency, job.recipient, amountOut);
        return abi.encode(spent, amountOut);
    }

    /// The price a swap on this pool is allowed to walk to.
    ///
    /// While the launch is a curve that is the end of its own range in the direction this order
    /// moves the price, which is what turns an oversized order into a fill to the end. The
    /// direction is `zeroForOne` and nothing else: selling `currency0` walks the price down toward
    /// the lower tick and selling `currency1` walks it up toward the upper one. Which of those two
    /// is a buy depends on which side of the key the quote sorts on, and the caller has already
    /// settled that.
    ///
    /// The wide limit belongs to `Locked` alone. The permanent position is full range by then and
    /// there is no end to stop on. Reading "no range" off "not `Trading`" would be wrong one phase
    /// earlier: the hook's range guard is still armed in `Graduated`, so a wide limit there would
    /// walk the price out of a range the hook still holds. Every other phase, a pool id this hook
    /// never registered among them, is named instead.
    ///
    /// The room check is the difference between a named refusal and a wrapped one. v4 rejects a
    /// limit that is already at the price, so a buy sent after the curve sold out would come back
    /// as `PriceLimitAlreadyExceeded` from inside the manager. A caller has to be able to tell
    /// "this launch is ready to graduate" from "something broke".
    function _priceLimit(PoolId poolId, bool zeroForOne) private view returns (uint160 limit) {
        Phase phase = HOOK.stateOf(poolId).phase;
        if (phase == Phase.Locked) {
            return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        if (phase != Phase.Trading) revert NotTradable();

        SeedPlan memory plan = HOOK.planOf(poolId);
        limit = TickMath.getSqrtPriceAtTick(zeroForOne ? plan.tickLower : plan.tickUpper);
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (zeroForOne ? limit >= sqrtPriceX96 : limit <= sqrtPriceX96) revert CurveEndReached();
    }
}
