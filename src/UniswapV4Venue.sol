// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @notice Spends quote on a Uniswap V4 pool and hands the bought token straight back to the
///         caller. `BuybackBurner` speaks one venue interface, `buy(amountIn, minOut)`, and the
///         PoolManager answers nothing of the sort. Every market on this rail is a v4 pool from
///         its first block, $RIPP included, so this adapter is the whole of the burner's venue.
///
///         It holds no funds between calls, has no owner and no privileged caller. Pulling from
///         `msg.sender` means an unrelated caller can only ever spend its own quote, so leaving
///         `buy` open costs nothing and keeps an admin off a contract that does not need one.
///
///         **v1 wires one venue, and it is WETH-quoted** (DQ13). `QUOTE` is immutable and the
///         pool key is fixed at deploy, so a venue is a single market: the $RIPP buyback runs
///         against WETH/$RIPP and stock-denominated fees never reach it. They go to the treasury
///         instead, which is where a fee in an asset the burn venue cannot spend belongs. This
///         contract is quote-agnostic in the same way the graduation hook is (it never reads
///         what its quote *is*), so a stock-quoted venue is a deployment choice, not a change
///         here, and nothing in the buyback path would have to move to make one.
contract UniswapV4Venue is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable QUOTE;
    IERC20 public immutable TOKEN;
    uint24 public immutable FEE;
    int24 public immutable TICK_SPACING;
    IHooks public immutable HOOKS;
    /// V4 sorts a pool's currencies numerically, so which side the quote sits on is fixed at
    /// deploy and decides the swap direction.
    bool public immutable QUOTE_IS_0;

    bytes32 private _callbackHash;

    struct CallbackData {
        uint256 amountIn;
        address recipient;
    }

    event Bought(address indexed recipient, uint256 amountIn, uint256 amountOut);

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error NotAContract();
    error InvalidTokenPair();
    error NotPoolManager();
    error InvalidCallback();
    error CallbackNotConsumed();
    error UnexpectedDebt();
    error PartialFill();
    error SlippageExceeded();
    error TransferMismatch();

    constructor(
        IPoolManager poolManager,
        IERC20 quote,
        IERC20 token,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    ) {
        if (address(poolManager) == address(0) || address(quote) == address(0)) {
            revert ZeroAddress();
        }
        if (address(token) == address(0)) revert ZeroAddress();
        if (address(quote) == address(token)) revert InvalidTokenPair();
        if (address(poolManager).code.length == 0) revert NotAContract();
        if (address(quote).code.length == 0 || address(token).code.length == 0) {
            revert NotAContract();
        }

        POOL_MANAGER = poolManager;
        QUOTE = quote;
        TOKEN = token;
        FEE = fee;
        TICK_SPACING = tickSpacing;
        HOOKS = hooks;
        QUOTE_IS_0 = address(quote) < address(token);
    }

    function poolKey() public view returns (PoolKey memory) {
        (address c0, address c1) =
            QUOTE_IS_0 ? (address(QUOTE), address(TOKEN)) : (address(TOKEN), address(QUOTE));
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOKS
        });
    }

    /// @notice Spend `amountIn` of quote and send at least `minOut` of the token to the caller.
    function buy(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        // Pool deltas are int128 and the swap is specified as a negative int256, so the input has
        // to fit both before anything is pulled.
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge();

        uint256 before = QUOTE.balanceOf(address(this));
        QUOTE.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 afterBalance = QUOTE.balanceOf(address(this));
        if (afterBalance < before || afterBalance - before != amountIn) revert TransferMismatch();

        out = abi.decode(
            _execute(CallbackData({ amountIn: amountIn, recipient: msg.sender })), (uint256)
        );
        if (out < minOut) revert SlippageExceeded();
        emit Bought(msg.sender, amountIn, out);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        bytes32 expected = _callbackHash;
        if (expected == bytes32(0) || keccak256(raw) != expected) revert InvalidCallback();
        delete _callbackHash;

        CallbackData memory data = abi.decode(raw, (CallbackData));
        PoolKey memory key = poolKey();
        bool zeroForOne = QUOTE_IS_0;

        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // Negative specifies an exact input in V4.
                amountSpecified: -int256(data.amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (int128 quoteDelta, int128 tokenDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        // The burner checks that its own balance fell by exactly `amountIn`, which stays true even
        // if the pool absorbed less than that. The unspent remainder would then sit here with its
        // accounting still balanced, so a short fill has to fail rather than settle.
        uint256 spent = _debt(quoteDelta);
        if (spent != data.amountIn) revert PartialFill();

        uint256 received = _credit(tokenDelta);
        if (received == 0) revert ZeroAmount();

        _settle(zeroForOne ? key.currency0 : key.currency1, spent);
        POOL_MANAGER.take(zeroForOne ? key.currency1 : key.currency0, data.recipient, received);
        return abi.encode(received);
    }

    function _execute(CallbackData memory data) private returns (bytes memory result) {
        bytes memory raw = abi.encode(data);
        _callbackHash = keccak256(raw);
        result = POOL_MANAGER.unlock(raw);
        if (_callbackHash != bytes32(0)) revert CallbackNotConsumed();
    }

    function _settle(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        POOL_MANAGER.sync(currency);
        uint256 before = token.balanceOf(address(this));
        token.safeTransfer(address(POOL_MANAGER), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance > before || before - afterBalance != amount) revert TransferMismatch();
        if (POOL_MANAGER.settle() != amount) revert TransferMismatch();
    }

    function _debt(int128 amount) private pure returns (uint256) {
        if (amount > 0) revert UnexpectedDebt();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(-amount));
    }

    function _credit(int128 amount) private pure returns (uint256) {
        if (amount < 0) revert UnexpectedDebt();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(amount));
    }
}
