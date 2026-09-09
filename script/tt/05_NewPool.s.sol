// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { TerminalTestRouter } from "../../src/tt/TerminalTestRouter.sol";
import { TerminalTestSeeder } from "../../src/tt/TerminalTestSeeder.sol";
import { TerminalTestToken } from "../../src/tt/TerminalTestToken.sol";
import { TerminalTestConfig as C } from "./TerminalTestConfig.sol";

/// @notice Opens a **fresh** pool (new token, new seeder, same hook and same swap router) and
///         buys from it, in one run.
///
///         This exists because of the one question the first run could not answer. A New Pairs
///         column is a clock, not a filter: GeckoTerminal's `new_pools` feed for this chain covers
///         under three minutes, because Pons opens about thirty pools a minute. By the time anyone
///         reads the record of the first pool, that pool is hundreds of launches down the list, and
///         no amount of looking will tell you whether it was ever in the feed.
///
///         So the Pulse check has to be run live. Open Axiom Pulse and GMGN first, watch the New
///         Pairs column, then run this and keep watching. The run prints the token, the pool id and
///         the swap time; note how many seconds pass before the pair appears, or that it never does.
///
///             . ops/env/keys.sh
///             cd contracts
///             SPARE_SALT_INDEX=0 forge script script/tt/05_NewPool.s.sol:NewTerminalTestPool \
///               --rpc-url https://rpc.mainnet.chain.robinhood.com \
///               --private-key "$RIPPLES_EVM_DEPLOYER_KEY" --broadcast --slow
///
///         Five token salts are pre-mined below, so five runs are available. Each produces an
///         address that sorts under WETH, which keeps the launch token as currency0 and the seed
///         single-sided the way the plan wants it. Costs about 0.0011 ETH of gas and whatever
///         `BUY_AMOUNT` is set to in WETH; the seed itself costs no quote.
contract NewTerminalTestPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 internal constant BUY_AMOUNT = 0.0005 ether;

    function run() external {
        uint256 index = vm.envOr("SPARE_SALT_INDEX", uint256(0));
        bytes32 tokenSalt = _spareSalt(index);

        bytes memory tokenInit = abi.encodePacked(
            type(TerminalTestToken).creationCode, abi.encode(C.TOTAL_SUPPLY, C.DEPLOYER)
        );
        bytes32 seederSalt = keccak256(abi.encodePacked("ripples.terminal-test.seeder.", index + 2));
        bytes memory seederInit = abi.encodePacked(
            type(TerminalTestSeeder).creationCode,
            abi.encode(IPoolManager(C.POOL_MANAGER), C.DEPLOYER)
        );
        bytes memory routerInit = abi.encodePacked(
            type(TerminalTestRouter).creationCode, abi.encode(IPoolManager(C.POOL_MANAGER))
        );

        address token = C.predict(tokenSalt, keccak256(tokenInit));
        address seeder = C.predict(seederSalt, keccak256(seederInit));
        address router =
            C.predict(keccak256("ripples.terminal-test.router.1"), keccak256(routerInit));

        require(token < C.WETH, "token must sort below WETH to be currency0");
        require(token.code.length == 0, "that salt is already used, raise SPARE_SALT_INDEX");
        require(C.HOOK.code.length > 0, "run 01_Deploy first, the hook is shared");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(C.WETH),
            fee: C.FEE,
            tickSpacing: C.TICK_SPACING,
            hooks: IHooks(C.HOOK)
        });

        console2.log("token           ", token);
        console2.log("poolId");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("watch New Pairs from now; timestamp", block.timestamp);

        vm.startBroadcast(C.DEPLOYER);

        (bool ok,) = C.CREATE2_DEPLOYER.call(abi.encodePacked(tokenSalt, tokenInit));
        require(ok && token.code.length > 0, "token deploy failed");
        if (seeder.code.length == 0) {
            (ok,) = C.CREATE2_DEPLOYER.call(abi.encodePacked(seederSalt, seederInit));
            require(ok && seeder.code.length > 0, "seeder deploy failed");
        }
        if (router.code.length == 0) {
            (ok,) = C.CREATE2_DEPLOYER
                .call(abi.encodePacked(keccak256("ripples.terminal-test.router.1"), routerInit));
            require(ok && router.code.length > 0, "router deploy failed");
        }

        IERC20(token).transfer(seeder, C.SEED_AMOUNT);
        TerminalTestSeeder(seeder).initializePool(key, C.SQRT_PRICE_X96);
        TerminalTestSeeder(seeder).seed(key, C.TICK_LOWER, C.TICK_UPPER, C.LIQUIDITY, C.SEED_AMOUNT);

        if (IERC20(C.WETH).allowance(C.DEPLOYER, router) < BUY_AMOUNT) {
            IERC20(C.WETH).approve(router, BUY_AMOUNT);
        }
        TerminalTestRouter(router).swapExactIn(key, false, BUY_AMOUNT, 0);

        vm.stopBroadcast();

        IPoolManager pm = IPoolManager(C.POOL_MANAGER);
        (uint160 sqrtAfter, int24 tickAfter,,) = pm.getSlot0(key.toId());
        console2.log("sqrtPrice after ", sqrtAfter);
        console2.log("tick after      ", tickAfter);
        console2.log("pool liquidity  ", pm.getLiquidity(key.toId()));
        console2.log("eth after       ", C.DEPLOYER.balance);
        console2.log("weth after      ", IERC20(C.WETH).balanceOf(C.DEPLOYER));
    }

    /// Pre-mined against `TerminalTestToken`'s init code with the supply and recipient in
    /// `TerminalTestConfig`. Each sorts below WETH. Change the token's source and these stop
    /// working, which the `token < C.WETH` assertion above will catch.
    function _spareSalt(uint256 index) internal pure returns (bytes32) {
        if (index == 0) return 0xbc83c565cf95b55028f1e401cd4c59971ebb07787ebaf4d601c7065ec023d2ba;
        if (index == 1) return 0xb97fd3a4b108a8f4cdce570da22491d254172f9893167cfe17ee9bb2af87a4ec;
        if (index == 2) return 0xf69af6debd60ba7bbbe5656956c9720cb422276ad19c0245c2c6bc6fa080de27;
        if (index == 3) return 0x8c93236ecdb9f771cb7d7cd69c618ccbd2b5cbfaff5d4b1e10fb15f3e111a7e6;
        if (index == 4) return 0xd6b103b2f5d5e8620a8d82e9f902f2702c330634ba727cc1b178e2e1332dd7a9;
        revert("SPARE_SALT_INDEX out of range, mine another with cast create2");
    }
}
