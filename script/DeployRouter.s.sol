// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { LaunchRouter } from "../src/LaunchRouter.sol";
import { LaunchHook } from "../src/hook/LaunchHook.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { IAllowanceTransfer } from "../src/interfaces/IAllowanceTransfer.sol";

/// Deploys `LaunchRouter`, the contract a Ripples market is traded through so that an oversized
/// buy fills to the end of the curve instead of reverting. `src/interfaces/ILaunchRouter.sol` says
/// why a launch needs that.
///
/// There is nothing to wire afterwards. The router has no owner, no pause, no fee and no
/// allowlist, it holds no balance between calls, and it serves the one hook it is constructed
/// with, so it is finished the moment the transaction lands. The record write below is what
/// points the web at it.
///
/// Its three constructor arguments are the whole configuration, and none of them is typed here as
/// a live address. The manager and the hook are read out of the network's own record, so a
/// generation that mined a new hook cannot leave this script keyed to a retired one, and Permit2
/// is a constant because it holds one address on every chain.
///
///   PoolManager  0x8366a39CC670B4001A1121B8F6A443A643e40951  on 4663 and on 46630
///   LaunchHook   0xaF59944A7d03B914567cb0272b7E588A7aE7AAC4  on 4663 and on 46630
///   Permit2      0x000000000022D473030F116dDEE9F6B43aC78BA3  on both, and everywhere else
///
/// Every override this script reads is prefixed, because `Deploy.s.sol` reads `POOL_MANAGER` and
/// `LAUNCH_HOOK` of its own and forge shares one environment across the tests that drive both.
///
///   ROUTER_POOL_MANAGER   Uniswap V4 PoolManager; defaults to the network's record
///   ROUTER_LAUNCH_HOOK    the hook every launch is keyed to; defaults to the network's record
///   ROUTER_PERMIT2        Permit2's allowance ledger; defaults to the canonical address
///   ALLOW_MAINNET_DEPLOY  must be true to broadcast on chain 4663
///   WRITE_DEPLOYMENTS     set false to skip the deployments.json write on a broadcast run
///
/// The deployer is whichever sender forge is running as. No environment variable overrides it.
contract DeployRouter is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant DEPLOYMENTS = "./deployments.json";
    /// Permit2 is deployed to this address on both Robinhood networks and holds it everywhere
    /// else, so the record carries no entry for it and there is nothing to resolve.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    error HookPoolManagerMismatch(address hook);

    function run() external returns (LaunchRouter router) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));

        address poolManager = _resolve("ROUTER_POOL_MANAGER", network, "poolManager");
        // `launchHook` is the key every pool opened since the 2026-09-06 generation is keyed to.
        // `graduationHook` is the older name for the same address and is not read here.
        address hook = _resolve("ROUTER_LAUNCH_HOOK", network, "launchHook");
        address permit2 = vm.envOr("ROUTER_PERMIT2", address(0));
        if (permit2 == address(0)) permit2 = CANONICAL_PERMIT2;

        // The constructor rejects a zero and nothing else, and it does it once the transaction is
        // in flight. A typo is cheaper to find here.
        if (poolManager.code.length == 0) revert NoCodeAt(poolManager);
        if (hook.code.length == 0) revert NoCodeAt(hook);
        if (permit2.code.length == 0) revert NoCodeAt(permit2);
        // A router keyed to a hook that trades on some other manager would unlock one contract
        // and swap against another, and every order sent to it would revert.
        if (address(LaunchHook(payable(hook)).POOL_MANAGER()) != poolManager) {
            revert HookPoolManagerMismatch(hook);
        }

        vm.startBroadcast();
        router = new LaunchRouter(
            IPoolManager(poolManager), ILaunchHook(hook), IAllowanceTransfer(permit2)
        );
        vm.stopBroadcast();

        console2.log("launchRouter", address(router));
        console2.log("poolManager", address(router.POOL_MANAGER()));
        console2.log("hook", address(router.HOOK()));
        console2.log("permit2", address(router.PERMIT2()));

        if (!_writesDeployments()) return router;
        vm.writeJson(
            _jsonAddress(address(router)), DEPLOYMENTS, string.concat(".", network, ".launchRouter")
        );
    }

    /// The network this chain id deploys into, or a revert. Mainnet needs `ALLOW_MAINNET_DEPLOY`,
    /// which is read by the caller so the rule itself can be checked without an environment.
    function guardNetwork(uint256 chainId, bool allowMainnet)
        public
        pure
        returns (string memory network)
    {
        if (chainId == RH_MAINNET) {
            if (!allowMainnet) revert MainnetNotAuthorized();
            return "robinhoodMainnet";
        }
        if (chainId == RH_TESTNET) return "robinhoodTestnet";
        revert UnsupportedChain(chainId);
    }

    /// True when this run will record itself in deployments.json. A dry run or a test prints the
    /// address and writes nothing, so the committed record only ever names contracts on chain.
    function _writesDeployments() private view returns (bool) {
        return
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    /// An environment override, or the network's own entry in deployments.json. Reading the
    /// record means a factory redeploy cannot leave this script pointing at a retired hook.
    function _resolve(string memory variableName, string memory network, string memory field)
        private
        view
        returns (address value)
    {
        value = vm.envOr(variableName, address(0));
        if (value != address(0)) return value;
        value = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), _path(network, field));
        if (value == address(0)) revert DeploymentAddressRequired(variableName);
    }

    function _path(string memory network, string memory field)
        private
        pure
        returns (string memory)
    {
        return string.concat(".", network, ".", field);
    }

    /// writeJson takes a JSON document, so a bare address has to arrive quoted.
    function _jsonAddress(address value) private pure returns (string memory) {
        return string.concat('"', vm.toString(value), '"');
    }
}
