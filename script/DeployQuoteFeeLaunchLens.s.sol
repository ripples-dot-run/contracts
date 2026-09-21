// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console } from "forge-std/Script.sol";
import { LaunchLens } from "../src/LaunchLens.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";

/// `LaunchLens` for `quoteFeeHook`. `Deploy.s.sol` deploys one lens per `launchHook` generation
/// at the same time it deploys the hook; `quoteFeeHook` predates this script, so its lens is
/// caught up here instead. The contract is unmodified and hook-agnostic (it reads back whatever
/// `ILaunchHook` it is constructed with), so this is the same `new LaunchLens(hook)` `Deploy.s.sol`
/// runs, aimed at the hook that never got one.
///
/// Without this, `readPoolMarket` (`apps/web/lib/evm/pool-trade.ts`) cannot price a single launch
/// on `quoteFeeHook`: `launchesReaderFor` only redirects reads to a lens for `launchHook`, so a
/// `quoteFeeHook` market falls through to calling `launchesOf` on the hook directly, and no hook
/// in this codebase has ever carried that function itself; it has lived on a lens since before
/// this generation existed. `launchesReaderFor` needs a matching case for `quoteFeeHook` once this
/// address is recorded, which is `apps/web/lib/evm/deployments.ts`'s to make, not this script's.
///
///   QUOTE_FEE_HOOK   the deployed hook this lens reads. Defaults to the network record's own.
///   BROADCAST        set to deploy; unset only prints what would deploy
contract DeployQuoteFeeLaunchLens is Script {
    string internal constant DEPLOYMENTS = "./deployments.json";

    error HookUnset();
    error HookHasNoCode();

    function run() external returns (address lens) {
        address hook = vm.envOr("QUOTE_FEE_HOOK", _recordedHook());
        if (hook == address(0)) revert HookUnset();
        if (hook.code.length == 0) revert HookHasNoCode();

        console.log("quoteFeeHook", hook);

        if (!vm.envOr("BROADCAST", false)) {
            console.log("dry run: would deploy a LaunchLens against the hook above");
            return address(0);
        }

        vm.startBroadcast();
        lens = address(new LaunchLens(ILaunchHook(hook)));
        vm.stopBroadcast();

        console.log("quoteFeeLaunchLens", lens);
        _record(lens);
    }

    function _recordedHook() private view returns (address) {
        string memory network = _networkKey();
        if (bytes(network).length == 0) return address(0);
        string memory record = vm.readFile(DEPLOYMENTS);
        string memory path = string.concat(".", network, ".quoteFeeHook");
        if (!vm.keyExistsJson(record, path)) return address(0);
        return vm.parseJsonAddress(record, path);
    }

    function _networkKey() private view returns (string memory) {
        if (block.chainid == 46630) return "robinhoodTestnet";
        if (block.chainid == 4663) return "robinhoodMainnet";
        return "";
    }

    function _record(address lens) private {
        string memory network = _networkKey();
        if (bytes(network).length == 0 || !vm.envOr("WRITE_DEPLOYMENTS", true)) return;
        vm.writeJson(
            vm.toString(lens), DEPLOYMENTS, string.concat(".", network, ".quoteFeeLaunchLens")
        );
    }
}
