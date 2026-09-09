// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { LaunchHook } from "../src/hook/LaunchHook.sol";
import { Create2Deployer, HookMiner } from "./Deploy.s.sol";

/// Mine the singleton launch hook's address and deploy it.
///
/// A Uniswap v4 hook's permissions are the low 14 bits of its own address, so the address has to
/// be searched for rather than chosen. `LaunchHook` needs `0x2AC4`: `beforeInitialize`,
/// `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap` and
/// `afterSwapReturnsDelta`. One salt in 2^14 lands it, so the search is seconds of CPU.
///
/// Run it against the same compiler settings the deploy will use. The salt is a function of the
/// creation code, which carries the constructor arguments and the metadata hash, so a salt mined
/// against a different build is a different address. The script prints the triple that pins the
/// result (deployer, salt, creation-code hash) and `contracts/test/hook/LaunchHookPermissions
/// .t.sol` holds the one from `docs/plans/2026-09-05-pool-curve-design.md` and re-derives the
/// address from it, so a recorded deploy stays checkable without a network.
///
/// The owner is the one thing a mis-set deploy cannot recover from. It is a constructor argument,
/// so it is baked into the creation code, into the salt and into the address: the hook can only
/// exist at that address with that owner. An owner nobody controls is a singleton that can never
/// admit a launchpad and can never be replaced without re-mining and re-announcing the address, so
/// a broadcast refuses an owner with no code unless the caller says outright that it is a key they
/// hold. Confirm before you set it that the address is either an EOA whose key is in hand or a
/// Safe already deployed at exactly that address on the target chain.
///
///   POOL_MANAGER   the v4 PoolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951 on 4663
///   HOOK_OWNER     the address allowed to admit launchpads; the factory owner Safe
///   OWNER_IS_EOA   set when HOOK_OWNER is a key rather than a contract
///   BROADCAST      set to deploy; unset only prints
contract MineLaunchHook is Script {
    /// The canonical CREATE2 deployer, present on both Robinhood Chain networks.
    address internal constant CANONICAL_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = 0x2AC4;

    error PoolManagerUnset();
    error HookOwnerUnset();
    error HookOwnerHasNoCode();
    error HookDeployFailed();

    function run() external returns (address hook, bytes32 salt) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hookOwner = vm.envAddress("HOOK_OWNER");
        if (poolManager == address(0)) revert PoolManagerUnset();
        if (hookOwner == address(0)) revert HookOwnerUnset();

        bytes memory initcode = abi.encodePacked(
            type(LaunchHook).creationCode, abi.encode(IPoolManager(poolManager), hookOwner)
        );
        address deployer = CANONICAL_CREATE2.code.length != 0 ? CANONICAL_CREATE2 : address(0);
        if (deployer == address(0)) {
            vm.startBroadcast();
            deployer = address(new Create2Deployer());
            vm.stopBroadcast();
        }

        (hook, salt) = HookMiner.find(deployer, HOOK_FLAGS, initcode);

        console.log("create2Deployer", deployer);
        console.log("launchHook", hook);
        console.logBytes32(salt);
        console.logBytes32(keccak256(initcode));
        console.log("flags", uint256(uint160(hook) & 0x3FFF));

        if (vm.envOr("BROADCAST", false)) {
            // A dry run prints against whatever chain state it has, which off a fork is none. A
            // broadcast is the moment the owner becomes permanent, so it is where this bites.
            if (hookOwner.code.length == 0 && !vm.envOr("OWNER_IS_EOA", false)) {
                revert HookOwnerHasNoCode();
            }
            vm.startBroadcast();
            if (deployer == CANONICAL_CREATE2) {
                (bool ok,) = deployer.call(abi.encodePacked(salt, initcode));
                if (!ok && hook.code.length == 0) revert HookDeployFailed();
            } else {
                Create2Deployer(deployer).deploy(salt, initcode);
            }
            vm.stopBroadcast();
            if (hook.code.length == 0) revert HookDeployFailed();
        }
    }
}
