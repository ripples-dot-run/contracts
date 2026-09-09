// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { ILaunchHook, LaunchView, Phase } from "./hook/interfaces/ILaunchHook.sol";

/// @notice A page of Ripples launches in one call, so a board of two hundred markets is one read
///         rather than four hundred.
///
/// It holds no state, no money and no permission. Everything it returns it reads back out of the
/// hook's own public views and the PoolManager, so a caller who does not trust this contract can
/// reproduce every field from those two addresses directly.
///
/// It is a separate contract because a v4 hook's permissions are the low bits of its own address:
/// the hook has to be mined, it cannot sit behind a proxy, and it is the one contract in this
/// system against the 24,576-byte limit. `launchesOf` returns an array of nested structs, so the
/// ABI encoder it generates grows every time `LaunchConfig` gains a field, and by the parity
/// changes of 2026-09-07 that one convenience read was 1,797 bytes of the hook. Moving it here
/// costs one more deployed address and buys the hook room for what an audit finds next. Nothing
/// was added to the hook to make it possible; `configOf`, `planOf`, `stateOf`, `realQuote` and
/// `snipeTaxBps` were already public.
///
/// A lens is replaceable in a way a hook is not. If a later generation wants more fields in the
/// view, deploy another one; every launch keeps trading on the hook it was mined against.
/// The one hook getter this contract needs. Not on `ILaunchHook`, which is the frozen wire
/// interface readers hold, so it is declared here the way `PoolDeployer` declares it.
interface IHookPoolManager {
    function POOL_MANAGER() external view returns (IPoolManager);
}

contract LaunchLens {
    using StateLibrary for IPoolManager;

    ILaunchHook public immutable HOOK;
    IPoolManager public immutable POOL_MANAGER;

    error ZeroAddress();
    error NotAContract();

    /// The PoolManager is read off the hook rather than passed in. A lens exists to read one
    /// hook's markets, and those markets live on the PoolManager that hook was mined against;
    /// taking the address as a second argument let a run reusing an existing hook ship a lens
    /// that reads every market's price from a different manager, silently. `PoolDeployer` reads
    /// it off the hook for the same reason.
    constructor(ILaunchHook hook) {
        if (address(hook) == address(0)) revert ZeroAddress();
        if (address(hook).code.length == 0) revert NotAContract();
        HOOK = hook;
        POOL_MANAGER = IHookPoolManager(address(hook)).POOL_MANAGER();
    }

    /// @notice Every launch named, in one call. An id that is not a launch answers with
    ///         `Phase.None` and zeroes rather than reverting, so one bad id in a batch does not
    ///         lose the other answers.
    function launchesOf(PoolId[] calldata poolIds) external view returns (LaunchView[] memory) {
        LaunchView[] memory out = new LaunchView[](poolIds.length);
        for (uint256 i = 0; i < poolIds.length; i++) {
            PoolId poolId = poolIds[i];
            out[i].poolId = poolId;
            out[i].state = HOOK.stateOf(poolId);
            if (out[i].state.phase == Phase.None) continue;
            out[i].config = HOOK.configOf(poolId);
            out[i].plan = HOOK.planOf(poolId);
            out[i].realQuote = HOOK.realQuote(poolId);
            // The pool does not exist until the launch is seeded, and `getSlot0` on an
            // uninitialized id answers zero rather than reverting, so this is a read the caller
            // can tell apart from a live price.
            if (out[i].state.phase != Phase.Registered) {
                (out[i].sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
            }
            out[i].snipeTaxBps = HOOK.snipeTaxBps(poolId);
        }
        return out;
    }
}
