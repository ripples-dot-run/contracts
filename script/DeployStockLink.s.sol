// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { ITokenLaunchRegistry, StockLinkRegistry } from "../src/StockLinkRegistry.sol";

/// The one read `LaunchpadFactory` has and `TokenLaunchFactory` does not, used to tell the two
/// apart. `TokenLaunchFactory`'s own counterpart is `ITokenLaunchRegistry.launchCount`.
interface INftLaunchpad {
    function collectionCount() external view returns (uint256);
}

/// Deploys `StockLinkRegistry`, the association registry the stock-link panel reads on Robinhood
/// Chain. It is a standalone contract with no owner and no wiring: the two factory addresses are
/// fixed at construction and the launchpad itself is untouched, so this script never redeploys or
/// reconfigures anything that is already live.
///
/// Both factory addresses come from the network's own entry in deployments.json rather than from
/// constants typed here, so a factory redeploy cannot leave the registry pointing at retired
/// factories: it points at whatever the record says is live when the registry is deployed, and
/// then it is immutable. Overrides exist for a rehearsal against a fork.
///
/// The address is printed for the deployment record. This script does not write deployments.json:
/// the `stockLinkRegistry` key belongs to the release record `Deploy.s.sol` maintains, and a
/// separate writer here would race it.
///
///   STOCK_LINK_TOKEN_FACTORY  TokenLaunchFactory override; defaults to the network's record
///   STOCK_LINK_NFT_FACTORY    LaunchpadFactory override; defaults to the network's record
///   ALLOW_MAINNET_DEPLOY      must be true to broadcast on chain 4663
///
/// Every override is prefixed, because forge shares one environment across the tests that drive
/// `Deploy.s.sol` and `DeployBurner.s.sol` too.
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployStockLink is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant DEPLOYMENTS = "./deployments.json";

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    /// The address given for a factory does not answer that factory's own read.
    error NotTheTokenFactory(address target);
    error NotTheNftFactory(address target);

    function run() external returns (StockLinkRegistry registry) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));

        address tokenFactory = _resolve("STOCK_LINK_TOKEN_FACTORY", network, "tokenLaunchFactory");
        address nftFactory = _resolve("STOCK_LINK_NFT_FACTORY", network, "launchpadFactory");

        // The constructor rejects both of these, but it does it after the transaction is in
        // flight, and the addresses are immutable once it lands. A typo is cheaper to find here.
        if (tokenFactory.code.length == 0) revert NoCodeAt(tokenFactory);
        if (nftFactory.code.length == 0) revert NoCodeAt(nftFactory);

        // Both factories answer `isFromFactory(address)` with the same selector, so code at the
        // address is not enough: the two overrides swapped would deploy an immutable registry
        // whose every curve link reverts and whose every collection link fails provenance, and
        // the only repair is a redeploy. Ask each address for the read only it has.
        if (!_answers(tokenFactory, ITokenLaunchRegistry.launchCount.selector)) {
            revert NotTheTokenFactory(tokenFactory);
        }
        if (!_answers(nftFactory, INftLaunchpad.collectionCount.selector)) {
            revert NotTheNftFactory(nftFactory);
        }

        vm.startBroadcast();
        registry = new StockLinkRegistry(tokenFactory, nftFactory);
        vm.stopBroadcast();

        console2.log("stockLinkRegistry", address(registry));
        console2.log("tokenLaunchFactory", registry.TOKEN_FACTORY());
        console2.log("launchpadFactory", registry.NFT_FACTORY());
        console2.log("network", network);
        if (_isBroadcast()) {
            console2.log("record stockLinkRegistry under", string.concat(".", network));
        }
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

    /// An environment override, or the network's own entry in deployments.json.
    function _resolve(string memory variableName, string memory network, string memory field)
        internal
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

    /// Whether `target` answers `selector` with at least a word: the identifying read, not a
    /// value we need. A staticcall, so a probe cannot change anything even on a broadcast run.
    function _answers(address target, bytes4 selector) private view returns (bool) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSelector(selector));
        return ok && answer.length >= 32;
    }

    function _isBroadcast() private view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }
}
