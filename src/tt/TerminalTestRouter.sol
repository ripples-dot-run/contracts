// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @notice Minimal exact-input swap router, the shape v4-periphery's own test routers use:
///         `unlock`, swap, pay the debt, take the credit. Permissionless, holds nothing, and
///         pulls the input from the caller with `transferFrom`.
///
///         It exists because Uniswap's Universal Router on this chain
///         (`0x8876789976dEcBfCbBbe364623C63652db8C0904`) reverts with empty data on every
///         ERC-20/ERC-20 v4 pool tried against it, live third-party pools included, while
///         routing native-quoted pools normally. That is recorded in
///         `docs/qa/terminal-test-2026-09-06.md`; it is a property of that deployment, not of
///         this pool or its hook.
contract TerminalTestRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    error NotPoolManager();
    error TooLittleReceived(uint256 minimum, uint256 received);
    error UnexpectedDelta();

    event Swapped(address indexed payer, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    /// @param zeroForOne  true sells currency0 for currency1, false sells currency1 for currency0
    /// @param amountIn    exact input, taken from `msg.sender`
    /// @param minAmountOut floor on what comes back, or the swap reverts
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut
    ) external returns (uint256 amountOut) {
        amountOut = abi.decode(
            POOL_MANAGER.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn)), (uint256)
        );
        if (amountOut < minAmountOut) revert TooLittleReceived(minAmountOut, amountOut);
        emit Swapped(msg.sender, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (address payer, PoolKey memory key, bool zeroForOne, uint128 amountIn) =
            abi.decode(raw, (address, PoolKey, bool, uint128));

        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (int128 in_, int128 out_) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        (Currency inCurrency, Currency outCurrency) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (in_ > 0 || out_ < 0) revert UnexpectedDelta();

        uint256 owed = uint256(uint128(-in_));
        POOL_MANAGER.sync(inCurrency);
        IERC20(Currency.unwrap(inCurrency)).safeTransferFrom(payer, address(POOL_MANAGER), owed);
        if (POOL_MANAGER.settle() != owed) revert UnexpectedDelta();

        uint256 received = uint256(uint128(out_));
        if (received > 0) POOL_MANAGER.take(outCurrency, payer, received);
        return abi.encode(received);
    }
}
