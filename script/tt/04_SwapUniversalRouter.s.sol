// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { TerminalTestConfig as C } from "./TerminalTestConfig.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Stage 4: the same buy again, this time through Uniswap's own Universal Router on 4663
///         (`0x8876789976dEcBfCbBbe364623C63652db8C0904`), so the pool has one trade whose `Swap`
///         event carries the same `sender` as every other Uniswap trade on this chain. A terminal
///         that filters trades by router sees this one.
///
///         **The encoding, because it cost an afternoon.** The `SWAP_EXACT_IN_SINGLE` parameter
///         struct this deployment expects carries one more head word than the current
///         v4-periphery `ExactInputSingleParams`: an unused word sits between `amountOutMinimum`
///         and the `hookData` offset. Encode the current five-field struct and the router reads
///         the `hookData` offset out of that unused slot instead.
///
///         The failure is silent and asymmetric, which is what makes it worth writing down. When
///         `currency0` is native ETH the misread offset lands on a zero word, the hook data
///         decodes as empty, and the swap goes through, so every native-quoted pool on the chain
///         works with the wrong encoding. When `currency0` is an ERC-20 the same slot holds a
///         token address, that becomes a nonsense `hookData` length, and the calldata bounds
///         check reverts with **no return data at all**, before the router ever calls the
///         PoolManager. Confirmed against this pool, against a hookless pool opened for the
///         comparison, and against two live third-party pools including a Pons one. And a real
///         ERC-20/ERC-20 trade on chain (`0xcc54c1f1…68b3`) does carry the extra word.
///
///         So: nothing about a hook, a zero fee or a tick spacing of 200 stops Uniswap's router
///         trading a Ripples pool. Whatever builds this calldata for the launch has to match this
///         deployment's struct, and a native-quoted pool will not catch the mistake.
contract SwapViaUniversalRouter is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes1 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    uint128 internal constant AMOUNT_IN = 0.001 ether;
    uint128 internal constant MIN_OUT = 900_000e18;

    /// @dev The head word this deployment expects and does not use. The one on-chain trace we
    ///      decoded shows the router choosing the price limit itself
    ///      (`TickMath.MAX_SQRT_PRICE - 1` for a one-for-zero swap) and ignoring this value; the
    ///      live ERC-20/ERC-20 trade passes zero.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 unusedHeadWord;
        bytes hookData;
    }

    function run() external {
        PoolKey memory key = C.poolKey();
        PoolId id = key.toId();
        IPoolManager pm = IPoolManager(C.POOL_MANAGER);

        uint256 wethBefore = IERC20(C.WETH).balanceOf(C.DEPLOYER);
        uint256 tokenBefore = IERC20(C.TOKEN).balanceOf(C.DEPLOYER);
        (uint160 sqrtBefore, int24 tickBefore,,) = pm.getSlot0(id);
        console2.log("weth before     ", wethBefore);
        console2.log("sqrtPrice before", sqrtBefore);
        console2.log("tick before     ", tickBefore);
        console2.log("eth before      ", C.DEPLOYER.balance);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: AMOUNT_IN,
                amountOutMinimum: MIN_OUT,
                unusedHeadWord: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(key.currency1, uint256(AMOUNT_IN));
        params[2] = abi.encode(key.currency0, uint256(MIN_OUT));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);

        vm.startBroadcast(C.DEPLOYER);

        if (IERC20(C.WETH).allowance(C.DEPLOYER, C.PERMIT2) < AMOUNT_IN) {
            IERC20(C.WETH).approve(C.PERMIT2, type(uint256).max);
        }
        (uint160 permitted, uint48 expiry,) =
            IPermit2(C.PERMIT2).allowance(C.DEPLOYER, C.WETH, C.UNIVERSAL_ROUTER);
        if (permitted < AMOUNT_IN || expiry < block.timestamp + 60) {
            IPermit2(C.PERMIT2)
                .approve(C.WETH, C.UNIVERSAL_ROUTER, AMOUNT_IN, uint48(block.timestamp + 3600));
        }
        IUniversalRouter(C.UNIVERSAL_ROUTER)
            .execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 600);

        vm.stopBroadcast();

        (uint160 sqrtAfter, int24 tickAfter,,) = pm.getSlot0(id);
        console2.log("sqrtPrice after ", sqrtAfter);
        console2.log("tick after      ", tickAfter);
        console2.log("weth spent      ", wethBefore - IERC20(C.WETH).balanceOf(C.DEPLOYER));
        console2.log("ttest received  ", IERC20(C.TOKEN).balanceOf(C.DEPLOYER) - tokenBefore);
        console2.log("eth after       ", C.DEPLOYER.balance);
    }
}
