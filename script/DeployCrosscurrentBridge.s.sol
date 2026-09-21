// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { BridgeBytecode } from "../src/crosscurrent/BridgeBytecode.sol";
import { BridgeDeployer } from "../src/crosscurrent/BridgeDeployer.sol";
import { BridgeMesh, CrosscurrentRegistrar } from "../src/crosscurrent/CrosscurrentRegistrar.sol";
import { BridgePath } from "../src/crosscurrent/SealedOFTConfig.sol";
import { FundedFillCoordinator } from "../src/FundedFillCoordinator.sol";
import { FundedTokenLaunchFactory } from "../src/FundedTokenLaunchFactory.sol";

/// The reads this deploy makes off the launch factory it binds to and the holder factory it
/// hands the coordinator.
interface IBridgePolicyReads {
    function launchHook() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function QUOTE() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function FEE_TOKEN() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function HOOK() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function MESH_HASH() external view returns (bytes32);
}

/// See `Deploy.s.sol`: on an Orbit chain `block.number` is the parent chain's height.
interface IBridgeArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// Deploys one EVM side of a bridged Crosscurrent: the registrar that deploys and seals each
/// launch's bridge, the funded-fill coordinator every fill on this chain settles through, and the
/// funded launch factory that opens their markets on the launch hook the policy factory names.
///
/// The three bind to each other at construction, so their addresses are fixed before anything is
/// sent: forge deploys the linked libraries first, then the registrar goes at the deployer's next
/// nonce, then the coordinator, then the market factory, and each is checked against the address
/// it was promised. The mesh names both chains' registrar and coordinator, so the other chain's
/// pair is computed from the same deployer's account nonce there (BRIDGED_OTHER_NONCE) plus the
/// same library count; with BRIDGED_OTHER_RPC set the other chain is read first, and a registrar
/// already there has to answer this run's mesh hash exactly.
///
/// The LayerZero endpoint, message libraries, executor and DVNs come from the official deployment
/// metadata and are fixed per chain below, the same pairs the sealed bridge accepts. What varies is
/// said outright and identically on both chains, because the mesh commits to both policies:
///
///   BRIDGED_AUTHORIZER            the API's setup signer for this release
///   BRIDGED_KEEPER                this chain's opener, the only sender the coordinator opens for
///   BRIDGED_HOLDER_FACTORY        holder factory bound to the policy's launch hook, or zero
///   BRIDGED_OTHER_NONCE           the deployer's account nonce on the other chain before it deploys there
///   BRIDGED_OTHER_RPC             optional: read the other chain before deploying here
///   BRIDGED_RH_CONFIRMATIONS      block confirmations DVNs wait for on Robinhood Chain
///   BRIDGED_ARC_CONFIRMATIONS     block confirmations DVNs wait for on Arc
///   BRIDGED_SOLANA_CONFIRMATIONS  slot confirmations DVNs wait for on Solana
///   BRIDGED_SOLANA_FILL           the Solana fill program, as 32 bytes
///   BRIDGED_SOLANA_REGISTRAR      the Solana registrar program, as 32 bytes
///   BRIDGED_SOLANA_SETTINGS_HASH  the Solana registrar's settings commitment
///   BRIDGED_POLICY_FACTORY        optional: the launch factory, otherwise the record's
///   ALLOW_MAINNET_DEPLOY          must be true to broadcast on chain 4663 or 5042
///   WRITE_DEPLOYMENTS             set false to skip the record write on a broadcast run
///
/// A broadcast run writes deployments/crosscurrent-bridge-<network>.json with everything the
/// release builder reads, and deployments/crosscurrent-bridge-creation-code.json with the two
/// wrapper creation bytecodes the API hands the registrar, pinned by hash in BridgeBytecode.
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it.
contract DeployCrosscurrentBridge is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    string internal constant DEPLOYMENTS = "./deployments.json";
    string internal constant CREATION_CODE = "./deployments/crosscurrent-bridge-creation-code.json";
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    uint256 internal constant ARB_SYS_GAS = 100_000;
    uint32 internal constant MAX_MESSAGE_SIZE = 10_000;
    uint128 internal constant RECEIVE_GAS = 200_000;
    uint128 internal constant COMPOSE_RECEIVE_GAS = 300_000;

    struct Wiring {
        uint256 chainId;
        uint32 eid;
        uint8 local;
        address endpoint;
        address sendLibrary;
        address receiveLibrary;
        address executor;
        address[2] dvns;
        bool nativeWrap;
        string network;
        string recordFile;
        string recordEntry;
    }

    struct Settings {
        address deployer;
        address authorizer;
        address keeper;
        address policyFactory;
        address holderFactory;
        uint256 accountNonce;
        uint256 linkedLibraries;
        uint256 localNonce;
        uint256 otherNonce;
        uint64 rhConfirmations;
        uint64 arcConfirmations;
        uint64 solanaConfirmations;
        bytes32 solanaFill;
        bytes32 solanaRegistrar;
        bytes32 solanaSettingsHash;
    }

    struct Plan {
        Wiring home;
        Wiring other;
        Settings settings;
        BridgeMesh mesh;
        BridgePath[2] policy;
        address registrar;
        address coordinator;
        address marketFactory;
    }

    error MainnetNotAuthorized();
    error UnsupportedChain(uint256 chainId);
    error MissingSetting(string name);
    error NoCodeAt(string role, address target);
    error HookMismatch(address holderFactory, address hook, address launchHook);
    error PredictionFailed(string role, address predicted, address deployed);
    error OtherChainMismatch(string field);
    error CreationCodeDrift(string role);

    function run() external returns (CrosscurrentRegistrar registrar) {
        Plan memory plan = preflight();
        checkOtherChain(plan);
        if (isMainnet(block.chainid) && _isBroadcast() && !vm.envOr("ALLOW_MAINNET_DEPLOY", false)) {
            revert MainnetNotAuthorized();
        }

        vm.startBroadcast();
        registrar = new CrosscurrentRegistrar(plan.mesh, plan.policy, plan.settings.authorizer);
        FundedFillCoordinator coordinator = new FundedFillCoordinator(
            address(registrar),
            plan.settings.keeper,
            plan.settings.policyFactory,
            plan.marketFactory,
            plan.home.nativeWrap,
            plan.settings.holderFactory
        );
        FundedTokenLaunchFactory marketFactory =
            new FundedTokenLaunchFactory(plan.settings.policyFactory, address(coordinator));
        vm.stopBroadcast();

        if (address(registrar) != plan.registrar) {
            revert PredictionFailed("registrar", plan.registrar, address(registrar));
        }
        if (address(coordinator) != plan.coordinator) {
            revert PredictionFailed("coordinator", plan.coordinator, address(coordinator));
        }
        if (address(marketFactory) != plan.marketFactory) {
            revert PredictionFailed("marketFactory", plan.marketFactory, address(marketFactory));
        }
        uint256 deployBlock = deployHeight();

        console2.log("network", plan.home.network);
        console2.log("deployer", plan.settings.deployer);
        console2.log("registrar", address(registrar));
        console2.log("coordinator", address(coordinator));
        console2.log("marketFactory", address(marketFactory));
        console2.log("meshHash");
        console2.logBytes32(registrar.MESH_HASH());
        console2.log("accountNonce", plan.settings.accountNonce);
        console2.log("linkedLibraries", plan.settings.linkedLibraries);
        console2.log("otherNonce", plan.settings.otherNonce);
        console2.log("deployBlock", deployBlock);

        string memory record = recordJson(plan, deployBlock);
        if (_isBroadcast() && vm.envOr("WRITE_DEPLOYMENTS", true)) {
            string memory recordPath = string.concat("./deployments/crosscurrent-bridge-", plan.home.network, ".json");
            vm.writeJson(record, recordPath);
            vm.writeJson(creationCodeJson(), CREATION_CODE);
            console2.log("written to", recordPath);
        } else {
            console2.log("record (not written: dry run)");
            console2.log(record);
        }
    }

    /// @notice Everything a run needs, read and checked before a single transaction: the chain's
    ///         fixed LayerZero wiring, the settings named in the environment, the three
    ///         addresses this deploy will produce, and the mesh both chains commit to.
    function preflight() public returns (Plan memory plan) {
        plan.home = wiring(block.chainid);
        plan.other = wiring(otherChainId(block.chainid));
        Settings memory s;
        s.deployer = msg.sender;
        s.authorizer = requireAddress("BRIDGED_AUTHORIZER");
        s.keeper = requireAddress("BRIDGED_KEEPER");
        s.otherNonce = vm.envUint("BRIDGED_OTHER_NONCE");
        // Forge deploys the linked libraries from the same account before the script's own
        // creates, so the simulated nonce runs ahead of the chain's by their count. The other
        // chain links the same build, so its registrar sits the same distance past its nonce.
        s.accountNonce = accountNonce(s.deployer);
        s.localNonce = vm.getNonce(s.deployer);
        if (s.localNonce < s.accountNonce) revert MissingSetting("nonce");
        s.linkedLibraries = s.localNonce - s.accountNonce;
        s.rhConfirmations = uint64(vm.envUint("BRIDGED_RH_CONFIRMATIONS"));
        s.arcConfirmations = uint64(vm.envUint("BRIDGED_ARC_CONFIRMATIONS"));
        s.solanaConfirmations = uint64(vm.envUint("BRIDGED_SOLANA_CONFIRMATIONS"));
        s.solanaFill = vm.envBytes32("BRIDGED_SOLANA_FILL");
        s.solanaRegistrar = vm.envBytes32("BRIDGED_SOLANA_REGISTRAR");
        s.solanaSettingsHash = vm.envBytes32("BRIDGED_SOLANA_SETTINGS_HASH");
        if (s.rhConfirmations == 0 || s.arcConfirmations == 0 || s.solanaConfirmations == 0) {
            revert MissingSetting("BRIDGED_*_CONFIRMATIONS");
        }

        string memory record = vm.readFile(plan.home.recordFile);
        s.policyFactory = vm.envOr(
            "BRIDGED_POLICY_FACTORY",
            vm.parseJsonAddress(record, string.concat(plan.home.recordEntry, ".tokenLaunchFactory"))
        );
        s.holderFactory = vm.envOr(
            "BRIDGED_HOLDER_FACTORY",
            recordedAddress(record, string.concat(plan.home.recordEntry, ".holderRewardsFactory"))
        );
        if (s.policyFactory.code.length == 0) revert NoCodeAt("policyFactory", s.policyFactory);
        if (plan.home.endpoint.code.length == 0) revert NoCodeAt("endpoint", plan.home.endpoint);
        if (s.holderFactory != address(0)) {
            if (s.holderFactory.code.length == 0) revert NoCodeAt("holderFactory", s.holderFactory);
            address hook = IBridgePolicyReads(s.holderFactory).HOOK();
            address launchHook = IBridgePolicyReads(s.policyFactory).launchHook();
            if (hook != launchHook) revert HookMismatch(s.holderFactory, hook, launchHook);
        }
        plan.settings = s;

        plan.registrar = vm.computeCreateAddress(s.deployer, s.localNonce);
        plan.coordinator = vm.computeCreateAddress(s.deployer, s.localNonce + 1);
        plan.marketFactory = vm.computeCreateAddress(s.deployer, s.localNonce + 2);
        address otherRegistrar = vm.computeCreateAddress(s.deployer, s.otherNonce + s.linkedLibraries);
        address otherCoordinator = vm.computeCreateAddress(s.deployer, s.otherNonce + s.linkedLibraries + 1);

        Wiring memory rh = plan.home.local == 0 ? plan.home : plan.other;
        Wiring memory arc = plan.home.local == 0 ? plan.other : plan.home;
        BridgePath[2] memory rhPolicy = policyFor(rh, arc, s);
        BridgePath[2] memory arcPolicy = policyFor(arc, rh, s);
        plan.mesh = BridgeMesh({
            robinhoodChainId: rh.chainId,
            arcChainId: arc.chainId,
            robinhoodFactory: plan.home.local == 0 ? plan.registrar : otherRegistrar,
            arcFactory: plan.home.local == 0 ? otherRegistrar : plan.registrar,
            robinhoodCoordinator: plan.home.local == 0 ? plan.coordinator : otherCoordinator,
            arcCoordinator: plan.home.local == 0 ? otherCoordinator : plan.coordinator,
            robinhoodPolicyHash: keccak256(abi.encode(rhPolicy)),
            arcPolicyHash: keccak256(abi.encode(arcPolicy)),
            solanaProgram: s.solanaFill,
            solanaRegistrar: s.solanaRegistrar,
            solanaSettingsHash: s.solanaSettingsHash
        });
        plan.policy = plan.home.local == 0 ? rhPolicy : arcPolicy;
        checkCreationCode();
    }

    /// @notice The two paths a chain's bridges are sealed with: Solana first, the other EVM chain
    ///         second, the order the registrar requires. Confirmations are the source chain's for
    ///         sending and the destination's for receiving.
    function policyFor(Wiring memory home, Wiring memory other, Settings memory s)
        public
        pure
        returns (BridgePath[2] memory paths)
    {
        uint64 homeConfirmations = confirmationsFor(home.chainId, s);
        paths[0] = bridgePath(home, solanaEid(home.chainId), homeConfirmations, s.solanaConfirmations);
        paths[1] = bridgePath(home, other.eid, homeConfirmations, confirmationsFor(other.chainId, s));
    }

    function bridgePath(Wiring memory home, uint32 eid, uint64 sendConfirmations, uint64 receiveConfirmations)
        internal
        pure
        returns (BridgePath memory)
    {
        return BridgePath({
            eid: eid,
            peer: bytes32(0),
            sendLibrary: home.sendLibrary,
            receiveLibrary: home.receiveLibrary,
            executor: home.executor,
            dvns: home.dvns,
            sendConfirmations: sendConfirmations,
            receiveConfirmations: receiveConfirmations,
            maxMessageSize: MAX_MESSAGE_SIZE,
            receiveGas: RECEIVE_GAS,
            composeReceiveGas: COMPOSE_RECEIVE_GAS,
            receiveValue: 0
        });
    }

    function confirmationsFor(uint256 chainId, Settings memory s) internal pure returns (uint64) {
        return chainId == RH_MAINNET || chainId == RH_TESTNET ? s.rhConfirmations : s.arcConfirmations;
    }

    function solanaEid(uint256 chainId) internal pure returns (uint32) {
        return isMainnet(chainId) ? 30168 : 40168;
    }

    /// @notice With BRIDGED_OTHER_RPC set, the other chain is read before anything is sent here. A
    ///         registrar already deployed there must carry this run's mesh hash; with nothing there
    ///         yet, the deployer's account nonce there must be the one the mesh was computed from.
    function checkOtherChain(Plan memory plan) public {
        string memory rpc = vm.envOr("BRIDGED_OTHER_RPC", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("BRIDGED_OTHER_RPC unset: the other chain was not read");
            return;
        }
        uint256 home = vm.activeFork();
        vm.createSelectFork(rpc);
        if (block.chainid != plan.other.chainId) revert OtherChainMismatch("chain id");
        address otherRegistrar = plan.home.local == 0 ? plan.mesh.arcFactory : plan.mesh.robinhoodFactory;
        if (otherRegistrar.code.length != 0) {
            bytes32 expected = keccak256(abi.encode(plan.mesh, plan.settings.authorizer));
            if (IBridgePolicyReads(otherRegistrar).MESH_HASH() != expected) revert OtherChainMismatch("mesh hash");
            console2.log("other chain registrar answers this mesh", otherRegistrar);
        } else {
            if (accountNonce(plan.settings.deployer) != plan.settings.otherNonce) revert OtherChainMismatch("nonce");
            console2.log("other chain is undeployed at the promised nonce", plan.settings.otherNonce);
        }
        vm.selectFork(home);
    }

    /// @notice The wrapper creation code the registrar accepts is pinned by hash in the contracts;
    ///         the artifacts this build produced have to be that code, or the API would hand the
    ///         registrar bytecode it refuses.
    function checkCreationCode() public view {
        if (keccak256(vm.getCode("CrosscurrentAdapter.sol:CrosscurrentAdapter")) != BridgeBytecode.ADAPTER) {
            revert CreationCodeDrift("adapter");
        }
        if (keccak256(vm.getCode("CrosscurrentOFT.sol:CrosscurrentOFT")) != BridgeBytecode.OFT) {
            revert CreationCodeDrift("oft");
        }
    }

    function creationCodeJson() public returns (string memory) {
        string memory json = "creationCode";
        vm.serializeBytes(json, "adapter", vm.getCode("CrosscurrentAdapter.sol:CrosscurrentAdapter"));
        return vm.serializeBytes(json, "oft", vm.getCode("CrosscurrentOFT.sol:CrosscurrentOFT"));
    }

    /// @notice The record the release builder reads: every address the release commits to, the
    ///         wiring and policy the bridges are sealed with, and the mesh as deployed.
    function recordJson(Plan memory plan, uint256 deployBlock) public returns (string memory) {
        string memory meshKey = "meshRecord";
        vm.serializeUint(meshKey, "robinhoodChainId", plan.mesh.robinhoodChainId);
        vm.serializeUint(meshKey, "arcChainId", plan.mesh.arcChainId);
        vm.serializeAddress(meshKey, "robinhoodFactory", plan.mesh.robinhoodFactory);
        vm.serializeAddress(meshKey, "arcFactory", plan.mesh.arcFactory);
        vm.serializeAddress(meshKey, "robinhoodCoordinator", plan.mesh.robinhoodCoordinator);
        vm.serializeAddress(meshKey, "arcCoordinator", plan.mesh.arcCoordinator);
        vm.serializeBytes32(meshKey, "robinhoodPolicyHash", plan.mesh.robinhoodPolicyHash);
        vm.serializeBytes32(meshKey, "arcPolicyHash", plan.mesh.arcPolicyHash);
        vm.serializeBytes32(meshKey, "solanaProgram", plan.mesh.solanaProgram);
        vm.serializeBytes32(meshKey, "solanaRegistrar", plan.mesh.solanaRegistrar);
        string memory meshJson = vm.serializeBytes32(meshKey, "solanaSettingsHash", plan.mesh.solanaSettingsHash);

        string memory policyKey = "wiringRecord";
        vm.serializeAddress(policyKey, "endpoint", plan.home.endpoint);
        vm.serializeAddress(policyKey, "sendLibrary", plan.home.sendLibrary);
        vm.serializeAddress(policyKey, "receiveLibrary", plan.home.receiveLibrary);
        vm.serializeAddress(policyKey, "executor", plan.home.executor);
        address[] memory dvns = new address[](plan.home.dvns[1] == address(0) ? 1 : 2);
        dvns[0] = plan.home.dvns[0];
        if (dvns.length == 2) dvns[1] = plan.home.dvns[1];
        vm.serializeAddress(policyKey, "dvns", dvns);
        vm.serializeUint(policyKey, "solanaEid", solanaEid(plan.home.chainId));
        vm.serializeUint(policyKey, "otherEid", plan.other.eid);
        vm.serializeUint(policyKey, "robinhoodConfirmations", plan.settings.rhConfirmations);
        vm.serializeUint(policyKey, "arcConfirmations", plan.settings.arcConfirmations);
        vm.serializeUint(policyKey, "solanaConfirmations", plan.settings.solanaConfirmations);
        vm.serializeUint(policyKey, "maxMessageSize", MAX_MESSAGE_SIZE);
        vm.serializeUint(policyKey, "receiveGas", RECEIVE_GAS);
        vm.serializeUint(policyKey, "composeReceiveGas", COMPOSE_RECEIVE_GAS);
        string memory policyJson = vm.serializeUint(policyKey, "receiveValue", 0);

        string memory out = "record";
        vm.serializeUint(out, "chainId", plan.home.chainId);
        vm.serializeString(out, "network", plan.home.network);
        vm.serializeUint(out, "localIndex", plan.home.local);
        vm.serializeUint(out, "eid", plan.home.eid);
        vm.serializeAddress(out, "deployer", plan.settings.deployer);
        vm.serializeUint(out, "deployBlock", deployBlock);
        vm.serializeUint(out, "accountNonce", plan.settings.accountNonce);
        vm.serializeUint(out, "linkedLibraries", plan.settings.linkedLibraries);
        vm.serializeUint(out, "localNonce", plan.settings.localNonce);
        vm.serializeUint(out, "otherNonce", plan.settings.otherNonce);
        vm.serializeAddress(out, "registrar", plan.registrar);
        vm.serializeAddress(out, "coordinator", plan.coordinator);
        vm.serializeAddress(out, "marketFactory", plan.marketFactory);
        vm.serializeAddress(out, "policyFactory", plan.settings.policyFactory);
        vm.serializeAddress(out, "holderRewardsFactory", plan.settings.holderFactory);
        vm.serializeAddress(out, "keeper", plan.settings.keeper);
        vm.serializeAddress(out, "authorizer", plan.settings.authorizer);
        vm.serializeAddress(out, "quote", IBridgePolicyReads(plan.settings.policyFactory).QUOTE());
        vm.serializeAddress(out, "feeToken", IBridgePolicyReads(plan.settings.policyFactory).FEE_TOKEN());
        vm.serializeBool(out, "nativeWrap", plan.home.nativeWrap);
        vm.serializeBytes32(out, "meshHash", keccak256(abi.encode(plan.mesh, plan.settings.authorizer)));
        vm.serializeBytes32(out, "deployerCodeHash", keccak256(type(BridgeDeployer).creationCode));
        vm.serializeBytes32(out, "adapterCreationCodeHash", BridgeBytecode.ADAPTER);
        vm.serializeBytes32(out, "oftCreationCodeHash", BridgeBytecode.OFT);
        vm.serializeString(out, "mesh", meshJson);
        return vm.serializeString(out, "wiring", policyJson);
    }

    /// @notice The fixed LayerZero wiring per chain: the endpoint, the ULN 302 message libraries,
    ///         the executor and the DVN pair, from the official deployment metadata and identical
    ///         to what SealedOFTConfig accepts. Mainnet pairs LayerZero Labs with Nethermind, in
    ///         address order; the testnets have LayerZero Labs alone.
    function wiring(uint256 chainId) public pure returns (Wiring memory c) {
        c.chainId = chainId;
        if (chainId == RH_MAINNET) {
            c.eid = 30416;
            c.local = 0;
            c.endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
            c.sendLibrary = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
            c.receiveLibrary = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
            c.executor = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
            c.dvns = [0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8, 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12];
            c.nativeWrap = true;
            c.network = "robinhood-mainnet";
            c.recordFile = DEPLOYMENTS;
            c.recordEntry = ".robinhoodMainnet";
        } else if (chainId == ARC_MAINNET) {
            c.eid = 30417;
            c.local = 1;
            c.endpoint = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
            c.sendLibrary = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
            c.receiveLibrary = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
            c.executor = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
            c.dvns = [0x9E0E95Ede70F680f74480b510FF9f45C70e3da80, 0xa2447e5B58D357c49Bf74B50B14421e6A100e525];
            c.nativeWrap = false;
            c.network = "arc-mainnet";
            c.recordFile = "./deployments/arc-mainnet.json";
            c.recordEntry = "";
        } else if (chainId == RH_TESTNET) {
            c.eid = 40451;
            c.local = 0;
            c.endpoint = 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32;
            c.sendLibrary = 0x45841dd1ca50265Da7614fC43A361e526c0e6160;
            c.receiveLibrary = 0xd682ECF100f6F4284138AA925348633B0611Ae21;
            c.executor = 0x701f3927871EfcEa1235dB722f9E608aE120d243;
            c.dvns = [0xa78A78a13074eD93aD447a26Ec57121f29E8feC2, address(0)];
            c.nativeWrap = true;
            c.network = "robinhood-testnet";
            c.recordFile = DEPLOYMENTS;
            c.recordEntry = ".robinhoodTestnet";
        } else if (chainId == ARC_TESTNET) {
            c.eid = 40434;
            c.local = 1;
            c.endpoint = 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff;
            c.sendLibrary = 0xd682ECF100f6F4284138AA925348633B0611Ae21;
            c.receiveLibrary = 0xcF1B0F4106B0324F96fEfcC31bA9498caa80701C;
            c.executor = 0x9dB9Ca3305B48F196D18082e91cB64663b13d014;
            c.dvns = [0x88B27057A9e00c5F05DDa29241027afF63f9e6e0, address(0)];
            c.nativeWrap = false;
            c.network = "arc-testnet";
            c.recordFile = "./deployments/arc-testnet.json";
            c.recordEntry = "";
        } else {
            revert UnsupportedChain(chainId);
        }
    }

    function otherChainId(uint256 chainId) public pure returns (uint256) {
        if (chainId == RH_MAINNET) return ARC_MAINNET;
        if (chainId == ARC_MAINNET) return RH_MAINNET;
        if (chainId == RH_TESTNET) return ARC_TESTNET;
        if (chainId == ARC_TESTNET) return RH_TESTNET;
        revert UnsupportedChain(chainId);
    }

    function isMainnet(uint256 chainId) public pure returns (bool) {
        return chainId == RH_MAINNET || chainId == ARC_MAINNET;
    }

    /// @notice This chain's own height. ArbSys answers it on a live Orbit node; a forked EVM runs
    ///         the precompile's placeholder byte as INVALID, so the read is gas-capped and any
    ///         failure falls back to `block.number`.
    function deployHeight() public view returns (uint256) {
        if (block.chainid != RH_TESTNET && block.chainid != RH_MAINNET) return block.number;
        (bool ok, bytes memory answer) =
            ARB_SYS.staticcall{ gas: ARB_SYS_GAS }(abi.encodeCall(IBridgeArbSys.arbBlockNumber, ()));
        if (!ok || answer.length < 32) return block.number;
        uint256 height = abi.decode(answer, (uint256));
        return height == 0 ? block.number : height;
    }

    /// @notice One address the record carries, or zero when the key is absent or null. Probed
    ///         rather than parsed, because `vm.parseJsonAddress` reverts on `null`.
    function recordedAddress(string memory record, string memory path) public view returns (address) {
        if (!vm.keyExistsJson(record, path)) return address(0);
        bytes memory value = vm.parseJson(record, path);
        if (value.length != 32) return address(0);
        uint256 word = abi.decode(value, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
    }

    /// @notice The account's nonce as the chain reports it, which is what its next transaction
    ///         will carry, rather than the simulation's count.
    function accountNonce(address account) public returns (uint256) {
        bytes memory answer = vm.rpc(
            "eth_getTransactionCount", string.concat("[\"", vm.toString(account), "\",\"latest\"]")
        );
        uint256 value;
        for (uint256 i = 0; i < answer.length; i++) value = (value << 8) | uint8(answer[i]);
        return value;
    }

    function requireAddress(string memory name) internal view returns (address value) {
        value = vm.envOr(name, address(0));
        if (value == address(0)) revert MissingSetting(name);
    }

    function _isBroadcast() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
