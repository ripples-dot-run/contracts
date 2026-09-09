// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

/// Helpers for seeding a fresh Uniswap V4 pool from a pair of token amounts: the initial
/// square-root price the amounts imply, and the widest tick range a given spacing allows.
library PoolMath {
    error PriceOutOfRange();

    /// sqrt(amount1 / amount0) in Q64.96, the price currency1-per-currency0 the reserves
    /// imply. Scaling in two steps keeps the intermediate inside 256 bits for the amount
    /// sizes a launch produces.
    ///
    /// The two amounts do **not** have to share decimals, and since per-launch quotes they
    /// routinely do not: a 6-decimal quote against an 18-decimal launch token is a ratio twelve
    /// orders of magnitude from 1. That is fine, and the real bound is stated here rather than
    /// assumed. The tickable band is roughly `2**-128` to `2**128` in price, so a pair whose
    /// implied ratio falls outside it reverts `PriceOutOfRange`: it never returns a truncated
    /// `uint160`, which would be a pool opened at a price nobody chose. The factory probes this
    /// at create, at both ends of the raise and in both currency orderings
    /// (`TokenLaunchFactory._validate`), so a configuration that could not open its pool is
    /// refused before a creator pays for it rather than discovered at graduation, after the
    /// money is in and the one-shot call is the only way out.
    function initialSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 ratioX96 = Math.mulDiv(amount1, FixedPoint96.Q96, amount0);
        uint256 priceX96 = Math.sqrt(ratioX96) << 48;
        if (priceX96 <= TickMath.MIN_SQRT_PRICE || priceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
        // Bounded above by MAX_SQRT_PRICE, which is below 2**160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(priceX96);
    }

    /// The widest position a pool of this spacing supports. Truncation toward zero keeps
    /// both bounds inside [MIN_TICK, MAX_TICK] and aligned to the spacing.
    function fullRangeTicks(int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Aligning to spacing needs the divide before the multiply; that is the point.
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }
}
