// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { LinkedDualFillFactory } from "../src/LinkedDualFillFactory.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// The reads a combined Dual Fill factory copies off the network's token Dual Fill factory, so
/// both generations answer to the same launch factory, keeper and wrap rule.
interface ILinkedDualFillSource {
    // solhint-disable-next-line func-name-mixedcase
    function LAUNCH_FACTORY() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function KEEPER() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function NATIVE_WRAP() external view returns (bool);
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
}

interface ILinkedDualFillLaunchFactoryReads {
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
    function quoteRegistry() external view returns (address);
}

/// See `Deploy.s.sol`: on an Orbit chain `block.number` is the parent chain's height.
interface ILinkedDualFillArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// Deploys `LinkedDualFillFactory`, the EVM side of every combined Dual Fill, on Robinhood Chain
/// or on Arc. No owner, no setter: the launch factory, the keeper and the native-wrap flag are
/// fixed at construction.
///
/// All three are read off the token Dual Fill factory the record names, so the opener that opens
/// a token Dual Fill opens a combined one with the same key, and the launch factory it reports is
/// checked against the record's. That launch factory's quote has to be the token Dual Fill
/// factory's, and the record's WETH on a rail that wraps. Its registry has to price the quote in
/// the linked shape the combined terms are derived from (`phantomQuote` five quarters of the
/// target) with a mint price floor. Both are ratios of the row, so they hold in the quote's own
/// decimals, six on Arc's USDC and eighteen on Robinhood Chain's WETH. A broadcast run writes the
/// factory and this chain's own deploy height back into the network's record.
///
/// A deploy over a factory the record already names is a new generation: the factory being
/// replaced goes on the end of `legacyLinkedDualFillFactories` before the live key moves, so the
/// fills it made stay discoverable. Same shape as `legacyDualFillFactories`.
///
///   LINKED_DUAL_FILL_ALLOW_REDEPLOY  must be true to deploy over a factory the record names
///   ALLOW_MAINNET_DEPLOY             must be true to broadcast on chain 4663 or 5042
///   WRITE_DEPLOYMENTS                set false to skip the record write on a broadcast run
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployLinkedDualFill is Script {
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
    /// The token Dual Fill factory reports a launch factory other than the record's, the launch
    /// factory's quote is not the one the token Dual Fill factory settles in, or, on a rail that
    /// wraps, that quote is not the record's WETH.
    error WiringMismatch(string field, address recorded, address answered);
    /// The registry's row for the quote is missing, not the linked shape, or has no mint price
    /// floor.
    error RowUnsupported(address quote);
    error FactoryAlreadyDeployed(address recorded);
    error RecordCannotHold(string path);

    function run() external returns (LinkedDualFillFactory factory) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));
        (string memory file, string memory entry) = recordFor(block.chainid);
        string memory record = vm.readFile(file);
        guardRedeploy(
            recordedAddress(record, entry, "linkedDualFillFactory"),
            vm.envOr("LINKED_DUAL_FILL_ALLOW_REDEPLOY", false)
        );
        bool writesRecord = writesDeployments();
        if (writesRecord) requireRecordable(record, entry);
        (address launchFactory, address keeper, bool nativeWrap) = resolveWiring(record, entry);

        vm.startBroadcast();
        factory = new LinkedDualFillFactory(launchFactory, keeper, nativeWrap);
        vm.stopBroadcast();
        uint256 deployBlock = deployHeight();

        console2.log("network", network);
        console2.log("deployer", msg.sender);
        console2.log("linkedDualFillFactory", address(factory));
        console2.log("linkedDualFillDeployBlock", deployBlock);
        console2.log("tokenLaunchFactory", factory.LAUNCH_FACTORY());
        console2.log("keeper", factory.KEEPER());
        console2.log("nativeWrap", factory.NATIVE_WRAP());
        console2.log("quote", factory.QUOTE());
        console2.log("feeToken", factory.FEE_TOKEN());

        if (writesRecord) {
            recordDeployment(file, entry, address(factory), deployBlock);
            console2.log("written to", string.concat(file, _path(entry, "linkedDualFillFactory")));
            return factory;
        }
        if (_isBroadcast()) console2.log("WRITE_DEPLOYMENTS is false, so nothing was written");
    }

    /// @notice Write what this deploy produced into the network's record. Public and given its
    ///         file, so the write can be exercised against a copy of the record. A factory the
    ///         record already names, with code on this chain, is retired onto the legacy list
    ///         before the live key moves.
    function recordDeployment(
        string memory file,
        string memory entry,
        address factory,
        uint256 deployBlock
    ) public {
        string memory record = vm.readFile(file);
        address previous = recordedAddress(record, entry, "linkedDualFillFactory");
        if (previous != address(0) && previous != factory && previous.code.length != 0) {
            vm.writeJson(
                retiredWith(record, entry, previous),
                file,
                _path(entry, "legacyLinkedDualFillFactories")
            );
        }
        vm.writeJson(_quoted(vm.toString(factory)), file, _path(entry, "linkedDualFillFactory"));
        vm.writeJson(vm.toString(deployBlock), file, _path(entry, "linkedDualFillDeployBlock"));
    }

    /// @notice The entry's legacy list with `previous` on the end, as a JSON array. Built by hand
    ///         because forge's serializer returns an object around its arrays, and this key
    ///         holds the bare list. A factory already on it stays where it is.
    function retiredWith(string memory record, string memory entry, address previous)
        public
        view
        returns (string memory)
    {
        string memory path = _path(entry, "legacyLinkedDualFillFactories");
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
        string[3] memory fields = [
            "linkedDualFillFactory", "linkedDualFillDeployBlock", "legacyLinkedDualFillFactories"
        ];
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

    /// @notice One factory per network unless the deployer says otherwise: fills already created
    ///         answer to the factory that made them. A recorded address with no code is a record
    ///         pointing at another chain, which is not a live deployment.
    function guardRedeploy(address recorded, bool allowRedeploy) public view {
        if (allowRedeploy) return;
        if (recorded != address(0) && recorded.code.length != 0) {
            revert FactoryAlreadyDeployed(recorded);
        }
    }

    /// @notice The launch factory, keeper and wrap flag the token Dual Fill factory was deployed
    ///         with, once it is the record's and its launch factory prices a linked launch.
    /// @dev The combined factory takes its quote off the launch factory at construction, and the
    ///      launch factory's default can have moved since the token Dual Fill factory took its
    ///      own. Two quotes would open one Dual Fill key into two assets, and a wrap rail whose
    ///      quote is not WETH takes ETH it cannot wrap.
    function resolveWiring(string memory record, string memory entry)
        public
        view
        returns (address launchFactory, address keeper, bool nativeWrap)
    {
        address dualFillFactory = recordedAddress(record, entry, "dualFillFactory");
        if (dualFillFactory.code.length == 0) revert NoCodeAt(dualFillFactory);
        address recordedLaunchFactory = recordedAddress(record, entry, "tokenLaunchFactory");
        launchFactory = _read(dualFillFactory, ILinkedDualFillSource.LAUNCH_FACTORY.selector);
        if (recordedLaunchFactory == address(0) || launchFactory != recordedLaunchFactory) {
            revert WiringMismatch("tokenLaunchFactory", recordedLaunchFactory, launchFactory);
        }
        keeper = ILinkedDualFillSource(dualFillFactory).KEEPER();
        nativeWrap = ILinkedDualFillSource(dualFillFactory).NATIVE_WRAP();

        address fillQuote = _read(dualFillFactory, ILinkedDualFillSource.QUOTE.selector);
        address quote = _read(launchFactory, ILinkedDualFillLaunchFactoryReads.QUOTE.selector);
        if (fillQuote == address(0) || quote != fillQuote) {
            revert WiringMismatch("quote", fillQuote, quote);
        }
        // Only a rail that wraps can be handed native currency, and only the record's WETH can
        // take it. A rail that does not wrap has no WETH in its record and nothing to compare.
        address weth = recordedAddress(record, entry, "weth");
        if (nativeWrap && (weth == address(0) || quote != weth)) {
            revert WiringMismatch("weth", weth, quote);
        }
        guardRow(launchFactory);
    }

    /// @notice The linked shape the combined terms mirror: `phantomQuote * 4 ==
    ///         graduationThreshold * 5`, with a mint price floor. Both are ratios of the row, so
    ///         they hold in the quote's own decimals.
    function guardRow(address launchFactory) public view {
        address quote = _read(launchFactory, ILinkedDualFillLaunchFactoryReads.QUOTE.selector);
        address registry =
            _read(launchFactory, ILinkedDualFillLaunchFactoryReads.quoteRegistry.selector);
        if (registry.code.length == 0 || !IQuoteRegistry(registry).approvedQuote(quote)) {
            revert RowUnsupported(quote);
        }
        IQuoteRegistry.QuoteEconomics memory e = IQuoteRegistry(registry).quoteEconomics(quote);
        if (e.phantomQuote * 4 != e.graduationThreshold * 5 || e.minPriceQuote == 0) {
            revert RowUnsupported(quote);
        }
    }

    /// @notice This chain's own height. ArbSys answers it on a live Orbit node; a forked EVM runs
    ///         the precompile's placeholder byte as INVALID, so the read is gas-capped and any
    ///         failure falls back to `block.number`, which is what `Deploy.s.sol` records too.
    function deployHeight() public view returns (uint256) {
        if (block.chainid != RH_TESTNET && block.chainid != RH_MAINNET) return block.number;
        (bool ok, bytes memory answer) = ARB_SYS.staticcall{ gas: ARB_SYS_GAS }(
            abi.encodeCall(ILinkedDualFillArbSys.arbBlockNumber, ())
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
