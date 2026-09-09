// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

/// @notice Prints the pool numbers for the terminal test, so the range, the price and the seed
///         amount are read off the same TickMath and SqrtPriceMath the PoolManager uses rather
///         than off a spreadsheet. Read-only; run with `forge script`, never broadcast.
contract TerminalTestMath is Script {
    int24 internal constant TICK_LOWER = -207_200;
    int24 internal constant TICK_UPPER = -193_400;
    uint256 internal constant TARGET_SEED = 250_000_000e18;

    function run() external pure {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        console2.log("tickLower        ", TICK_LOWER);
        console2.log("tickUpper        ", TICK_UPPER);
        console2.log("sqrtLowerX96     ", sqrtLower);
        console2.log("sqrtUpperX96     ", sqrtUpper);
        console2.log("tickAt(sqrtLower)", TickMath.getTickAtSqrtPrice(sqrtLower));

        // liquidity for a token-only deposit over the range: L = amount0 * (sA*sB/2^96) / (sB-sA)
        uint256 intermediate = FullMath.mulDiv(sqrtLower, sqrtUpper, FixedPoint96.Q96);
        uint128 liquidity =
            uint128(FullMath.mulDiv(TARGET_SEED, intermediate, sqrtUpper - sqrtLower));
        console2.log("liquidity        ", liquidity);

        // What the position actually costs at the bottom of the range, rounded the way the
        // PoolManager rounds an add.
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        console2.log("amount0 (TTEST)  ", amount0);

        // What it costs to buy the whole position out, i.e. to walk price from the bottom of the
        // range to the top: the quote the range absorbs in full.
        uint256 fullQuote = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        console2.log("range absorbs WETH", fullQuote);

        // Price at each end, as WETH wei per whole TTEST (1e18 base units).
        console2.log("price lo (wei/T) ", _priceWeiPerToken(sqrtLower));
        console2.log("price hi (wei/T) ", _priceWeiPerToken(sqrtUpper));

        // Where a 0.002 WETH exact-input buy lands: new sqrt price, tick, and tokens out.
        uint160 sqrtAfter =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtLower, liquidity, 0.002 ether, false);
        console2.log("sqrtAfter 0.002  ", sqrtAfter);
        console2.log("tickAfter 0.002  ", TickMath.getTickAtSqrtPrice(sqrtAfter));
        console2.log(
            "TTEST out 0.002  ",
            SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtAfter, liquidity, false)
        );
    }

    function _priceWeiPerToken(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96) * uint256(sqrtPriceX96), 1e18, 1 << 192);
    }
}
