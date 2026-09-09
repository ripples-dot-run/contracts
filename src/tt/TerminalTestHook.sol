// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Throwaway hook for the terminal test described in
///         `docs/plans/2026-09-06-pool-from-block-one.md`. It exists to answer one question and
///         nothing else: do GMGN, Axiom and Axiom Pulse index a Uniswap v4 pool whose hook
///         address carries the permission bitmap the launch hook will be mined to.
///
///         It therefore declares exactly that bitmap (`0x2AC4`) and implements every enabled
///         callback as a no-op that returns its own selector. No gate, no fee, no state, no
///         owner, nothing that can move a balance. A pool keyed to this hook behaves like a
///         plain Uniswap v4 pool, so anything an indexer refuses is the bitmap, not behaviour.
///
///         Bit layout, low 14 bits of the address (`Hooks.ALL_HOOK_MASK`):
///
///         | bit | flag                    | value  | set |
///         |-----|-------------------------|--------|-----|
///         | 13  | beforeInitialize        | 0x2000 | yes |
///         | 12  | afterInitialize         | 0x1000 | no  |
///         | 11  | beforeAddLiquidity      | 0x0800 | yes |
///         | 10  | afterAddLiquidity       | 0x0400 | no  |
///         |  9  | beforeRemoveLiquidity   | 0x0200 | yes |
///         |  8  | afterRemoveLiquidity    | 0x0100 | no  |
///         |  7  | beforeSwap              | 0x0080 | yes |
///         |  6  | afterSwap               | 0x0040 | yes |
///         |  5  | beforeDonate            | 0x0020 | no  |
///         |  4  | afterDonate             | 0x0010 | no  |
///         |  3  | beforeSwapReturnsDelta  | 0x0008 | no  |
///         |  2  | afterSwapReturnsDelta   | 0x0004 | yes |
///         |  1  | afterAddLiqReturnsDelta | 0x0002 | no  |
///         |  0  | afterRemoveLiqReturnsD. | 0x0001 | no  |
///
///         0x2000 | 0x0800 | 0x0200 | 0x0080 | 0x0040 | 0x0004 = 0x2AC4.
///
///         `0x2AC4` is the superset the plan names: `p1-pool-curve-hook` will mine either
///         `0x2AC4` or `0x2A44`, the difference being `beforeSwap`. Testing the superset means a
///         pass covers whichever `p1` settles on. For reference, Pons' hook
///         `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` decodes to `0x2044` and the current
///         Ripples `GraduationHook` to `0x2000`.
///
///         `afterSwapReturnsDelta` is set but the returned delta is always zero, which is the
///         point: the launch hook will take its fee there, and an indexer that cannot read a
///         pool whose hook is allowed to alter the swap delta would fail on the flag alone,
///         before any fee is ever charged.
contract TerminalTestHook {
    /// @dev The low 14 bits this contract's address must carry.
    uint160 public constant PERMISSION_BITMAP = 0x2AC4;

    address public immutable POOL_MANAGER;

    error NotPoolManager();

    constructor(address poolManager_) {
        POOL_MANAGER = poolManager_;
        // Reverts unless the mined address carries exactly the bitmap declared below, so a
        // wrong salt fails at deploy rather than at the pool's first swap.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager();
        _;
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev `beforeSwapReturnsDelta` is off, so the delta is ignored; it is returned as zero
    ///      anyway. The fee override is ignored too, because `key.fee` is static (0) rather than
    ///      carrying `LPFeeLibrary.DYNAMIC_FEE_FLAG`.
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev `afterSwapReturnsDelta` is on, so the PoolManager settles this number against the
    ///      hook. Zero means the hook takes nothing and the swapper's delta is untouched.
    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, int128(0));
    }
}
