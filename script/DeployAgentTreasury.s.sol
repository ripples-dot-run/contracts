// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { AgentTreasuryFactory } from "../src/AgentTreasuryFactory.sol";

/// The reads that identify the contracts this factory is wired to, so an address that is merely
/// code at the right place cannot be mistaken for the right contract. `FEE_TOKEN` rather than
/// `launchCount`, because the fee token is what the deployment actually depends on: every
/// treasury denominates its whole charter in it.
interface ITokenLaunchRegistry {
    // solhint-disable-next-line func-name-mixedcase
    function FEE_TOKEN() external view returns (address);
    /// The factory's resolved default quote, which is the asset a launch naming none settles in.
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
}

/// `PERMIT2` alone is answered by anything with that getter, including a treasury factory. The
/// hook is what makes the pair unique to `LaunchRouter`, and it pins the generation as well.
interface IRouterReads {
    // solhint-disable-next-line func-name-mixedcase
    function PERMIT2() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function HOOK() external view returns (address);
}

/// Deploys `AgentTreasuryFactory`, the contract agent launches are created through. It has no
/// owner and no wiring: the launch factory, the venue and the allowance ledger are fixed at
/// construction, and nothing already deployed is touched or reconfigured.
///
/// The three addresses come from the network's own entry in deployments.json, so a factory or
/// router redeploy cannot leave this one pointing at something retired: it points at whatever the
/// record says is live on the day it is deployed, and after that it is immutable. Permit2 is read
/// off the router rather than typed here, because a treasury grants its allowance through the
/// same ledger the router spends from and the two disagreeing would mean every trade reverts.
///
/// The address is printed for the deployment record. This script does not write deployments.json;
/// `Deploy.s.sol` owns that file and carries `agentTreasuryFactory` forward the way it carries
/// `stockLinkRegistry`, so the key survives the next factory redeploy.
///
///   AGENT_TOKEN_FACTORY   TokenLaunchFactory override; defaults to the network's record
///   AGENT_LAUNCH_ROUTER   LaunchRouter override; defaults to the network's record
///   AGENT_LAUNCH_HOOK     LaunchHook override, which the router is checked against
///   ALLOW_MAINNET_DEPLOY  must be true to broadcast on chain 4663
///
/// Every override is prefixed, because forge shares one environment across the tests that drive
/// the other deploy scripts too.
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployAgentTreasury is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant DEPLOYMENTS = "./deployments.json";

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    error NotTheTokenFactory(address target);
    /// The address given for the launch factory is one this network has retired. It still works
    /// and still creates launches, and every launch made on it is invisible to the site, so an
    /// immutable factory wired to it would produce agent launches nobody can find.
    error RetiredTokenFactory(address target);
    /// The launch factory's default quote is not the asset it charges its fee in, so a treasury
    /// would be funded and metered in one token and open a market in another.
    error QuoteIsNotTheFeeToken(address factory);
    /// The address given for the venue is not our router: it does not answer both `PERMIT2()`
    /// and `HOOK()`, or the hook it serves is not this network's.
    error NotTheLaunchRouter(address target);

    function run() external returns (AgentTreasuryFactory agents) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));
        (address tokenFactory, address router, address permit2) = resolveWiring(
            network,
            _resolve("AGENT_TOKEN_FACTORY", network, "tokenLaunchFactory"),
            _resolve("AGENT_LAUNCH_ROUTER", network, "launchRouter"),
            _resolve("AGENT_LAUNCH_HOOK", network, "launchHook")
        );

        vm.startBroadcast();
        agents = new AgentTreasuryFactory(tokenFactory, router, permit2);
        vm.stopBroadcast();

        console2.log("agentTreasuryFactory", address(agents));
        console2.log("tokenLaunchFactory", agents.TOKEN_FACTORY());
        console2.log("launchRouter", agents.ROUTER());
        console2.log("permit2", agents.PERMIT2());
        console2.log("network", network);
        if (_isBroadcast()) {
            console2.log("record agentTreasuryFactory under", string.concat(".", network));
        }
    }

    /// @notice Everything that stands between a typo and an immutable factory wired to the wrong
    ///         contract, with the addresses passed in rather than read, so the rules can be
    ///         checked without an environment.
    /// @param network The record's key for this chain, which is where the retired list comes from.
    function resolveWiring(
        string memory network,
        address tokenFactory,
        address router,
        address hook
    ) public view returns (address, address, address) {
        if (tokenFactory.code.length == 0) revert NoCodeAt(tokenFactory);
        if (router.code.length == 0) revert NoCodeAt(router);

        address feeToken = _read(tokenFactory, ITokenLaunchRegistry.FEE_TOKEN.selector);
        if (feeToken == address(0)) revert NotTheTokenFactory(tokenFactory);
        // Every charter is denominated in the fee token and every launch a treasury opens has to
        // settle in it, so a factory whose default quote is something else would deploy agents
        // funded in one asset and trading in another.
        if (_read(tokenFactory, ITokenLaunchRegistry.QUOTE.selector) != feeToken) {
            revert QuoteIsNotTheFeeToken(tokenFactory);
        }
        // A retired factory answers every read the live one does. Only the record tells them
        // apart, and the two addresses sit one line from each other in it.
        _refuseRetired(tokenFactory, network);

        address permit2 = _read(router, IRouterReads.PERMIT2.selector);
        if (permit2 == address(0) || permit2.code.length == 0) revert NotTheLaunchRouter(router);
        if (_read(router, IRouterReads.HOOK.selector) != hook) revert NotTheLaunchRouter(router);
        return (tokenFactory, router, permit2);
    }

    /// The network this chain id deploys into, or a revert. Mainnet needs `ALLOW_MAINNET_DEPLOY`.
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

    /// One address-returning read, or zero for anything a contract of the right shape would
    /// never answer with: a revert, a short answer, or a word with bits above the low 160.
    function _read(address target, bytes4 selector) private view returns (address) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || answer.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(answer, 0x20))
        }
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    function _refuseRetired(address tokenFactory, string memory network) private view {
        string memory record = vm.readFile(DEPLOYMENTS);
        string memory path = _path(network, "legacyTokenLaunchFactories");
        if (!vm.keyExistsJson(record, path)) return;
        address[] memory retired = vm.parseJsonAddressArray(record, path);
        for (uint256 i = 0; i < retired.length; i++) {
            if (retired[i] == tokenFactory) revert RetiredTokenFactory(tokenFactory);
        }
    }

    function _isBroadcast() private view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }
}
