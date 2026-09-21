// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { QuoteFeeHook } from "../src/hook/QuoteFeeHook.sol";
import { Create2Deployer, HookMiner } from "./Deploy.s.sol";

/// Mine `QuoteFeeHook`'s address and deploy it. `MineLaunchHook.s.sol` is the same script for
/// `LaunchHook`; this is its sibling for the quote-fee generation, kept separate rather than
/// parameterizing the one script over two hook types because the two mine different creation
/// code against different flags, and a mined salt is a function of both.
///
/// `QuoteFeeHook` needs `0x2ACC`: everything `LaunchHook`'s `0x2AC4` carries plus
/// `beforeSwapReturnDelta`, the bit that lets it take its fee out of the quote on every swap
/// shape instead of whichever side a trade happened to hand it. One salt in 2^14 lands it, so the
/// search is seconds of CPU, same as the first hook's.
///
/// Run it against the same compiler settings the deploy will use. The salt is a function of the
/// creation code, which carries the constructor arguments and the metadata hash, so a salt mined
/// against a different build is a different address. The script prints the triple that pins the
/// result (deployer, salt, creation-code hash), the same shape `MineLaunchHook.s.sol` prints, so a
/// recorded deploy stays checkable without a network.
///
/// The owner is the one thing a mis-set deploy cannot recover from, for the reason
/// `MineLaunchHook.s.sol`'s own doc gives in full: it is baked into the creation code, into the
/// salt and into the address, so a broadcast refuses an owner with no code unless the caller says
/// outright that it is a key they hold.
///
///   POOL_MANAGER   the v4 PoolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951 on 4663
///   HOOK_OWNER     the address allowed to admit launchpads; the factory owner Safe
///   OWNER_IS_EOA   set when HOOK_OWNER is a key rather than a contract
///   BROADCAST      set to deploy; unset only prints
contract MineQuoteFeeHook is Script {
    /// The canonical CREATE2 deployer, present on both Robinhood Chain networks.
    address internal constant CANONICAL_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = 0x2ACC;

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
            type(QuoteFeeHook).creationCode, abi.encode(IPoolManager(poolManager), hookOwner)
        );
        address deployer = CANONICAL_CREATE2.code.length != 0 ? CANONICAL_CREATE2 : address(0);
        if (deployer == address(0)) {
            vm.startBroadcast();
            deployer = address(new Create2Deployer());
            vm.stopBroadcast();
        }

        (hook, salt) = HookMiner.find(deployer, HOOK_FLAGS, initcode);

        console.log("create2Deployer", deployer);
        console.log("quoteFeeHook", hook);
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
