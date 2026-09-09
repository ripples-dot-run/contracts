// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";

/// @notice Holds the terminal test's liquidity position, the way `LPLocker` will hold a launch's.
///
///         The point of not using Uniswap's own PositionManager here is that the launch will not
///         use it either: a Ripples pool's liquidity lives in a contract we deploy, opened
///         through `PoolManager.unlock` and a callback, and held rather than represented by an
///         NFT. If a terminal only sees pools whose liquidity arrived through Uniswap's
///         PositionManager, the launch would be invisible for the same reason this test is, and
///         that is exactly what the test has to be able to find out.
///
///         `seed` adds one position and refuses to pay any `currency1`: the seed is single-sided
///         in the launch token, with the pool initialized at the bottom of the range so the
///         position needs no quote at all.
contract TerminalTestSeeder is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable OWNER;

    error NotOwner();
    error NotPoolManager();
    error InvalidCallback();
    error CallbackNotConsumed();
    error UnexpectedDebt();
    error QuoteRequired(uint256 amount);
    error TransferMismatch();

    struct CallbackData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        uint256 maxAmount0;
    }

    bytes32 private _callbackHash;

    constructor(IPoolManager poolManager_, address owner_) {
        POOL_MANAGER = poolManager_;
        OWNER = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    /// @notice Open the pool. Permissionless on the PoolManager, and this hook's
    ///         `beforeInitialize` admits everyone, so this is only here to keep the whole test
    ///         in one place.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyOwner
        returns (int24 tick)
    {
        return POOL_MANAGER.initialize(key, sqrtPriceX96);
    }

    /// @notice Add one single-sided position in `currency0`. Reverts if the pool asks for any
    ///         `currency1`, which would mean the pool was initialized above the bottom of the
    ///         range and the seed is not single-sided after all.
    function seed(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 maxAmount0
    ) external onlyOwner returns (uint256 amount0) {
        bytes memory raw = abi.encode(
            CallbackData({
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                maxAmount0: maxAmount0
            })
        );
        _callbackHash = keccak256(raw);
        bytes memory result = POOL_MANAGER.unlock(raw);
        if (_callbackHash != bytes32(0)) revert CallbackNotConsumed();
        amount0 = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        bytes32 expected = _callbackHash;
        if (expected == bytes32(0) || keccak256(raw) != expected) revert InvalidCallback();
        delete _callbackHash;

        CallbackData memory data = abi.decode(raw, (CallbackData));

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

        uint256 owed0 = _debt(delta.amount0());
        uint256 owed1 = _debt(delta.amount1());
        if (owed1 != 0) revert QuoteRequired(owed1);
        if (owed0 > data.maxAmount0) revert UnexpectedDebt();
        _settle(data.key.currency0, owed0);
        return abi.encode(owed0);
    }

    /// @notice Send whatever this contract still holds back to the owner. The position itself
    ///         lives in the PoolManager and is not reachable this way.
    function sweep(IERC20 token) external onlyOwner returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount > 0) token.safeTransfer(OWNER, amount);
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
}
