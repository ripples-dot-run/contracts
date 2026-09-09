// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FixedPoint96 } from "v4-core/src/libraries/FixedPoint96.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// Liquidity a range can hold given amounts of each token, ported from the Uniswap V4
/// periphery helper. Returns the largest liquidity the pair can back without exceeding
/// either amount, so the caller refunds whatever the position did not consume.
library LiquidityAmounts {
    error LiquidityOverflow();

    function forAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return _toUint128(_forAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0));
        }
        if (sqrtPriceX96 >= sqrtPriceBX96) {
            return _toUint128(_forAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1));
        }

        uint256 liquidity0 = _forAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
        uint256 liquidity1 = _forAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
        return _toUint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1);
    }

    /// @notice Whether the liquidity backed by `amount0` and `amount1` exceeds `cap`.
    /// @dev Compares the full 512-bit products instead of first narrowing the liquidity to
    ///      uint128. This lets callers reject an oversized position before `forAmounts` or the
    ///      PoolManager reverts on the same input.
    function exceedsCap(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1,
        uint128 cap
    ) internal pure returns (bool) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return _amount0Exceeds(sqrtPriceAX96, sqrtPriceBX96, amount0, cap);
        }
        if (sqrtPriceX96 >= sqrtPriceBX96) {
            return _mulDivExceeds(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96, cap);
        }

        return _amount0Exceeds(sqrtPriceX96, sqrtPriceBX96, amount0, cap)
            && _mulDivExceeds(amount1, FixedPoint96.Q96, sqrtPriceX96 - sqrtPriceAX96, cap);
    }

    /// @notice Whether V4's rounded-up principal delta cannot fit in BalanceDelta's int128 leg.
    function deltaExceedsInt128(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (bool) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            return
                SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true)
                    > maxDelta;
        }
        if (sqrtPriceX96 >= sqrtPriceBX96) {
            return
                SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, true)
                    > maxDelta;
        }

        return SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, true)
                > maxDelta
            || SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, true)
                > maxDelta;
    }

    function _forAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        private
        pure
        returns (uint256)
    {
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        uint256 denominator = sqrtPriceBX96 - sqrtPriceAX96;
        if (_mulDivExceeds(amount0, intermediate, denominator, type(uint128).max)) {
            return uint256(type(uint128).max) + 1;
        }
        return FullMath.mulDiv(amount0, intermediate, denominator);
    }

    function _forAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        private
        pure
        returns (uint256)
    {
        uint256 denominator = sqrtPriceBX96 - sqrtPriceAX96;
        if (_mulDivExceeds(amount1, FixedPoint96.Q96, denominator, type(uint128).max)) {
            return uint256(type(uint128).max) + 1;
        }
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, denominator);
    }

    function _amount0Exceeds(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint128 cap
    ) private pure returns (bool) {
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        return _mulDivExceeds(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96, cap);
    }

    /// floor(x * y / denominator) > cap iff x * y >= (cap + 1) * denominator.
    function _mulDivExceeds(uint256 x, uint256 y, uint256 denominator, uint128 cap)
        private
        pure
        returns (bool)
    {
        (uint256 productHigh, uint256 productLow) = Math.mul512(x, y);
        (uint256 limitHigh, uint256 limitLow) = Math.mul512(uint256(cap) + 1, denominator);
        return productHigh > limitHigh || (productHigh == limitHigh && productLow >= limitLow);
    }

    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        // Any truncation is caught by the equality check below, which reverts.
        // forge-lint: disable-next-line(unsafe-typecast)
        narrowed = uint128(value);
        if (narrowed != value) revert LiquidityOverflow();
    }
}
