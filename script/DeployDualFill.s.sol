// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DualFillFactory } from "../src/DualFillFactory.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// The reads that identify the launch factory a Dual Fill factory is bound to. Each is compared
/// with the network's record, so an address that answers them with anything else is refused.
interface IDualFillLaunchFactoryReads {
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function FEE_TOKEN() external view returns (address);
    function launchHook() external view returns (address);
    function quoteRegistry() external view returns (address);
}

/// See `Deploy.s.sol`: on an Orbit chain `block.number` is the parent chain's height.
interface IDualFillArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// Deploys `DualFillFactory`, the EVM side of every fill-first Dual Fill, on Robinhood Chain or
/// on Arc. No owner, no setter: the launch factory, the keeper and the native-wrap flag are fixed
/// at construction, and the quote and fee token are read off the launch factory in the same
/// transaction.
///
/// The launch factory comes from the network's record and is checked against it read by read
/// before anything is broadcast: its default quote, fee token, hook and registry, and the
/// registry's row for that quote, which has to be the standalone shape the Dual Fill terms are
/// derived from. The row's decimals are the quote's own, six on Arc's USDC and eighteen on
/// Robinhood Chain's WETH; every amount the fill handles is a ratio of that row. A broadcast run
/// writes the factory, the keeper, the flag and this chain's own deploy height back into the
/// network's record.
///
/// A deploy over a factory the record already names is a new generation. The factory being
/// replaced goes on the end of `legacyDualFillFactories` before the live key moves: every fill it
/// made is still on chain and still answers to it, and a reader looking one up has nowhere else
/// to find the factory that made it. The list is the same shape as `legacyTokenLaunchFactories`.
///
///   DUAL_FILL_KEEPER          the opener's EVM address; required, and no address the record names
///   DUAL_FILL_NATIVE_WRAP     defaults to true on 4663 and false elsewhere, where true is refused
///   DUAL_FILL_TOKEN_FACTORY   TokenLaunchFactory override; a retired factory is refused
///   DUAL_FILL_ALLOW_REDEPLOY  must be true to deploy over a factory the record already names
///   ALLOW_MAINNET_DEPLOY      must be true to broadcast on chain 4663 or 5042
///   WRITE_DEPLOYMENTS         set false to skip the record write on a broadcast run
///
/// Each network's keeper has a key of its own in `~/.config/ripples/keys.env`, and
/// `DUAL_FILL_KEEPER` is the address it derives to: `DUAL_FILL_MAINNET_KEEPER_KEY` and
/// `DUAL_FILL_TESTNET_KEEPER_KEY` on Robinhood Chain, `DUAL_FILL_ARC_MAINNET_KEEPER_KEY` and
/// `DUAL_FILL_ARC_TESTNET_KEEPER_KEY` on Arc. An Arc deploy refuses a keeper Robinhood Chain's
/// record already names, so the two rails cannot share an opener key.
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployDualFill is Script {
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
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    error RetiredTokenFactory(address target);
    /// The launch factory answered a wiring read with something other than the record.
    error WiringMismatch(string field, address recorded, address answered);
    /// The registry's row for the quote is missing or not the standalone shape
    /// (`standalonePhantomQuote * 5 == graduationThreshold * 2`) the Solana side is sized from.
    error RowUnsupported(address quote);
    error KeeperIsAContract(address keeper);
    /// The keeper is an address a record already gives another job, or the deployer itself.
    error KeeperHoldsAnotherRole(address keeper, string role);
    /// The quote cannot take native currency in: 46630's WETH has no `deposit()`, and Arc settles
    /// in USDC, which is also its gas.
    error NativeWrapUnsupported(uint256 chainId);
    error FactoryAlreadyDeployed(address recorded);
    error RecordCannotHold(string path);

    function run() external returns (DualFillFactory factory) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));
        (string memory file, string memory entry) = recordFor(block.chainid);
        string memory record = vm.readFile(file);
        guardRedeploy(
            recordedAddress(record, entry, "dualFillFactory"),
            vm.envOr("DUAL_FILL_ALLOW_REDEPLOY", false)
        );
        bool writesRecord = writesDeployments();
        if (writesRecord) requireRecordable(vm.readFile(file), entry);

        address tokenFactory =
            resolveTokenFactory(record, entry, vm.envOr("DUAL_FILL_TOKEN_FACTORY", address(0)));
        guardWiring(record, entry, tokenFactory);
        address keeper = vm.envOr("DUAL_FILL_KEEPER", address(0));
        guardKeeper(record, entry, keeper, msg.sender);
        if (!_same(file, DEPLOYMENTS)) guardKeeperIsNotShared(vm.readFile(DEPLOYMENTS), keeper);
        bool nativeWrap = vm.envOr("DUAL_FILL_NATIVE_WRAP", defaultNativeWrap(block.chainid));
        guardNativeWrap(block.chainid, nativeWrap);

        vm.startBroadcast();
        factory = new DualFillFactory(tokenFactory, keeper, nativeWrap);
        vm.stopBroadcast();
        uint256 deployBlock = deployHeight();

        console2.log("network", network);
        console2.log("deployer", msg.sender);
        console2.log("dualFillFactory", address(factory));
        console2.log("dualFillKeeper", factory.KEEPER());
        console2.log("dualFillNativeWrap", factory.NATIVE_WRAP());
        console2.log("dualFillDeployBlock", deployBlock);
        console2.log("tokenLaunchFactory", factory.LAUNCH_FACTORY());
        console2.log("quote", factory.QUOTE());
        console2.log("feeToken", factory.FEE_TOKEN());

        if (writesRecord) {
            recordDeployment(file, entry, address(factory), keeper, nativeWrap, deployBlock);
            console2.log("written to", string.concat(file, _path(entry, "dualFillFactory")));
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
        address keeper,
        bool nativeWrap,
        uint256 deployBlock
    ) public {
        string memory record = vm.readFile(file);
        address previous = recordedAddress(record, entry, "dualFillFactory");
        if (previous != address(0) && previous != factory && previous.code.length != 0) {
            vm.writeJson(
                retiredWith(record, entry, previous), file, _path(entry, "legacyDualFillFactories")
            );
        }
        vm.writeJson(_quoted(vm.toString(factory)), file, _path(entry, "dualFillFactory"));
        vm.writeJson(_quoted(vm.toString(keeper)), file, _path(entry, "dualFillKeeper"));
        vm.writeJson(nativeWrap ? "true" : "false", file, _path(entry, "dualFillNativeWrap"));
        vm.writeJson(vm.toString(deployBlock), file, _path(entry, "dualFillDeployBlock"));
    }

    /// @notice The entry's legacy list with `previous` on the end, as a JSON array. Built by hand
    ///         because forge's serializer returns an object around its arrays, and this key
    ///         holds the bare list. A factory already on it stays where it is, so a deploy re-run
    ///         after a failed record write does not list it twice.
    function retiredWith(string memory record, string memory entry, address previous)
        public
        view
        returns (string memory)
    {
        string memory path = _path(entry, "legacyDualFillFactories");
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
        string[5] memory fields = [
            "dualFillFactory",
            "dualFillKeeper",
            "dualFillNativeWrap",
            "dualFillDeployBlock",
            "legacyDualFillFactories"
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

    /// @notice One factory per network unless the deployer says otherwise. Fills already created
    ///         answer to the factory that made them, and the web and the API refuse a fill whose
    ///         factory is not the one they were built with. A recorded address with no code is a
    ///         record pointing at another chain, which is not a live deployment.
    function guardRedeploy(address recorded, bool allowRedeploy) public view {
        if (allowRedeploy) return;
        if (recorded != address(0) && recorded.code.length != 0) {
            revert FactoryAlreadyDeployed(recorded);
        }
    }

    function resolveTokenFactory(string memory record, string memory entry, address overridden)
        public
        view
        returns (address tokenFactory)
    {
        tokenFactory = overridden != address(0)
            ? overridden
            : recordedAddress(record, entry, "tokenLaunchFactory");
        if (tokenFactory == address(0)) {
            revert DeploymentAddressRequired("DUAL_FILL_TOKEN_FACTORY");
        }
        string memory path = _path(entry, "legacyTokenLaunchFactories");
        if (!vm.keyExistsJson(record, path)) return tokenFactory;
        address[] memory retired = vm.parseJsonAddressArray(record, path);
        for (uint256 i = 0; i < retired.length; i++) {
            if (retired[i] == tokenFactory) revert RetiredTokenFactory(tokenFactory);
        }
    }

    /// @notice The launch factory is the one the record describes, read by read, and its
    ///         registry prices the quote in the only shape the Dual Fill terms know how to mirror.
    function guardWiring(string memory record, string memory entry, address tokenFactory)
        public
        view
    {
        if (tokenFactory.code.length == 0) revert NoCodeAt(tokenFactory);
        (string memory quoteField, string memory feeField) = quoteFields(record, entry);
        address quote = _matches(
            record, entry, quoteField, tokenFactory, IDualFillLaunchFactoryReads.QUOTE.selector
        );
        _matches(
            record, entry, feeField, tokenFactory, IDualFillLaunchFactoryReads.FEE_TOKEN.selector
        );
        _matches(
            record,
            entry,
            "launchHook",
            tokenFactory,
            IDualFillLaunchFactoryReads.launchHook.selector
        );
        address registry = _matches(
            record,
            entry,
            "quoteRegistry",
            tokenFactory,
            IDualFillLaunchFactoryReads.quoteRegistry.selector
        );

        if (registry.code.length == 0 || !IQuoteRegistry(registry).approvedQuote(quote)) {
            revert RowUnsupported(quote);
        }
        IQuoteRegistry.QuoteEconomics memory e = IQuoteRegistry(registry).quoteEconomics(quote);
        // The shape is a ratio, so it holds in any decimals: eighteen for WETH on Robinhood
        // Chain, six for USDC on Arc. What a fill cannot mirror is a row whose standalone
        // reserve is not two fifths of its target.
        if (e.standalonePhantomQuote * 5 != e.graduationThreshold * 2) {
            revert RowUnsupported(quote);
        }
    }

    /// @notice The record's names for the launch factory's default quote and its fee token.
    ///         Robinhood Chain's entry names them apart, because a launch factory can settle fees
    ///         in an asset other than the one it quotes in; Arc's record names one `quote`, which
    ///         its launch factory answers to both reads.
    function quoteFields(string memory record, string memory entry)
        public
        view
        returns (string memory quoteField, string memory feeField)
    {
        quoteField =
            vm.keyExistsJson(record, _path(entry, "defaultQuote")) ? "defaultQuote" : "quote";
        feeField = vm.keyExistsJson(record, _path(entry, "feeToken")) ? "feeToken" : "quote";
    }

    /// @notice The keeper can open and abort fills, so it gets a key of its own: not the
    ///         deployer's, and none the record already names for another job. Every key in the
    ///         network's record is read rather than a list of roles: the record gains roles as the
    ///         platform does, and a list kept here refuses only the ones somebody remembered to
    ///         add. The entry's own `dualFillKeeper` is skipped, so a redeploy can keep the keeper
    ///         it already has.
    function guardKeeper(string memory record, string memory entry, address keeper, address sender)
        public
        view
    {
        if (keeper == address(0)) {
            revert DeploymentAddressRequired("DUAL_FILL_KEEPER");
        }
        if (keeper.code.length != 0) revert KeeperIsAContract(keeper);
        string[] memory fields = vm.parseJsonKeys(record, _entryPath(entry));
        for (uint256 i = 0; i < fields.length; i++) {
            if (_same(fields[i], "dualFillKeeper")) continue;
            if (recordedAddress(record, entry, fields[i]) == keeper) {
                revert KeeperHoldsAnotherRole(keeper, fields[i]);
            }
        }
        if (keeper == sender) revert KeeperHoldsAnotherRole(keeper, "deployer");
    }

    /// @notice A network with a record of its own gets a keeper of its own. `guardKeeper` skips
    ///         the entry's own `dualFillKeeper` so a redeploy can keep the keeper it already has;
    ///         across records nothing is skipped, because one key opening fills on two rails
    ///         makes a single compromise cost both of them.
    function guardKeeperIsNotShared(string memory shared, address keeper) public view {
        string[2] memory entries = ["robinhoodMainnet", "robinhoodTestnet"];
        for (uint256 i = 0; i < entries.length; i++) {
            string memory path = _entryPath(entries[i]);
            if (!vm.keyExistsJson(shared, path)) continue;
            string[] memory fields = vm.parseJsonKeys(shared, path);
            for (uint256 j = 0; j < fields.length; j++) {
                if (recordedAddress(shared, entries[i], fields[j]) == keeper) {
                    revert KeeperHoldsAnotherRole(keeper, fields[j]);
                }
            }
        }
        // The Arc records keep their signing roles under these keys; a key in another network's
        // record is refused. The network's own record is skipped, so a redeploy keeps its keeper.
        string[2] memory arcRecords =
            ["./deployments/arc-mainnet.json", "./deployments/arc-testnet.json"];
        string[3] memory roles = [".dualFillKeeper", ".holderRewardsPublisher", ".graduationKeeper"];
        string memory own =
            block.chainid == 5042 ? arcRecords[0] : block.chainid == 5042002 ? arcRecords[1] : "";
        for (uint256 i = 0; i < arcRecords.length; i++) {
            if (!vm.exists(arcRecords[i]) || _same(arcRecords[i], own)) continue;
            string memory record = vm.readFile(arcRecords[i]);
            for (uint256 j = 0; j < roles.length; j++) {
                if (
                    vm.keyExistsJson(record, roles[j])
                        && vm.parseJsonAddress(record, roles[j]) == keeper
                ) {
                    revert KeeperHoldsAnotherRole(keeper, roles[j]);
                }
            }
        }
    }

    /// @notice Canonical WETH9 on 4663 takes ETH in; `TestnetWETH` on 46630 does not, and Arc
    ///         settles in USDC, which is also its gas and has nothing to wrap.
    function defaultNativeWrap(uint256 chainId) public pure returns (bool) {
        return chainId == RH_MAINNET;
    }

    function guardNativeWrap(uint256 chainId, bool nativeWrap) public pure {
        if (nativeWrap && chainId != RH_MAINNET) revert NativeWrapUnsupported(chainId);
    }

    /// @notice This chain's own height. ArbSys answers it on a live Orbit node; a forked EVM runs
    ///         the precompile's placeholder byte as INVALID, so the read is gas-capped and any
    ///         failure falls back to `block.number`, which is what `Deploy.s.sol` records too.
    function deployHeight() public view returns (uint256) {
        if (block.chainid != RH_TESTNET && block.chainid != RH_MAINNET) return block.number;
        (bool ok, bytes memory answer) = ARB_SYS.staticcall{ gas: ARB_SYS_GAS }(
            abi.encodeCall(IDualFillArbSys.arbBlockNumber, ())
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
    ) private view returns (address answered) {
        address expected = recordedAddress(record, entry, field);
        answered = _read(target, selector);
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

    /// @notice The path of the whole entry: the network's object in a shared record, and the root
    ///         of a record that holds one network.
    function _entryPath(string memory entry) private pure returns (string memory) {
        return bytes(entry).length == 0 ? "." : string.concat(".", entry);
    }

    function _quoted(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
