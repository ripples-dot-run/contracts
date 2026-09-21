// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DualFillAgentFactory } from "../src/DualFillAgentFactory.sol";

/// The reads that identify the token Dual Fill factory an agent factory is bound to.
interface IDualFillAgentFillFactoryReads {
    // solhint-disable-next-line func-name-mixedcase
    function LAUNCH_FACTORY() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function FEE_TOKEN() external view returns (address);
}

/// `PERMIT2` alone is answered by anything with that getter. The hook is what makes the pair
/// unique to `LaunchRouter`, and it pins the generation as well.
interface IDualFillAgentRouterReads {
    // solhint-disable-next-line func-name-mixedcase
    function PERMIT2() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function HOOK() external view returns (address);
}

/// See `Deploy.s.sol`: on an Orbit chain `block.number` is the parent chain's height.
interface IDualFillAgentArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// Deploys `DualFillAgentFactory`, which creates the EVM side of every agent Dual Fill, on
/// Robinhood Chain or on Arc. It has no owner and no wiring: the token Dual Fill factory, the
/// venue and the allowance ledger are fixed at construction.
///
/// Every address comes from the network's own record and is checked read by read before anything
/// is broadcast: the Dual Fill factory is bound to the record's launch factory and names the fee
/// token it bonds in, and the router serves the record's hook, with Permit2 read off the router rather
/// than typed here, because a treasury grants through the ledger the router spends from. A
/// treasury is funded, metered and paid out in its own fill's quote, in that quote's decimals,
/// and bonds in the fee token. A broadcast run writes the factory and this chain's own deploy
/// height back into the record.
///
/// A deploy over a factory the record already names is a new generation: the factory being
/// replaced goes on the end of `legacyDualFillAgentFactories` before the live key moves, so the
/// treasuries it made stay discoverable. Same shape as `legacyDualFillFactories`.
///
///   DUAL_FILL_AGENT_ALLOW_REDEPLOY  must be true to deploy over a factory the record names
///   ALLOW_MAINNET_DEPLOY            must be true to broadcast on chain 4663 or 5042
///   WRITE_DEPLOYMENTS               set false to skip the record write on a broadcast run
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployDualFillAgent is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    string internal constant DEPLOYMENTS = "./deployments.json";
    string internal constant ARC_MAINNET_RECORD = "./deployments/arc-mainnet.json";
    string internal constant ARC_TESTNET_RECORD = "./deployments/arc-testnet.json";
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    uint256 internal constant ARB_SYS_GAS = 100_000;

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error NoCodeAt(address target);
    /// A contract the record names answered a wiring read with something else.
    error WiringMismatch(string field, address recorded, address answered);
    /// The Dual Fill factory names no fee token, so there is nothing for a treasury to bond in.
    error FeeTokenMissing(address dualFillFactory);
    /// The router does not answer `PERMIT2()` with a contract.
    error NotTheLaunchRouter(address target);
    error FactoryAlreadyDeployed(address recorded);
    error RecordCannotHold(string path);

    function run() external returns (DualFillAgentFactory agents) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));
        (string memory file, string memory entry) = recordFor(block.chainid);
        string memory record = vm.readFile(file);
        guardRedeploy(
            recordedAddress(record, entry, "dualFillAgentFactory"),
            vm.envOr("DUAL_FILL_AGENT_ALLOW_REDEPLOY", false)
        );
        bool writesRecord = writesDeployments();
        if (writesRecord) requireRecordable(record, entry);
        (address dualFillFactory, address router, address permit2) = resolveWiring(record, entry);

        vm.startBroadcast();
        agents = new DualFillAgentFactory(dualFillFactory, router, permit2);
        vm.stopBroadcast();
        uint256 deployBlock = deployHeight();

        console2.log("network", network);
        console2.log("deployer", msg.sender);
        console2.log("dualFillAgentFactory", address(agents));
        console2.log("dualFillAgentDeployBlock", deployBlock);
        console2.log("dualFillFactory", agents.DUAL_FILL_FACTORY());
        console2.log("tokenLaunchFactory", agents.LAUNCH_FACTORY());
        console2.log("runwayAsset", agents.RUNWAY_ASSET());
        console2.log("nativeWrap", agents.NATIVE_WRAP());
        console2.log("launchRouter", agents.ROUTER());
        console2.log("permit2", agents.PERMIT2());

        if (writesRecord) {
            recordDeployment(file, entry, address(agents), deployBlock);
            console2.log("written to", string.concat(file, _path(entry, "dualFillAgentFactory")));
            return agents;
        }
        if (_isBroadcast()) console2.log("WRITE_DEPLOYMENTS is false, so nothing was written");
    }

    /// @notice Everything that stands between a typo and an immutable factory wired to the wrong
    ///         contract, read off the record the deploy is about to write into.
    function resolveWiring(string memory record, string memory entry)
        public
        view
        returns (address dualFillFactory, address router, address permit2)
    {
        dualFillFactory = recordedAddress(record, entry, "dualFillFactory");
        if (dualFillFactory.code.length == 0) revert NoCodeAt(dualFillFactory);
        _matches(
            record,
            entry,
            "tokenLaunchFactory",
            dualFillFactory,
            IDualFillAgentFillFactoryReads.LAUNCH_FACTORY.selector
        );
        // A fill may be priced in another asset than the factory bonds in; the treasury is funded
        // and metered in the fill's quote and bonds in the fee token, which only has to exist.
        address feeToken = _read(dualFillFactory, IDualFillAgentFillFactoryReads.FEE_TOKEN.selector);
        if (feeToken == address(0)) revert FeeTokenMissing(dualFillFactory);
        console2.log("feeToken", feeToken);

        router = recordedAddress(record, entry, "launchRouter");
        if (router.code.length == 0) revert NoCodeAt(router);
        permit2 = _read(router, IDualFillAgentRouterReads.PERMIT2.selector);
        if (permit2 == address(0) || permit2.code.length == 0) revert NotTheLaunchRouter(router);
        _matches(record, entry, "launchHook", router, IDualFillAgentRouterReads.HOOK.selector);
    }

    /// @notice Write what this deploy produced into the network's record. Public and given its
    ///         file, so the write can be exercised against a copy of the record. A factory the
    ///         record already names, with code on this chain, is retired onto the legacy list
    ///         before the live key moves.
    function recordDeployment(
        string memory file,
        string memory entry,
        address agents,
        uint256 deployBlock
    ) public {
        string memory record = vm.readFile(file);
        address previous = recordedAddress(record, entry, "dualFillAgentFactory");
        if (previous != address(0) && previous != agents && previous.code.length != 0) {
            vm.writeJson(
                retiredWith(record, entry, previous),
                file,
                _path(entry, "legacyDualFillAgentFactories")
            );
        }
        vm.writeJson(_quoted(vm.toString(agents)), file, _path(entry, "dualFillAgentFactory"));
        vm.writeJson(vm.toString(deployBlock), file, _path(entry, "dualFillAgentDeployBlock"));
    }

    /// @notice The entry's legacy list with `previous` on the end, as a JSON array. Built by hand
    ///         because forge's serializer returns an object around its arrays, and this key
    ///         holds the bare list. A factory already on it stays where it is.
    function retiredWith(string memory record, string memory entry, address previous)
        public
        view
        returns (string memory)
    {
        string memory path = _path(entry, "legacyDualFillAgentFactories");
        string memory out = "[";
        bool listed;
        if (vm.keyExistsJson(record, path)) {
            address[] memory existing = vm.parseJsonAddressArray(record, path);
            for (uint256 i = 0; i < existing.length; i++) {
                listed = listed || existing[i] == previous;
                out = string.concat(out, i == 0 ? "" : ",", _quoted(vm.toString(existing[i])));
            }
        }
        if (listed) return string.concat(out, "]");
        return string.concat(
            out, bytes(out).length == 1 ? "" : ",", _quoted(vm.toString(previous)), "]"
        );
    }

    /// @notice Refuse a record with nowhere to put the result: `vm.writeJson` replaces a value
    ///         and cannot add a key, so the deploy would broadcast and record nothing.
    function requireRecordable(string memory record, string memory entry) public view {
        string[3] memory fields =
            ["dualFillAgentFactory", "dualFillAgentDeployBlock", "legacyDualFillAgentFactories"];
        for (uint256 i = 0; i < fields.length; i++) {
            string memory path = _path(entry, fields[i]);
            if (!vm.keyExistsJson(record, path)) revert RecordCannotHold(path);
        }
    }

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
        if (chainId == ARC_MAINNET) {
            if (!allowMainnet) revert MainnetNotAuthorized();
            return "arcMainnet";
        }
        if (chainId == ARC_TESTNET) return "arcTestnet";
        revert UnsupportedChain(chainId);
    }

    /// @notice Where the network's record lives, and which entry inside it this deploy writes
    ///         into. Robinhood Chain's two networks share deployments.json under an entry each;
    ///         each Arc network has a file of its own whose keys sit at the root, so its entry is
    ///         empty and every path is one segment. This answers where, not whether: `run` has
    ///         already put the chain through `guardNetwork` with the authorisation it was given.
    function recordFor(uint256 chainId)
        public
        pure
        returns (string memory file, string memory entry)
    {
        if (chainId == ARC_MAINNET) return (ARC_MAINNET_RECORD, "");
        if (chainId == ARC_TESTNET) return (ARC_TESTNET_RECORD, "");
        return (DEPLOYMENTS, guardNetwork(chainId, true));
    }

    /// @notice One factory per network unless the deployer says otherwise: every treasury answers
    ///         to the factory that made it, and `treasuryOf` is read from one factory. A recorded
    ///         address with no code is a record pointing at another chain.
    function guardRedeploy(address recorded, bool allowRedeploy) public view {
        if (allowRedeploy) return;
        if (recorded != address(0) && recorded.code.length != 0) {
            revert FactoryAlreadyDeployed(recorded);
        }
    }

    /// @notice This chain's own height. ArbSys answers it on a live Orbit node; a forked EVM runs
    ///         the precompile's placeholder byte as INVALID, so the read is gas-capped and any
    ///         failure falls back to `block.number`, which is what `Deploy.s.sol` records too.
    function deployHeight() public view returns (uint256) {
        if (block.chainid != RH_TESTNET && block.chainid != RH_MAINNET) return block.number;
        (bool ok, bytes memory answer) = ARB_SYS.staticcall{ gas: ARB_SYS_GAS }(
            abi.encodeCall(IDualFillAgentArbSys.arbBlockNumber, ())
        );
        if (!ok || answer.length < 32) return block.number;
        uint256 height = abi.decode(answer, (uint256));
        return height == 0 ? block.number : height;
    }

    /// @notice One address the record carries, or zero when the key is absent or null. Probed
    ///         rather than parsed, because `vm.parseJsonAddress` reverts on `null`.
    function recordedAddress(string memory record, string memory entry, string memory field)
        public
        view
        returns (address)
    {
        string memory path = _path(entry, field);
        if (!vm.keyExistsJson(record, path)) return address(0);
        bytes memory value = vm.parseJson(record, path);
        if (value.length != 32) return address(0);
        uint256 word = abi.decode(value, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    /// @notice True when this run will record itself in deployments.json. A dry run, a fork
    ///         rehearsal and `forge test` print and write nothing.
    function writesDeployments() public view returns (bool) {
        return _isBroadcast() && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    function _matches(
        string memory record,
        string memory entry,
        string memory field,
        address target,
        bytes4 selector
    ) private view {
        address expected = recordedAddress(record, entry, field);
        address answered = _read(target, selector);
        if (expected == address(0) || answered != expected) {
            revert WiringMismatch(field, expected, answered);
        }
    }

    function _read(address target, bytes4 selector) private view returns (address) {
        (bool ok, bytes memory answer) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || answer.length < 32) return address(0);
        uint256 word = abi.decode(answer, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    function _isBroadcast() private view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }

    function _path(string memory entry, string memory field) private pure returns (string memory) {
        if (bytes(entry).length == 0) return string.concat(".", field);
        return string.concat(".", entry, ".", field);
    }

    function _quoted(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }
}
