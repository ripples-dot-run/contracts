// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { TerminalTestRouter } from "../../src/tt/TerminalTestRouter.sol";
import { TerminalTestConfig as C } from "./TerminalTestConfig.sol";

/// @notice Stage 3: one buy of TTEST with WETH, from the deployer's own wallet.
///
///         One wallet is enough for what this test asks. The terminals are being asked whether a
///         pool and a trade are indexed at all, and none of them keys that on the buyer being a
///         different address from the deployer.
///
///         The buy goes through `TerminalTestRouter` rather than Uniswap's Universal Router.
///         That router is deployed on 4663 and does route native-quoted v4 pools, but it reverts
///         with empty return data on every ERC-20/ERC-20 v4 pool tried against it: this pool,
///         a hookless pool opened for the comparison, and two live third-party pools including
///         a Pons one. The finding is written up in `docs/qa/terminal-test-2026-09-06.md`.
contract SwapTerminalTest is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant ROUTER_SALT = keccak256("ripples.terminal-test.router.1");

    function run() external {
        PoolKey memory key = C.poolKey();
        PoolId id = key.toId();
        IPoolManager pm = IPoolManager(C.POOL_MANAGER);

        bytes memory routerInit = abi.encodePacked(
            type(TerminalTestRouter).creationCode, abi.encode(IPoolManager(C.POOL_MANAGER))
        );
        address router = C.predict(ROUTER_SALT, keccak256(routerInit));

        uint256 wethBefore = IERC20(C.WETH).balanceOf(C.DEPLOYER);
        uint256 tokenBefore = IERC20(C.TOKEN).balanceOf(C.DEPLOYER);
        (uint160 sqrtBefore, int24 tickBefore,,) = pm.getSlot0(id);

        console2.log("router          ", router);
        console2.log("weth before     ", wethBefore);
        console2.log("ttest before    ", tokenBefore);
        console2.log("sqrtPrice before", sqrtBefore);
        console2.log("tick before     ", tickBefore);
        console2.log("eth before      ", C.DEPLOYER.balance);

        vm.startBroadcast(C.DEPLOYER);

        if (router.code.length == 0) {
            (bool ok,) = C.CREATE2_DEPLOYER.call(abi.encodePacked(ROUTER_SALT, routerInit));
            require(ok && router.code.length > 0, "router deploy failed");
        }
        if (IERC20(C.WETH).allowance(C.DEPLOYER, router) < C.SWAP_AMOUNT_IN) {
            IERC20(C.WETH).approve(router, C.SWAP_AMOUNT_IN);
        }
        // currency0 is TTEST and currency1 is WETH, so buying TTEST with WETH is one-for-zero.
        TerminalTestRouter(router).swapExactIn(key, false, C.SWAP_AMOUNT_IN, C.SWAP_MIN_OUT);

        vm.stopBroadcast();

        (uint160 sqrtAfter, int24 tickAfter,,) = pm.getSlot0(id);
        console2.log("sqrtPrice after ", sqrtAfter);
        console2.log("tick after      ", tickAfter);
        console2.log("weth spent      ", wethBefore - IERC20(C.WETH).balanceOf(C.DEPLOYER));
        console2.log("ttest received  ", IERC20(C.TOKEN).balanceOf(C.DEPLOYER) - tokenBefore);
        console2.log("pool liquidity  ", pm.getLiquidity(id));
        console2.log("pool WETH       ", IERC20(C.WETH).balanceOf(C.POOL_MANAGER));
        console2.log("eth after       ", C.DEPLOYER.balance);
    }
}
