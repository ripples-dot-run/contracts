// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { HolderDistributorFactory } from "../src/HolderDistributorFactory.sol";

interface IHolderLaunchFactory {
    function launchHook() external view returns (address);
}

interface IHolderLaunchHook {
    function POOL_MANAGER() external view returns (address);
}

/// Deploys only the holder factory. Existing creator recipients and deployment records are untouched.
/// Run preflight() without a signer to verify the reviewed bindings and constructor initcode hash.
///
/// The token factory, the hook and the pool manager come from the network's own record unless an
/// override names them: Robinhood Chain's two networks share `deployments.json` under an entry
/// each, and Arc's have a file each under `deployments/`. The publisher is the address the
/// network's own publisher key derives to. On Arc that is `HOLDER_REWARDS_ARC_PUBLISHER_KEY`'s,
/// never the Robinhood publisher's: a key that signs on two chains is one compromise away from
/// assigning both chains' income, so an Arc deploy refuses the address Robinhood Chain's record
/// names.
contract DeployHolderRewards is Script {
    struct Settings {
        address tokenFactory;
        address hook;
        address poolManager;
        address publisher;
        uint256 finalityDelay;
        bytes32 tokenFactoryCodehash;
        bytes32 hookCodehash;
        bytes32 initcodeHash;
    }

    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    uint256 internal constant ARC_MAINNET = 5042;
    uint256 internal constant ARC_TESTNET = 5042002;
    string internal constant DEPLOYMENTS = "./deployments.json";
    string internal constant ARC_MAINNET_RECORD = "./deployments/arc-mainnet.json";
    string internal constant ARC_TESTNET_RECORD = "./deployments/arc-testnet.json";

    error UnsupportedChain(uint256 chainId);
    error MainnetNotAuthorized();
    error InvalidPublisher();
    /// The publisher is the one Robinhood Chain's record already names for its own factory.
    error PublisherIsShared(address publisher);
    error InvalidFinalityDelay();
    error NoCodeAt(address target);
    error CodehashMismatch(address target);
    error HookMismatch();
    error PoolManagerMismatch();

    function preflight() public view returns (Settings memory c) {
        (string memory file, string memory entry) = recordFor(block.chainid);
        c.tokenFactory = _address("HOLDER_REWARDS_TOKEN_FACTORY", file, entry, "tokenLaunchFactory");
        c.hook = _address("HOLDER_REWARDS_HOOK", file, entry, "launchHook");
        c.poolManager = _address("HOLDER_REWARDS_POOL_MANAGER", file, entry, "poolManager");
        c.publisher = vm.envAddress("HOLDER_REWARDS_PUBLISHER");
        c.finalityDelay = vm.envUint("HOLDER_REWARDS_FINALITY_DELAY");
        c.tokenFactoryCodehash = vm.envBytes32("HOLDER_REWARDS_EXPECTED_TOKEN_FACTORY_CODEHASH");
        c.hookCodehash = vm.envBytes32("HOLDER_REWARDS_EXPECTED_HOOK_CODEHASH");
        if (isArc(block.chainid)) {
            guardPublisherIsNotShared(vm.readFile(DEPLOYMENTS), c.publisher);
            guardPublisherIsNotTheOtherArcs(block.chainid, c.publisher);
        }
        return _validate(c);
    }

    /// @notice The record a chain's addresses are read from, and the entry inside it. Robinhood
    ///         Chain's networks share one file under an entry each; Arc's have a file each and no
    ///         entry, so every path there is one segment.
    function recordFor(uint256 chainId)
        public
        pure
        returns (string memory file, string memory entry)
    {
        if (chainId == RH_MAINNET) return (DEPLOYMENTS, "robinhoodMainnet");
        if (chainId == RH_TESTNET) return (DEPLOYMENTS, "robinhoodTestnet");
        if (chainId == ARC_MAINNET) return (ARC_MAINNET_RECORD, "");
        if (chainId == ARC_TESTNET) return (ARC_TESTNET_RECORD, "");
        revert UnsupportedChain(chainId);
    }

    function isArc(uint256 chainId) public pure returns (bool) {
        return chainId == ARC_MAINNET || chainId == ARC_TESTNET;
    }

    /// @notice Whether a broadcast on this chain moves real money, and so needs the explicit
    ///         `ALLOW_MAINNET_DEPLOY=true` beside the signer.
    function isMainnet(uint256 chainId) public pure returns (bool) {
        return chainId == RH_MAINNET || chainId == ARC_MAINNET;
    }

    /// @notice An Arc publisher has to be Arc's own. Both Robinhood Chain entries are checked,
    ///         because a key that was ever a publisher there is one whose loss or compromise
    ///         already halts or misdirects one chain's dividends.
    function guardPublisherIsNotShared(string memory record, address publisher) public view {
        string[2] memory entries = ["robinhoodMainnet", "robinhoodTestnet"];
        for (uint256 i = 0; i < entries.length; i++) {
            string memory path = string.concat(".", entries[i], ".holderRewardsPublisher");
            if (!vm.keyExistsJson(record, path)) continue;
            if (vm.parseJsonAddress(record, path) == publisher) {
                revert PublisherIsShared(publisher);
            }
        }
    }

    /// @notice The other Arc network's publisher is refused too: one key publishing dividends on
    ///         the test network and on mainnet makes a test-network leak a mainnet loss.
    function guardPublisherIsNotTheOtherArcs(uint256 chainId, address publisher) public view {
        string memory other = chainId == ARC_MAINNET ? ARC_TESTNET_RECORD : ARC_MAINNET_RECORD;
        if (!vm.exists(other)) return;
        string memory record = vm.readFile(other);
        if (!vm.keyExistsJson(record, ".holderRewardsPublisher")) return;
        if (vm.parseJsonAddress(record, ".holderRewardsPublisher") == publisher) {
            revert PublisherIsShared(publisher);
        }
    }

    /// @notice What the record names for a field, without the environment override: what the
    ///         script would deploy against when nothing overrides it.
    function recorded(uint256 chainId, string memory field) public view returns (address) {
        (string memory file, string memory entry) = recordFor(chainId);
        return _recorded(file, entry, field);
    }

    function _validate(Settings memory c) internal view returns (Settings memory) {
        // The automatic publisher signs locally. A contract recipient would require a different worker.
        if (c.publisher == address(0) || c.publisher.code.length != 0) revert InvalidPublisher();
        if (c.finalityDelay == 0 || c.finalityDelay > type(uint64).max) {
            revert InvalidFinalityDelay();
        }
        for (uint256 i; i < 3; ++i) {
            address target = i == 0 ? c.tokenFactory : i == 1 ? c.hook : c.poolManager;
            if (target.code.length == 0) revert NoCodeAt(target);
        }
        if (c.tokenFactoryCodehash != c.tokenFactory.codehash) {
            revert CodehashMismatch(c.tokenFactory);
        }
        if (c.hookCodehash != c.hook.codehash) {
            revert CodehashMismatch(c.hook);
        }
        if (IHolderLaunchFactory(c.tokenFactory).launchHook() != c.hook) revert HookMismatch();
        if (IHolderLaunchHook(c.hook).POOL_MANAGER() != c.poolManager) {
            revert PoolManagerMismatch();
        }
        c.initcodeHash = keccak256(
            abi.encodePacked(
                type(HolderDistributorFactory).creationCode,
                abi.encode(c.hook, c.publisher, uint64(c.finalityDelay))
            )
        );
        return c;
    }

    function run() external returns (HolderDistributorFactory factory) {
        Settings memory c = preflight();
        if (
            isMainnet(block.chainid) && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.envOr("ALLOW_MAINNET_DEPLOY", false)
        ) revert MainnetNotAuthorized();

        vm.startBroadcast();
        factory =
            new HolderDistributorFactory(ILaunchHook(c.hook), c.publisher, uint64(c.finalityDelay));
        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("holderRewardsFactory", address(factory));
        console2.log("hook", address(factory.HOOK()));
        console2.log("publisher", factory.PUBLISHER());
        console2.log("finalityDelay", factory.FINALITY_DELAY());
        console2.log("factoryInitcodeHash");
        console2.logBytes32(c.initcodeHash);
        console2.log("factoryRuntimeCodehash");
        console2.logBytes32(address(factory).codehash);
    }

    function _address(
        string memory variable,
        string memory file,
        string memory entry,
        string memory field
    ) private view returns (address value) {
        value = vm.envOr(variable, address(0));
        if (value == address(0)) value = _recorded(file, entry, field);
    }

    function _recorded(string memory file, string memory entry, string memory field)
        private
        view
        returns (address)
    {
        string memory path = bytes(entry).length == 0
            ? string.concat(".", field)
            : string.concat(".", entry, ".", field);
        return vm.parseJsonAddress(vm.readFile(file), path);
    }
}
