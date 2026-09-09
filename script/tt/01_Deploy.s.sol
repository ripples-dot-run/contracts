// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { TerminalTestHook } from "../../src/tt/TerminalTestHook.sol";
import { TerminalTestSeeder } from "../../src/tt/TerminalTestSeeder.sol";
import { TerminalTestToken } from "../../src/tt/TerminalTestToken.sol";
import { TerminalTestConfig as C } from "./TerminalTestConfig.sol";

/// @notice Stage 1 of the terminal test: hook, token, seeder, and the token side of the seed
///         moved into the seeder. Nothing here touches a pool.
///
///         Simulate first (`forge script` with no `--broadcast`). The run asserts the two mined
///         addresses before it sends anything, so a stale salt fails in simulation.
contract DeployTerminalTest is Script {
    function run() external {
        bytes memory hookInit =
            abi.encodePacked(type(TerminalTestHook).creationCode, abi.encode(C.POOL_MANAGER));
        bytes memory tokenInit = abi.encodePacked(
            type(TerminalTestToken).creationCode, abi.encode(C.TOTAL_SUPPLY, C.DEPLOYER)
        );
        bytes memory seederInit = abi.encodePacked(
            type(TerminalTestSeeder).creationCode,
            abi.encode(IPoolManager(C.POOL_MANAGER), C.DEPLOYER)
        );

        address hook = C.predict(C.HOOK_SALT, keccak256(hookInit));
        address token = C.predict(C.TOKEN_SALT, keccak256(tokenInit));
        address seeder = C.predict(C.SEEDER_SALT, keccak256(seederInit));

        require(hook == C.HOOK, "hook salt no longer produces the mined address");
        require(token == C.TOKEN, "token salt no longer produces the mined address");
        require(uint160(hook) & 0x3FFF == 0x2AC4, "hook address does not carry 0x2AC4");
        require(token < C.WETH, "token must sort below WETH to be currency0");

        console2.log("hook            ", hook);
        console2.log("token           ", token);
        console2.log("seeder          ", seeder);
        console2.log("eth before      ", C.DEPLOYER.balance);

        vm.startBroadcast(C.DEPLOYER);

        if (hook.code.length == 0) _create2(C.HOOK_SALT, hookInit, hook);
        if (token.code.length == 0) _create2(C.TOKEN_SALT, tokenInit, token);
        if (seeder.code.length == 0) _create2(C.SEEDER_SALT, seederInit, seeder);

        if (IERC20(token).balanceOf(seeder) < C.SEED_AMOUNT) {
            IERC20(token).transfer(seeder, C.SEED_AMOUNT);
        }

        vm.stopBroadcast();

        // The PoolManager's own view of the address: the same check `Hooks.validateHookPermissions`
        // makes, run against the deployed bytecode rather than the constructor's copy of it.
        console2.log("hook code size  ", hook.code.length);
        console2.log("bitmap          ", uint160(hook) & 0x3FFF);
        console2.log("seeder TTEST    ", IERC20(token).balanceOf(seeder));
        console2.log("deployer TTEST  ", IERC20(token).balanceOf(C.DEPLOYER));
        console2.log("eth after       ", C.DEPLOYER.balance);
    }

    function _create2(bytes32 salt, bytes memory initCode, address expected) internal {
        (bool ok,) = C.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok, "create2 deploy failed");
        require(expected.code.length > 0, "create2 produced no code at the predicted address");
    }
}
