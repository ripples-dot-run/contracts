// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";

/// What a v4 hook is allowed to charge, and out of which side of the swap.
///
/// A hook that returns a delta from `afterSwap` may only take it in the swap's **unspecified**
/// currency: the output on an exact-input swap, the input on an exact-output one. There is no
/// choice in it, and it is the whole reason a fee here does not always arrive in the quote the way
/// the curve rail's did. This library holds the three pieces of arithmetic that follow from it, so
/// the hook body reads as policy rather than as bit twiddling and the rules are testable on their
/// own.
library HookFeeMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Which side of a swap the hook may charge on, and how much moved on that side.
    /// @dev The condition is v4's own: `Hooks.afterSwap` builds the hook's delta as
    ///      `amountSpecified < 0 == zeroForOne ? (specified, unspecified) : (unspecified,
    ///      specified)`, so the same test names the currency here.
    /// @return isCurrency1 Whether the unspecified side is `currency1`.
    /// @return amount The absolute amount that moved on that side.
    function unspecified(BalanceDelta delta, int256 amountSpecified, bool zeroForOne)
        internal
        pure
        returns (bool isCurrency1, uint256 amount)
    {
        isCurrency1 = (amountSpecified < 0) == zeroForOne;
        int128 side = isCurrency1 ? delta.amount1() : delta.amount0();
        // Both branches narrow a value already known non-negative, so neither truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = side < 0 ? uint256(uint128(-side)) : uint256(uint128(side));
    }

    /// @notice `bps` of `amount`, floored. The launch keeps the odd unit.
    function share(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (amount == 0 || bps == 0) return 0;
        return Math.mulDiv(amount, bps, BPS_DENOMINATOR);
    }

    /// @notice The opening tax rate now: `maxBps` at `launchedAt`, halved fourteen times over
    ///         `window`, and zero at or after it.
    ///
    /// @dev The shape matters more than the headline. A straight line from 99% to zero across
    ///      three seconds still charges an ordinary buyer 66% one second in, which is a penalty
    ///      aimed at snipers landing on someone who simply saw the launch. Fourteen halvings
    ///      spread evenly across the window put that buyer at 6.18% and the next second at 0.19%,
    ///      so the rate is punitive in the block a launch opens in and negligible immediately
    ///      after. Fourteen because 2^14 clears the 9,900 starting rate, which is what makes the
    ///      tax reach zero inside the window rather than cutting off at a live rate.
    function snipeBps(uint64 launchedAt, uint64 window, uint96 maxBps, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        if (window == 0 || maxBps == 0 || timestamp < launchedAt) return 0;
        uint256 elapsed = timestamp - launchedAt;
        if (elapsed >= window) return 0;
        return uint256(maxBps) >> ((elapsed * 14) / window);
    }
}
