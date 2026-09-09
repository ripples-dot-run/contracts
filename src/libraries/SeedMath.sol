// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PoolMath } from "./PoolMath.sol";

/// The bonding curve, restated as one Uniswap v4 position.
///
/// A v4 position over `[a, b]` with liquidity `L` behaves as a constant-product market whose
/// reserves are `x = L/sqrt(P) - L/sqrt(b)` and `y = L*sqrt(P) - L*sqrt(a)`. Those are virtual
/// reserves, which is the same object the curve rail kept in `vQuote` and `vToken`, so the two
/// curves are not merely similar: put the range's ends at the launch price and the graduation
/// price and set `L = sqrt(vQuoteInit * vTokenInit)`, and the position walks the identical price
/// schedule and takes in the identical quote at every point along it.
///
/// This library derives that position from the parameters a launch already declares. Two things
/// the arithmetic cannot give away for free, and both are resolved toward the trader:
///
/// 1. **The tick grid.** A pool opens at a tick, not at a price, and Ripples pools use a spacing
///    of 200, whose steps are about 2% apart. `tickLower` is rounded **down** and `tickUpper`
///    **up**, in the launch token's own price direction and in either currency ordering, so the
///    band the pool trades always contains the band the curve described and the opening price is
///    never above the price the launch declared. The residual is measured, per quote row, in
///    `docs/plans/2026-09-05-pool-curve-design.md`, and pinned by
///    `contracts/test/hook/LaunchHookCurveParity.t.sol`.
/// 2. **The rounding of `L`.** Liquidity is rounded up, so traversing the whole range takes in at
///    least `graduationQuote` and the launch can always reach its target by trading. `plan`
///    asserts that with v4's own amount math rather than trusting the algebra.
library SeedMath {
    /// The launch's price band does not fit the tick grid: the two ends align to the same tick,
    /// so there is no room for a position between them.
    error RangeTooNarrow();
    /// The position's liquidity does not fit `uint128`, or its token side does not fit the
    /// `int128` leg of a v4 balance delta. Either way the pool could not open it.
    error SeedTooLarge();
    /// Liquidity rounded up still does not carry the raise across the range. Unreachable for any
    /// range wider than one tick; asserted rather than assumed.
    error RaiseUnreachable();
    /// A reserve of zero has no price.
    error ZeroReserves();

    /// @notice The position a launch opens.
    /// @param vQuoteInit The curve's virtual quote reserve, in the quote's smallest unit.
    /// @param vTokenInit The curve's virtual token reserve, in the token's smallest unit.
    /// @param graduationQuote The raise that fills the position, in the quote's smallest unit.
    /// @param tickSpacing The pool's tick spacing.
    /// @param tokenIsCurrency0 Whether the launch token sorts below the quote, which v4 decides
    ///        by address and native ETH always wins.
    /// @return sqrtPriceX96 The price to initialize the pool at: the end of the range the token
    ///         sits at, so the position needs no quote.
    /// @return tickLower The bottom of the range.
    /// @return tickUpper The top of the range.
    /// @return liquidity The position's liquidity.
    /// @return tokenAmount The launch token the position consumes, which is what the seeding
    ///         address must hold. Rounded the way v4 rounds a deposit, so it is exact.
    function plan(
        uint256 vQuoteInit,
        uint256 vTokenInit,
        uint256 graduationQuote,
        int24 tickSpacing,
        bool tokenIsCurrency0
    )
        internal
        pure
        returns (
            uint160 sqrtPriceX96,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 tokenAmount
        )
    {
        if (vQuoteInit == 0 || vTokenInit == 0 || graduationQuote == 0) {
            revert ZeroReserves();
        }

        // The two ends of the curve, in the pool's own orientation. The graduation price is the
        // launch price scaled by `((vQuoteInit + raise) / vQuoteInit)^2`, so its square root is
        // the launch price's square root scaled by that ratio once, which needs no squaring and
        // cannot overflow on the way.
        uint160 sqrtLaunchX96;
        uint160 sqrtGradX96;
        if (tokenIsCurrency0) {
            sqrtLaunchX96 = PoolMath.initialSqrtPriceX96(vTokenInit, vQuoteInit);
            sqrtGradX96 = _scale(sqrtLaunchX96, vQuoteInit + graduationQuote, vQuoteInit);
        } else {
            sqrtLaunchX96 = PoolMath.initialSqrtPriceX96(vQuoteInit, vTokenInit);
            sqrtGradX96 = _scale(sqrtLaunchX96, vQuoteInit, vQuoteInit + graduationQuote);
        }

        // Rounded outward in the token's price direction: the pool opens at or below the price
        // the launch declared, and its top is at or above the price the raise implies.
        if (tokenIsCurrency0) {
            tickLower = _floorTick(sqrtLaunchX96, tickSpacing);
            tickUpper = _ceilTick(sqrtGradX96, tickSpacing);
        } else {
            tickLower = _floorTick(sqrtGradX96, tickSpacing);
            tickUpper = _ceilTick(sqrtLaunchX96, tickSpacing);
        }
        if (tickLower >= tickUpper) revert RangeTooNarrow();

        uint160 sqrtAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        // Single sided: the pool opens at the end of the range the token occupies, so the
        // position is pure launch token and the seeding address brings no quote at all.
        sqrtPriceX96 = tokenIsCurrency0 ? sqrtAX96 : sqrtBX96;

        liquidity = _liquidityForRaise(sqrtAX96, sqrtBX96, graduationQuote, tokenIsCurrency0);
        if (quoteAcross(sqrtAX96, sqrtBX96, liquidity, !tokenIsCurrency0) < graduationQuote) {
            revert RaiseUnreachable();
        }

        tokenAmount = tokenIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtAX96, sqrtBX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtAX96, sqrtBX96, liquidity, true);
        if (tokenAmount > uint256(uint128(type(int128).max))) revert SeedTooLarge();
    }

    /// @notice The quote a position holds at `sqrtPriceX96`, which is the raise so far. Rounded
    ///         down, the way v4 pays a withdrawal, so the figure a threshold is tested against is
    ///         never more than the position could hand back.
    /// @param quoteIsCurrency0 Whether the quote sorts below the launch token.
    function quoteHeld(
        uint160 sqrtPriceX96,
        uint160 sqrtAX96,
        uint160 sqrtBX96,
        uint128 liquidity,
        bool quoteIsCurrency0
    ) internal pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0;
        if (quoteIsCurrency0) {
            // The quote is currency0, so the token appreciates as the pool price falls. The
            // position holds quote below the live price.
            if (sqrtPriceX96 >= sqrtBX96) return 0;
            uint160 from = sqrtPriceX96 > sqrtAX96 ? sqrtPriceX96 : sqrtAX96;
            return SqrtPriceMath.getAmount0Delta(from, sqrtBX96, liquidity, false);
        }
        if (sqrtPriceX96 <= sqrtAX96) return 0;
        uint160 to = sqrtPriceX96 < sqrtBX96 ? sqrtPriceX96 : sqrtBX96;
        return SqrtPriceMath.getAmount1Delta(sqrtAX96, to, liquidity, false);
    }

    /// @notice The quote a full traverse of the range takes in, rounded down. The raise the
    ///         position was sized for, measured rather than assumed.
    function quoteAcross(
        uint160 sqrtAX96,
        uint160 sqrtBX96,
        uint128 liquidity,
        bool quoteIsCurrency0
    ) internal pure returns (uint256) {
        return quoteIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtAX96, sqrtBX96, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(sqrtAX96, sqrtBX96, liquidity, false);
    }

    /// The liquidity whose full traverse takes in `raise`. Rounded up at every step, then
    /// checked by the caller against v4's own amount math.
    function _liquidityForRaise(
        uint160 sqrtAX96,
        uint160 sqrtBX96,
        uint256 raise,
        bool tokenIsCurrency0
    ) private pure returns (uint128) {
        uint256 gap = uint256(sqrtBX96) - uint256(sqrtAX96);
        uint256 value;
        if (tokenIsCurrency0) {
            // Quote is currency1: amount1 = L * (sqrtB - sqrtA) / 2**96.
            value = Math.mulDiv(raise, FixedPoint96.Q96, gap, Math.Rounding.Ceil);
        } else {
            // Quote is currency0: amount0 = L * 2**96 * (sqrtB - sqrtA) / (sqrtA * sqrtB).
            uint256 scaled = Math.mulDiv(raise, sqrtAX96, FixedPoint96.Q96, Math.Rounding.Ceil);
            value = Math.mulDiv(scaled, sqrtBX96, gap, Math.Rounding.Ceil);
        }
        // One unit of liquidity is worth a fraction of one unit of the quote at every range this
        // library can produce, so the increment costs the raise nothing and absorbs the two
        // nested floors v4's amount math applies on the way back out.
        if (value >= type(uint128).max) revert SeedTooLarge();
        // Bounded by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value + 1);
    }

    /// The greatest spacing-aligned tick at or below `sqrtPriceX96`.
    function _floorTick(uint160 sqrtPriceX96, int24 tickSpacing) private pure returns (int24) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // Aligning to spacing needs the divide before the multiply; that is the point.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && aligned != tick) aligned -= tickSpacing;
        return aligned;
    }

    /// The least spacing-aligned tick at or above `sqrtPriceX96`.
    function _ceilTick(uint160 sqrtPriceX96, int24 tickSpacing) private pure returns (int24) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // `getTickAtSqrtPrice` floors, so a price between ticks needs the next one up as well as
        // the alignment.
        if (TickMath.getSqrtPriceAtTick(tick) < sqrtPriceX96) tick += 1;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / tickSpacing) * tickSpacing;
        if (tick > 0 && aligned != tick) aligned += tickSpacing;
        return aligned;
    }

    /// `sqrtPriceX96 * sqrt(numerator/denominator)`, applied as one ratio rather than a square
    /// root, because the graduation price is the launch price times the square of that ratio.
    function _scale(uint160 sqrtPriceX96, uint256 numerator, uint256 denominator)
        private
        pure
        returns (uint160)
    {
        uint256 scaled = Math.mulDiv(sqrtPriceX96, numerator, denominator);
        if (scaled <= TickMath.MIN_SQRT_PRICE || scaled >= TickMath.MAX_SQRT_PRICE) {
            revert PoolMath.PriceOutOfRange();
        }
        // Bounded above by MAX_SQRT_PRICE, which is below 2**160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(scaled);
    }
}
