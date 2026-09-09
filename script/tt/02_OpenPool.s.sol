// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { TerminalTestSeeder } from "../../src/tt/TerminalTestSeeder.sol";
import { TerminalTestConfig as C } from "./TerminalTestConfig.sol";

/// @notice Stage 2: open the pool at the bottom of the range and put the whole seed in as one
///         single-sided position. Two transactions, both from the seeder, so the shape matches
///         what a launch will do rather than what Uniswap's PositionManager would do.
contract OpenTerminalTestPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        PoolKey memory key = C.poolKey();
        PoolId id = key.toId();
        TerminalTestSeeder seeder = TerminalTestSeeder(payable(_seeder()));
        IPoolManager pm = IPoolManager(C.POOL_MANAGER);

        console2.log("poolId");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("seeder          ", address(seeder));
        console2.log("seeder TTEST    ", IERC20(C.TOKEN).balanceOf(address(seeder)));
        console2.log("eth before      ", C.DEPLOYER.balance);

        (uint160 sqrtBefore,,,) = pm.getSlot0(id);
        console2.log("sqrtPrice before", sqrtBefore);

        vm.startBroadcast(C.DEPLOYER);

        if (sqrtBefore == 0) seeder.initializePool(key, C.SQRT_PRICE_X96);
        if (pm.getLiquidity(id) == 0) {
            seeder.seed(key, C.TICK_LOWER, C.TICK_UPPER, C.LIQUIDITY, C.SEED_AMOUNT);
        }

        vm.stopBroadcast();

        (uint160 sqrtAfter, int24 tick,,) = pm.getSlot0(id);
        console2.log("sqrtPrice after ", sqrtAfter);
        console2.log("tick after      ", tick);
        console2.log("pool liquidity  ", pm.getLiquidity(id));
        console2.log("pool TTEST      ", IERC20(C.TOKEN).balanceOf(C.POOL_MANAGER));
        console2.log("seeder TTEST end", IERC20(C.TOKEN).balanceOf(address(seeder)));
        console2.log("seeder WETH end ", IERC20(C.WETH).balanceOf(address(seeder)));
        console2.log("eth after       ", C.DEPLOYER.balance);
    }

    function _seeder() internal pure returns (address) {
        bytes memory init = abi.encodePacked(
            type(TerminalTestSeeder).creationCode,
            abi.encode(IPoolManager(C.POOL_MANAGER), C.DEPLOYER)
        );
        return C.predict(C.SEEDER_SALT, keccak256(init));
    }
}
