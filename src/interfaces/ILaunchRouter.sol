// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @notice Trading a Ripples market without a buy having to guess how much of the curve is left.
///
/// A Ripples launch is a Uniswap v4 pool whose liquidity sits in one bounded range, and the hook
/// refuses any swap that would end outside it. Uniswap's Universal Router places an exact-input
/// swap with no price limit, so an order larger than the curve can still serve tries to push the
/// price past the range and is refused whole. The last buyer before graduation therefore has to
/// size their order to the remaining capacity to the wei or watch it revert, which is the one
/// order on a launch that a trader most wants to send oversized.
///
/// This router places the same swap with the curve's own range end as its price limit. v4 fills
/// to that end and stops, so an oversized buy takes everything left on the curve, and the quote it
/// did not reach never leaves the buyer's wallet. `spent` is what the pool consumed, `amountOut`
/// is what came back, and a caller that reads `spent < amountIn` knows the order filled partially
/// and the curve is at its end.
///
/// **The floor a caller passes.** `minAmountOut` is a floor on the rate over the whole order; a
/// caller quoting a part-fill must scale its floor to `amountIn`. The router holds
/// `amountOut >= minAmountOut * spent / amountIn`, rounded up against the caller, so a whole fill
/// is held to exactly `amountOut >= minAmountOut` and a clamped one is held to the same price on
/// the share the pool served. A floor taken straight from a quote that was already capped at the
/// remaining curve binds at only that share of itself, so scaling it back up to `amountIn` before
/// signing is the caller's job.
interface ILaunchRouter {
    /// A trade cleared. `spent` below `amountIn` is a partial fill: the curve reached its range
    /// end and the difference was never taken from `sender`. The web reads this to tell a buyer
    /// their order filled in part.
    event Filled(
        PoolId indexed poolId,
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 spent,
        uint256 amountOut
    );

    /// The deadline the caller signed has passed.
    error Expired();
    /// An order for nothing.
    error ZeroAmount();
    /// A zero recipient, or a zero constructor argument.
    error ZeroAddress();
    /// The recipient is the router itself. It has no owner, no sweep and no reason to hold a
    /// balance between calls, so output taken there would sit in it for good.
    error RecipientIsRouter();
    /// The pool key names a hook this router does not serve. It exists so the router cannot be
    /// pointed at a foreign pool, where the curve's range end would be a price limit invented out
    /// of another launch's plan.
    error NotOurPool();
    /// The launch takes no order in the phase it is in. This router fills to the curve's range
    /// end while a launch is trading, and against the permanent position once it is locked. A
    /// registered launch has no pool yet and a graduated one is between positions; the hook
    /// refuses a swap in both, and its range guard is still armed in the second, so there is no
    /// price limit here for this router to name.
    error NotTradable();
    /// The callback arrived from an address that is not the PoolManager.
    error NotPoolManager();
    /// The input side is native ETH. A Permit2 allowance cannot move ETH and this router takes
    /// no value, so a buy on a natively quoted pool belongs elsewhere. Every Ripples market on
    /// Robinhood Chain settles in WETH.
    error NativeInputUnsupported();
    /// The price is already at the end of the curve in the direction the order would move it, so
    /// there is nothing left to fill. On a buy the curve is sold out and the launch is ready to
    /// graduate; on a sell the market is back at its opening price.
    error CurveEndReached();
    /// The fill came in under the rate the caller named.
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    /// The PoolManager's books disagree with what the router just paid or was owed. It means an
    /// input asset that moved less than it reported, and the swap is unwound whole.
    error UnexpectedDelta();

    /// @notice Swap an exact input on a Ripples pool, filling to the end of the curve when the
    ///         order is larger than the curve can still serve.
    /// @param key          The launch's pool key. Its hook must be the one this router serves.
    /// @param zeroForOne   true sells `currency0`, false sells `currency1`. A buy is whichever
    ///                     direction puts the quote into the pool.
    /// @param amountIn     The most the caller is willing to spend, pulled through Permit2 as the
    ///                     pool consumes it. What the pool does not consume is never pulled.
    /// @param minAmountOut The floor on the fill, read as a rate over `amountIn`.
    /// @param recipient    Where the output goes. May be an address other than the caller.
    /// @param deadline     The last block timestamp this order may be filled in.
    /// @return spent       What the pool consumed, at most `amountIn`.
    /// @return amountOut   What the recipient received, net of the hook's fee.
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 spent, uint256 amountOut);
}
