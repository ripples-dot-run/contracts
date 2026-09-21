// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { WorkSplitFactory } from "../src/WorkSplitFactory.sol";

/// The reads that identify the launch factory this deployment is wired to, so an address that is
/// merely code at the right place cannot be mistaken for the right contract. `FEE_TOKEN` because
/// it is the runway every split is funded in and the asset every commission is denominated in,
/// `launchHook` because a split claims its trade fees from the hook its own locker names.
interface ITokenLaunchReads {
    // solhint-disable-next-line func-name-mixedcase
    function FEE_TOKEN() external view returns (address);
    /// The factory's resolved default quote, which is the asset a launch naming none settles in.
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
    function launchHook() external view returns (address);
}

/// `PERMIT2()` is the read that tells a venue-side contract from a launch factory. Both of the
/// addresses that sit nearest `tokenLaunchFactory` in the record answer it and neither creates a
/// launch.
interface IVenueReads {
    // solhint-disable-next-line func-name-mixedcase
    function PERMIT2() external view returns (address);
}

/// Deploys `WorkSplitFactory`, the contract a launch that pays a commission is created through.
/// The factory deploys the `ScoutRegistry` its splits read a buyer's binding from in the same
/// transaction, so this script broadcasts once and prints two addresses. It has no owner, no fee
/// and no allowlist: the launch factory is fixed at construction and nothing already deployed is
/// touched or reconfigured.
///
/// The launch factory comes from the network's own entry in deployments.json, so a factory
/// redeploy cannot leave this one pointing at something retired: it points at whatever the record
/// says is live on the day it is deployed, and after that it is immutable. A split wired to a
/// retired factory would open launches the site cannot see, and the artist would find out when
/// the first buyer could not mint.
///
/// A broadcast run writes both addresses back into that entry, which is what the site reads and
/// what the redeploy guard reads on the next run. A dry run and a test print them and touch
/// nothing.
///
///   WORK_TOKEN_FACTORY    TokenLaunchFactory override; defaults to the network's record
///   WORK_LAUNCH_HOOK      LaunchHook override, which the launch factory is checked against
///   WORK_ALLOW_REDEPLOY   must be true to deploy over a factory the record already names
///   ALLOW_MAINNET_DEPLOY  must be true to broadcast on chain 4663
///   WRITE_DEPLOYMENTS     set false to skip the deployments.json write on a broadcast run
///
/// Every override is prefixed, because forge shares one environment across the tests that drive
/// the other deploy scripts too.
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployWorkSplit is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant DEPLOYMENTS = "./deployments.json";

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error DeploymentAddressRequired(string variableName);
    error NoCodeAt(address target);
    error NotTheTokenFactory(address target);
    /// The address given for the launch factory is one this network has retired.
    error RetiredTokenFactory(address target);
    /// The launch factory's default quote is not the asset it charges its fee in.
    error QuoteIsNotTheFeeToken(address factory);
    /// The address given is venue-side rather than a launch factory, or names another hook.
    error NotTheLaunchFactory(address target);
    /// This network's record already names a factory that is live.
    error FactoryAlreadyDeployed(address recorded);
    /// The network's entry has no key to hold one of the two addresses this deploy produces.
    error RecordCannotHold(string path);

    function run() external returns (WorkSplitFactory work) {
        string memory network = guardNetwork(block.chainid, vm.envOr("ALLOW_MAINNET_DEPLOY", false));
        guardRedeploy(
            _recorded(network, "workSplitFactory"), vm.envOr("WORK_ALLOW_REDEPLOY", false)
        );
        bool writesRecord = writesDeployments();
        if (writesRecord) requireRecordable(vm.readFile(DEPLOYMENTS), network);
        address tokenFactory = resolveWiring(
            network,
            _resolve("WORK_TOKEN_FACTORY", network, "tokenLaunchFactory"),
            _resolve("WORK_LAUNCH_HOOK", network, "launchHook")
        );

        vm.startBroadcast();
        work = new WorkSplitFactory(tokenFactory);
        vm.stopBroadcast();

        console2.log("workSplitFactory", address(work));
        console2.log("scoutRegistry", work.SCOUT_REGISTRY());
        console2.log("tokenLaunchFactory", work.TOKEN_FACTORY());
        console2.log("runwayAsset", address(work.RUNWAY_ASSET()));
        console2.log("network", network);

        if (writesRecord) {
            recordDeployment(DEPLOYMENTS, network, address(work), work.SCOUT_REGISTRY());
            console2.log("written to deployments.json under", string.concat(".", network));
            console2.log("commit it: the site and this script's redeploy guard both read it");
            return work;
        }
        if (_isBroadcast()) {
            console2.log("WRITE_DEPLOYMENTS is false, so nothing was written");
            console2.log(
                "record workSplitFactory and scoutRegistry under", string.concat(".", network)
            );
        }
    }

    /// @notice Write the pair this deploy produced into the network's entry, which is where the
    ///         site looks the commission up and where the guard on the next run looks for a
    ///         factory that already exists.
    /// @dev Public and given its file, so the write can be exercised against a copy of the record
    ///      rather than only by a deploy. `vm.writeJson` replaces one value and leaves the rest of
    ///      the document alone, so a run of this script cannot disturb another network's entry.
    ///
    ///      forge writes the file during the simulation, so a broadcast that fails after it leaves
    ///      an address with no code behind it. `guardRedeploy` reads that as no deployment and the
    ///      next run overwrites it, which is why the write can safely come before the receipt.
    function recordDeployment(
        string memory file,
        string memory network,
        address factory,
        address registry
    ) public {
        vm.writeJson(_jsonString(vm.toString(factory)), file, _path(network, "workSplitFactory"));
        vm.writeJson(_jsonString(vm.toString(registry)), file, _path(network, "scoutRegistry"));
        // The note beside them says the pair is not deployed yet, which stops being true on the
        // line above, and it is read by whoever is deciding whether to deploy again.
        string memory note = _path(network, "workSplitNote");
        if (vm.keyExistsJson(vm.readFile(file), note)) {
            vm.writeJson(_jsonString(_deployedNote()), file, note);
        }
    }

    /// @notice Refuse to deploy into a record that cannot hold the result.
    /// @dev The keys are carried as null on a network with no factory yet, which is what makes
    ///      them writable. A network entry that omits them altogether would take the deploy and
    ///      then swallow both addresses.
    function requireRecordable(string memory record, string memory network) public view {
        string[2] memory fields = ["workSplitFactory", "scoutRegistry"];
        for (uint256 i = 0; i < fields.length; i++) {
            string memory path = _path(network, fields[i]);
            if (!vm.keyExistsJson(record, path)) revert RecordCannotHold(path);
        }
    }

    /// @notice Everything that stands between a typo and an immutable factory wired to the wrong
    ///         contract, with the addresses passed in rather than read, so the rules can be
    ///         checked without an environment.
    /// @param network The record's key for this chain, which is where the retired list comes from.
    function resolveWiring(string memory network, address tokenFactory, address hook)
        public
        view
        returns (address)
    {
        if (tokenFactory.code.length == 0) revert NoCodeAt(tokenFactory);
        // Asked first because it is the read that names the two contracts a typo here actually
        // reaches. `launchRouter` and `agentTreasuryFactory` sit within a few lines of
        // `tokenLaunchFactory` in the record and both answer `PERMIT2()`; no launch factory
        // does, so the answer on its own is the refusal, and the deployer is told which kind of
        // address they pasted rather than that it is not a launch factory.
        if (_read(tokenFactory, IVenueReads.PERMIT2.selector) != address(0)) {
            revert NotTheLaunchFactory(tokenFactory);
        }

        address feeToken = _read(tokenFactory, ITokenLaunchReads.FEE_TOKEN.selector);
        if (feeToken == address(0)) revert NotTheTokenFactory(tokenFactory);
        // A split is funded in the fee token, pays the launch fee out of it, and divides its mint
        // revenue in whatever the collection was paid in, which is the launch's quote. A factory
        // whose default quote is something else would deploy splits funded in one asset and
        // paying a published commission in another.
        if (_read(tokenFactory, ITokenLaunchReads.QUOTE.selector) != feeToken) {
            revert QuoteIsNotTheFeeToken(tokenFactory);
        }
        // A split reads the hook off its own locker and claims the creator's share of every trade
        // fee from it, so the hook this factory opens pools with is the escrow every commission on
        // this network is eventually paid out of. Wired to a factory keyed to another generation's
        // hook, the splits would still launch and still settle mints, and the trade side would pay
        // out of an escrow no page on this network reads. Zero fails it too: a factory with no
        // hook wired creates nothing at all.
        if (_read(tokenFactory, ITokenLaunchReads.launchHook.selector) != hook) {
            revert NotTheLaunchFactory(tokenFactory);
        }
        // A retired factory answers every read the live one does. Only the record tells them
        // apart, and the two addresses sit one line from each other in it.
        _refuseRetired(tokenFactory, network);
        return tokenFactory;
    }

    /// @notice Refuse a second factory on a network that already has one, unless the deployer
    ///         said they meant it with `WORK_ALLOW_REDEPLOY`.
    /// @dev The record's own entry is the only thing that knows a live factory exists, and it is
    ///      zero until the first deploy fills it in, so this passes on a fresh network and on any
    ///      rehearsal against a chain the record has no entry for. A recorded address with no
    ///      code behind it is a record pointing at a chain this run is not on, which is the shape
    ///      a fork rehearsal leaves, and it is not a live deployment.
    /// @param recorded What `workSplitFactory` says under this network's key, or zero.
    function guardRedeploy(address recorded, bool allowRedeploy) public view {
        if (allowRedeploy) return;
        if (recorded != address(0) && recorded.code.length != 0) {
            revert FactoryAlreadyDeployed(recorded);
        }
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

    /// @notice One address the record already carries, or zero when the key is absent or still
    ///         null.
    /// @dev `_resolve` cannot do this job: it treats a missing address as the deployer's mistake
    ///      and reverts, and here an empty entry is the ordinary state before the first deploy.
    ///      The value is probed rather than parsed and caught, because `vm.parseJsonAddress`
    ///      reverts on that `null` and a caught revert still heads the trace of a run that failed
    ///      for some other reason.
    /// @param record The deployment record, passed in so the reading rule can be checked against
    ///        a document rather than against whatever the committed file happens to say.
    function recordedAddress(string memory record, string memory network, string memory field)
        public
        view
        returns (address)
    {
        string memory path = _path(network, field);
        if (!vm.keyExistsJson(record, path)) return address(0);
        bytes memory value = vm.parseJson(record, path);
        // `null` decodes to a zero word. Anything that is not one word, or one word with bits
        // above the low 160, is not an address and is treated as no entry rather than parsed.
        if (value.length != 32) return address(0);
        uint256 word = abi.decode(value, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    function _recorded(string memory network, string memory field) private view returns (address) {
        return recordedAddress(vm.readFile(DEPLOYMENTS), network, field);
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

    /// @notice True when this run will record itself in deployments.json.
    /// @dev A dry run, a fork rehearsal and `forge test` all print the addresses and write
    ///      nothing, so the committed record only ever names contracts that are on a chain.
    function writesDeployments() public view returns (bool) {
        return _isBroadcast() && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    /// What the record says about the pair once it exists, in the shape the sibling notes use:
    /// when, what it is bound to, and what a redeploy of that binding costs.
    function _deployedNote() private view returns (string memory) {
        return string.concat(
            "Deployed in block ",
            vm.toString(block.number),
            ". Ownerless and immutable, and it binds tokenLaunchFactory as a constructor immutable ",
            "and deploys scoutRegistry from its own constructor, so a launch factory redeploy needs ",
            "a new pair and both addresses move with it."
        );
    }

    /// writeJson takes a JSON document, so a bare value has to arrive quoted.
    function _jsonString(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }
}
