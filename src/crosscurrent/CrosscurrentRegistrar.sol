// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CanonicalTokenParams } from "./CrosscurrentAdapter.sol";
import { BridgePath } from "./SealedOFTConfig.sol";
import { BridgeBytecode } from "./BridgeBytecode.sol";
import { BridgeDeployer } from "./BridgeDeployer.sol";
import {
    FundedFillCoordinator,
    FundedAssetRegistration,
    ISealedBridgeAsset
} from "../FundedFillCoordinator.sol";

struct BridgeMesh {
    uint256 robinhoodChainId;
    uint256 arcChainId;
    address robinhoodFactory;
    address arcFactory;
    address robinhoodCoordinator;
    address arcCoordinator;
    bytes32 robinhoodPolicyHash;
    bytes32 arcPolicyHash;
    bytes32 solanaProgram;
    bytes32 solanaRegistrar;
    bytes32 solanaSettingsHash;
}

struct GlobalBridgePlan {
    bytes32 nonce;
    uint8 origin;
    address creator;
    bytes32 solanaCreator;
    bytes32 identityHash;
    bytes32 termsHash;
    uint256 globalSupply;
    uint256[3] inventories;
    uint256[3] allocations;
    bytes32[3] localTermsHashes;
    bytes32 solanaMint;
    bytes32 solanaStore;
    uint64 deadline;
}

/// The immutable authorizer attests remote initialization; local reads cannot prove it.
/// A compromised authorizer can approve an invalid new mesh, but cannot modify sealed assets.
contract CrosscurrentRegistrar is ReentrancyGuard {
    using MessageHashUtils for bytes32;

    struct Deployment {
        bytes32 planHash;
        address bridge;
        address token;
        bool registered;
    }

    bytes32 private constant PLAN_DOMAIN = keccak256("Crosscurrent.GlobalBridgePlan.v1");
    bytes32 private constant ASSET_DOMAIN = keccak256("Crosscurrent.GlobalAsset.v1");
    bytes32 private constant PREPARE_DOMAIN = keccak256("Crosscurrent.PrepareBridge.v1");
    bytes32 private constant CREATOR_DOMAIN = keccak256("Crosscurrent.CreatorBridge.v1");
    bytes32 private constant REGISTER_DOMAIN = keccak256("Crosscurrent.RegisterBridge.v1");
    bytes32 private constant ATTEMPT_DOMAIN = keccak256("Crosscurrent.BridgeAttempt.v1");

    BridgeMesh public mesh;
    bytes32 public immutable MESH_HASH;
    address public immutable AUTHORIZER;
    address public immutable ENDPOINT;
    uint8 public immutable LOCAL_INDEX;
    FundedFillCoordinator public immutable COORDINATOR;
    BridgePath[2] private _policy;
    mapping(bytes32 assetId => Deployment) public deployments;

    error InvalidMesh();
    error InvalidPlan();
    error InvalidSignature();
    error InvalidBytecode();
    error AlreadyDeployed();
    error InventoryNotReady();

    event BridgePrepared(
        bytes32 indexed assetId, bytes32 indexed planHash, address bridge, address token
    );
    event BridgeRegistered(bytes32 indexed assetId, bytes32 indexed planHash);

    constructor(BridgeMesh memory mesh_, BridgePath[2] memory policy, address authorizer) {
        bool mainnet = mesh_.robinhoodChainId == 4663 && mesh_.arcChainId == 5042;
        bool testnet = mesh_.robinhoodChainId == 46630 && mesh_.arcChainId == 5042002;
        if (
            (!mainnet && !testnet) || authorizer == address(0)
                || mesh_.robinhoodFactory == address(0) || mesh_.arcFactory == address(0)
                || mesh_.robinhoodCoordinator == address(0) || mesh_.arcCoordinator == address(0)
                || mesh_.solanaProgram == bytes32(0) || mesh_.solanaRegistrar == bytes32(0) || mesh_.solanaSettingsHash == bytes32(0)
        ) revert InvalidMesh();
        uint8 local;
        address coordinator;
        if (block.chainid == mesh_.robinhoodChainId && address(this) == mesh_.robinhoodFactory) {
            local = 0;
            coordinator = mesh_.robinhoodCoordinator;
        } else if (block.chainid == mesh_.arcChainId && address(this) == mesh_.arcFactory) {
            local = 1;
            coordinator = mesh_.arcCoordinator;
        } else {
            revert InvalidMesh();
        }
        bytes32 expectedPolicy = local == 0 ? mesh_.robinhoodPolicyHash : mesh_.arcPolicyHash;
        if (
            keccak256(abi.encode(policy)) != expectedPolicy || policy[0].peer != bytes32(0)
                || policy[1].peer != bytes32(0) || policy[0].eid != (mainnet ? 30168 : 40168)
                || policy[1].eid
                    != (local == 0 ? (mainnet ? 30417 : 40434) : (mainnet ? 30416 : 40451))
        ) revert InvalidMesh();
        mesh = mesh_;
        MESH_HASH = keccak256(abi.encode(mesh_, authorizer));
        AUTHORIZER = authorizer;
        ENDPOINT = mainnet
            ? 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B
            : local == 0
                ? 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32
                : 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff;
        LOCAL_INDEX = local;
        COORDINATOR = FundedFillCoordinator(coordinator);
        _policy[0] = policy[0];
        _policy[1] = policy[1];
    }

    function assetId(GlobalBridgePlan calldata plan) public view returns (bytes32) {
        return keccak256(abi.encode(ASSET_DOMAIN, MESH_HASH, plan.creator, plan.nonce));
    }

    function planHash(GlobalBridgePlan calldata plan) public view returns (bytes32) {
        return keccak256(abi.encode(PLAN_DOMAIN, MESH_HASH, plan));
    }

    function prepareDigest(GlobalBridgePlan calldata plan) public view returns (bytes32) {
        return
            keccak256(abi.encode(PREPARE_DOMAIN, MESH_HASH, planHash(plan)))
                .toEthSignedMessageHash();
    }

    function creatorDigest(GlobalBridgePlan calldata plan) public view returns (bytes32) {
        return keccak256(abi.encode(CREATOR_DOMAIN, block.chainid, address(this), planHash(plan)))
            .toEthSignedMessageHash();
    }

    function registrationDigest(GlobalBridgePlan calldata plan, uint64 validUntil)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(REGISTER_DOMAIN, MESH_HASH, planHash(plan), validUntil))
            .toEthSignedMessageHash();
    }

    function predict(address factory, bytes32 id) public pure returns (address) {
        address deployer = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), factory, id, keccak256(type(BridgeDeployer).creationCode)
                        )
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, hex"01")))));
    }

    function paths(GlobalBridgePlan calldata plan)
        public
        view
        returns (BridgePath[2] memory result)
    {
        result = _policy;
        result[0].peer = plan.solanaStore;
        result[1].peer = bytes32(
            uint256(
                uint160(
                    predict(
                        LOCAL_INDEX == 0 ? mesh.arcFactory : mesh.robinhoodFactory, assetId(plan)
                    )
                )
            )
        );
    }

    function prepare(
        GlobalBridgePlan calldata plan,
        CanonicalTokenParams calldata identity,
        bytes calldata creationCode,
        bytes calldata creatorSignature,
        bytes calldata authorizerSignature
    ) external nonReentrant returns (address bridge, address token) {
        _validate(plan, identity);
        bytes32 id = assetId(plan);
        if (deployments[id].bridge != address(0)) revert AlreadyDeployed();
        _signature(plan.creator, creatorDigest(plan), creatorSignature);
        _signature(AUTHORIZER, prepareDigest(plan), authorizerSignature);
        (bridge, token) = _deploy(plan, identity, creationCode, id);
        deployments[id] = Deployment(planHash(plan), bridge, token, false);
        emit BridgePrepared(id, planHash(plan), bridge, token);
    }

    function _deploy(
        GlobalBridgePlan calldata plan,
        CanonicalTokenParams calldata identity,
        bytes calldata creationCode,
        bytes32 id
    ) private returns (address bridge, address token) {
        bool canonical = plan.origin == LOCAL_INDEX;
        if (keccak256(creationCode) != (canonical ? BridgeBytecode.ADAPTER : BridgeBytecode.OFT)) {
            revert InvalidBytecode();
        }
        BridgePath[2] memory configured = paths(plan);
        bytes32 configHash = keccak256(abi.encode(block.chainid, ENDPOINT, configured));
        bytes memory args = _arguments(plan, identity, id, configHash);
        BridgeDeployer deployer = new BridgeDeployer{ salt: id }();
        bridge = deployer.deploy(bytes.concat(creationCode, args), configured);
        if (bridge != predict(address(this), id)) revert InvalidPlan();
        token = ISealedBridgeAsset(bridge).token();
        if (IERC20(token).totalSupply() != (canonical ? plan.globalSupply : 0)) {
            revert InvalidPlan();
        }
        if (canonical && IERC20(token).balanceOf(plan.creator) != plan.globalSupply) {
            revert InvalidPlan();
        }
    }

    function _arguments(
        GlobalBridgePlan calldata plan,
        CanonicalTokenParams calldata identity,
        bytes32 id,
        bytes32 configHash
    ) private view returns (bytes memory) {
        if (plan.origin == LOCAL_INDEX) {
            return abi.encode(identity, ENDPOINT, configHash, id);
        }
        return
            abi.encode(identity.name, identity.symbol, ENDPOINT, configHash, id, plan.globalSupply);
    }

    function register(GlobalBridgePlan calldata plan, uint64 validUntil, bytes calldata attestation)
        external
        nonReentrant
    {
        bytes32 id = assetId(plan);
        Deployment storage deployed = deployments[id];
        if (
            deployed.planHash != planHash(plan) || deployed.bridge == address(0)
                || deployed.registered
        ) {
            revert InvalidPlan();
        }
        if (validUntil < block.timestamp) revert InvalidPlan();
        _signature(AUTHORIZER, registrationDigest(plan, validUntil), attestation);
        uint256 inventory = plan.inventories[LOCAL_INDEX];
        if (IERC20(deployed.token).balanceOf(plan.creator) != inventory) {
            revert InventoryNotReady();
        }
        if (plan.origin == LOCAL_INDEX) {
            if (IERC20(deployed.token).balanceOf(deployed.bridge) != plan.globalSupply - inventory)
            {
                revert InventoryNotReady();
            }
        } else if (IERC20(deployed.token).totalSupply() != inventory) {
            revert InventoryNotReady();
        }
        if (COORDINATOR.REGISTRAR() != address(this)) revert InvalidMesh();
        deployed.registered = true;
        COORDINATOR.registerAsset(
            FundedAssetRegistration({
                assetId: id,
                globalPlanHash: deployed.planHash,
                localTermsHash: plan.localTermsHashes[LOCAL_INDEX],
                bridgeConfigHash: ISealedBridgeAsset(deployed.bridge).CONFIG_HASH(),
                bridge: deployed.bridge,
                token: deployed.token,
                creator: plan.creator,
                globalSupply: plan.globalSupply,
                inventory: inventory,
                allocation: plan.allocations[LOCAL_INDEX]
            })
        );
        emit BridgeRegistered(id, deployed.planHash);
    }

    function attemptDigest(bytes32 id, bytes32 localTermsHash, uint64 validUntil)
        public
        view
        returns (bytes32)
    {
        return keccak256(
                abi.encode(
                    ATTEMPT_DOMAIN,
                    MESH_HASH,
                    block.chainid,
                    address(this),
                    id,
                    deployments[id].planHash,
                    localTermsHash,
                    validUntil
                )
            )
            .toEthSignedMessageHash();
    }

    function authorizeAttempt(
        GlobalBridgePlan calldata plan,
        bytes32 localTermsHash,
        uint64 validUntil,
        bytes calldata creatorSignature,
        bytes calldata attestation
    ) external nonReentrant {
        bytes32 id = assetId(plan);
        Deployment memory deployed = deployments[id];
        if (
            !deployed.registered || deployed.planHash != planHash(plan)
                || localTermsHash == bytes32(0) || validUntil < block.timestamp
        ) revert InvalidPlan();
        bytes32 digest = attemptDigest(id, localTermsHash, validUntil);
        _signature(plan.creator, digest, creatorSignature);
        _signature(AUTHORIZER, digest, attestation);
        COORDINATOR.authorizeAttempt(id, localTermsHash);
    }

    function _validate(GlobalBridgePlan calldata plan, CanonicalTokenParams calldata identity)
        private
        view
    {
        if (
            plan.nonce == bytes32(0) || plan.origin > 1 || plan.creator == address(0)
                || plan.solanaCreator == bytes32(0) || plan.solanaMint == bytes32(0)
                || plan.solanaStore == bytes32(0) || plan.termsHash == bytes32(0)
                || plan.globalSupply == 0 || plan.globalSupply > uint256(type(uint64).max) * 1e9
                || plan.globalSupply % 1e12 != 0 || plan.deadline < block.timestamp
                || identity.holder != plan.creator || identity.supply != plan.globalSupply
                || keccak256(abi.encode(identity)) != plan.identityHash
                || bytes(identity.name).length == 0 || bytes(identity.name).length > 32
                || bytes(identity.symbol).length == 0 || bytes(identity.symbol).length > 10
        ) revert InvalidPlan();
        uint256 sum;
        uint256 reserved;
        uint256 collections;
        for (uint256 i; i < 3; ++i) {
            if (
                plan.inventories[i] == 0 || plan.inventories[i] % 1e12 != 0
                    || plan.allocations[i] >= plan.inventories[i] || plan.allocations[i] % 1e12 != 0
                    || plan.localTermsHashes[i] == bytes32(0)
            ) revert InvalidPlan();
            sum += plan.inventories[i];
            reserved += plan.allocations[i];
            if (plan.allocations[i] != 0) ++collections;
        }
        if (
            sum != plan.globalSupply || reserved > plan.globalSupply / 20 || collections != 1
                || plan.allocations[plan.origin] == 0
        ) {
            revert InvalidPlan();
        }
    }

    function _signature(address signer, bytes32 digest, bytes calldata signature) private view {
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) {
            revert InvalidSignature();
        }
    }
}
