// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { LaunchHook } from "../src/hook/LaunchHook.sol";
import { CollectionDeployer } from "../src/libraries/CollectionDeployer.sol";
import { PoolDeployer } from "../src/libraries/PoolDeployer.sol";
import { TokenDeployer } from "../src/libraries/TokenDeployer.sol";
import { VestingDeployer } from "../src/libraries/VestingDeployer.sol";

/// Replace the token rail's factory in place, leaving everything under it alone.
///
/// `Deploy.s.sol` builds a network from nothing: both factories, the hook, the quote registry,
/// the allowlist. This does one thing, which is what a factory-only change needs: a new
/// `TokenLaunchFactory` and the `TokenDeployer` library it links, wired to the **existing**
/// singleton hook, the **existing** quote registry, and the same settlement asset, treasury and
/// platform signer the live factory carries. The NFT factory, the hook, the registry, the lens
/// and every launch already open are untouched.
///
/// Every input except the hook and the registry is read off the live factory rather than typed
/// or taken from the record, so the replacement is like for like by construction: a stale
/// deployments.json cannot move the treasury, the fee, the asset origin or the settlement
/// asset. The record supplies exactly one address, the factory being replaced, and the run
/// prints every value it resolved before it sends anything.
///
///   Environment:
///     LAUNCH_HOOK            the singleton hook to key the new factory to. Defaults to the one
///                            the live factory is keyed to, which is what a rail keeps.
///     QUOTE_REGISTRY         the shared quote registry. Defaults to the live factory's.
///     FACTORY_OWNER          who the two-step handoff is opened to. Defaults to the live
///                            factory's `pendingOwner()` when a handoff is already outstanding,
///                            otherwise its `owner()`.
///     TOKEN_LAUNCH_FACTORY   the factory being replaced. Defaults to the network's record.
///     TREASURY               overrides the live treasury. Rarely wanted.
///     PLATFORM_SIGNER        overrides the live platform signer. Rarely wanted.
///     TOKEN_LAUNCH_FEE       overrides the live launch fee.
///     ALLOW_MAINNET_DEPLOY   must be true to broadcast on chain 4663.
///     WRITE_DEPLOYMENTS      false to broadcast without touching the record.
///     SOURCE_COMMIT          recorded beside the new address.
///     GAS_PRICE_WEI          priced into the estimate this run prints.
///
/// The four libraries below the factory are unchanged apart from `TokenDeployer`, and a run that
/// lets forge deploy fresh copies of the other three writes their new addresses into the record,
/// which is where `LaunchpadFactory` verification reads the `CollectionDeployer` it was linked
/// against. Pin the three that did not change with `--libraries` and only `TokenDeployer` moves.
/// The runbook command does this; the record always states what this run actually linked.
contract DeployTokenFactory is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    /// A v4 hook's permissions are the low 14 bits of its own address, and the PoolManager
    /// refuses a pool keyed to anything else. Checked here because a factory keyed to a wrong
    /// hook fails at the first launch rather than at deployment.
    uint160 internal constant LAUNCH_HOOK_FLAGS = 0x2AC4;
    uint160 private constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    /// The creator's share of the fees their market earns. A constant of the factory rather than
    /// a setting, and read back after deployment so a change to it cannot ship unannounced.
    uint96 internal constant LP_FEE_CREATOR_BPS = 7_000;

    error MainnetNotAuthorized();
    error PreviousFactoryRequired();
    error NoCodeAt(address target);
    error HookAddressInvalid(address hook);
    error HookNotWired();
    error HookPoolManagerMismatch(address hook);
    error LaunchpadNotAdmitted();
    error QuoteRegistryNotWired();
    error CreatorShareChanged(uint96 bps);
    error DeploymentAddressRequired(string variableName);

    /// Whether the new factory may create a launch. A run against a hook it does not own cannot
    /// admit itself and says so in the record rather than pretending.
    bool internal launchpadAdmitted;

    struct Rail {
        address previous;
        address weth;
        address poolManager;
        address treasury;
        address platformSigner;
        address hook;
        address quoteRegistry;
        address owner;
        address broadcaster;
        string assetOrigin;
        uint256 launchFee;
        uint96 nftProtocolFeeBps;
        address feePassCollection;
    }

    function run() external returns (TokenLaunchFactory tokenFactory) {
        Rail memory r = _resolve();

        if (block.chainid == RH_MAINNET && !vm.envOr("ALLOW_MAINNET_DEPLOY", false)) {
            revert MainnetNotAuthorized();
        }

        _describe(r);

        uint256 gasBefore = gasleft();
        vm.startBroadcast();

        tokenFactory = new TokenLaunchFactory(
            r.weth, r.poolManager, r.treasury, r.platformSigner, r.broadcaster
        );

        // Set before the ownership handoff, in the same order Deploy.s.sol sets them: a
        // collection reads the origin at creation, so a factory that launches without one
        // publishes drops with no collection document.
        if (bytes(r.assetOrigin).length != 0) tokenFactory.setAssetOrigin(r.assetOrigin);
        tokenFactory.setLaunchHook(r.hook);
        // The hook is a singleton that outlives every factory keyed to it, so admitting this one
        // is an entry in its mapping. Its owner is still the deployer while the Safe handoff is
        // outstanding, which is the window this run uses.
        if (LaunchHook(r.hook).owner() == r.broadcaster) {
            LaunchHook(r.hook).setLaunchpad(address(tokenFactory), true);
        }
        tokenFactory.setQuoteRegistry(r.quoteRegistry);
        if (r.launchFee != tokenFactory.launchFee()) tokenFactory.setLaunchFee(r.launchFee);
        if (r.nftProtocolFeeBps != tokenFactory.nftProtocolFeeBps()) {
            tokenFactory.setNftProtocolFeeBps(r.nftProtocolFeeBps);
        }
        if (r.feePassCollection != address(0)) {
            tokenFactory.setFeePassCollection(r.feePassCollection);
        }

        // The two-step handoff, opened last. The broadcaster holds the factory only long enough
        // to finish the wiring above.
        if (r.owner != r.broadcaster) tokenFactory.transferOwnership(r.owner);

        vm.stopBroadcast();
        uint256 gasUsed = gasBefore - gasleft();

        _check(tokenFactory, r);
        _estimate(gasUsed, r.broadcaster);
        _record(tokenFactory, r);
    }

    /// Every input, resolved and stated. The live factory is the source for all of it except the
    /// hook and the registry, which a redeploy may legitimately repoint.
    function _resolve() private view returns (Rail memory r) {
        r.broadcaster = tx.origin;

        r.previous = vm.envOr("TOKEN_LAUNCH_FACTORY", address(0));
        if (r.previous == address(0)) r.previous = _recordedAddress("tokenLaunchFactory");
        if (r.previous == address(0)) revert PreviousFactoryRequired();
        if (r.previous.code.length == 0) revert NoCodeAt(r.previous);

        TokenLaunchFactory live = TokenLaunchFactory(r.previous);
        r.weth = live.feeToken();
        r.poolManager = address(live.POOL_MANAGER());
        r.treasury = vm.envOr("TREASURY", live.treasury());
        r.platformSigner = vm.envOr("PLATFORM_SIGNER", live.platformSigner());
        r.assetOrigin = live.assetOrigin();
        r.launchFee = vm.envOr("TOKEN_LAUNCH_FEE", live.launchFee());
        r.nftProtocolFeeBps = live.nftProtocolFeeBps();
        r.feePassCollection = live.feePassCollection();

        r.hook = vm.envOr("LAUNCH_HOOK", live.launchHook());
        r.quoteRegistry = vm.envOr("QUOTE_REGISTRY", live.quoteRegistry());

        // The owner the live rail is on its way to, so the replacement lands in the same hands.
        // An outstanding handoff means the Safe has not accepted yet, and the new factory has to
        // be offered to the Safe rather than to the deployer holding it in the meantime.
        address pending = live.pendingOwner();
        r.owner = vm.envOr("FACTORY_OWNER", pending == address(0) ? live.owner() : pending);

        if (r.treasury == address(0)) revert DeploymentAddressRequired("TREASURY");
        if (r.platformSigner == address(0)) revert DeploymentAddressRequired("PLATFORM_SIGNER");
        if (r.owner == address(0)) revert DeploymentAddressRequired("FACTORY_OWNER");
        if (r.quoteRegistry == address(0)) revert DeploymentAddressRequired("QUOTE_REGISTRY");
        if (r.hook == address(0)) revert DeploymentAddressRequired("LAUNCH_HOOK");
        if (r.weth.code.length == 0) revert NoCodeAt(r.weth);
        if (r.poolManager.code.length == 0) revert NoCodeAt(r.poolManager);
        if (r.hook.code.length == 0) revert NoCodeAt(r.hook);
        if (r.quoteRegistry.code.length == 0) revert NoCodeAt(r.quoteRegistry);
        if (uint160(r.hook) & HOOK_FLAG_MASK != LAUNCH_HOOK_FLAGS) {
            revert HookAddressInvalid(r.hook);
        }
        // A hook keyed to a different PoolManager would open every pool somewhere the rest of
        // the rail cannot see.
        if (address(LaunchHook(r.hook).POOL_MANAGER()) != r.poolManager) {
            revert HookPoolManagerMismatch(r.hook);
        }
    }

    function _describe(Rail memory r) private pure {
        console2.log("replacing token launch factory", r.previous);
        console2.log("  settles in          ", r.weth);
        console2.log("  pool manager        ", r.poolManager);
        console2.log("  launch hook         ", r.hook);
        console2.log("  quote registry      ", r.quoteRegistry);
        console2.log("  treasury            ", r.treasury);
        console2.log("  platform signer     ", r.platformSigner);
        console2.log("  asset origin        ", r.assetOrigin);
        console2.log("  launch fee (wei)    ", r.launchFee);
        console2.log("  nft protocol fee bps", r.nftProtocolFeeBps);
        console2.log("  fee pass collection ", r.feePassCollection);
        console2.log("  ownership offered to", r.owner);
    }

    /// No launch is possible unless these hold, and each of them fails silently at the first
    /// launch rather than at deployment, so each is read back here.
    function _check(TokenLaunchFactory tokenFactory, Rail memory r) private {
        if (tokenFactory.launchHook() != r.hook) revert HookNotWired();
        if (tokenFactory.quoteRegistry() != r.quoteRegistry) revert QuoteRegistryNotWired();
        if (tokenFactory.LP_FEE_CREATOR_BPS() != LP_FEE_CREATOR_BPS) {
            revert CreatorShareChanged(tokenFactory.LP_FEE_CREATOR_BPS());
        }
        launchpadAdmitted = LaunchHook(r.hook).allowedLaunchpad(address(tokenFactory));
        // Only a run that owns the hook could have admitted the factory, and it did it above, so
        // a gap here would be this script's bug. A run against a hook someone else owns has no
        // way to admit anything and must still write its record: reverting would abort the
        // simulation, broadcast nothing, and leave the operator with no address at all.
        if (!launchpadAdmitted && LaunchHook(r.hook).owner() == r.broadcaster) {
            revert LaunchpadNotAdmitted();
        }
    }

    /// What the run costs, beside what the broadcaster holds. The gas is measured through the
    /// simulation of the same calls that broadcast, so it is the run's own figure rather than a
    /// typed one; the price is the operator's, because a script cannot read the next block's.
    function _estimate(uint256 gasUsed, address broadcaster) private view {
        uint256 price = vm.envOr("GAS_PRICE_WEI", tx.gasprice);
        console2.log("estimated gas       ", gasUsed);
        if (price != 0) {
            console2.log("at gas price (wei)  ", price);
            console2.log("estimated cost (wei)", gasUsed * price);
        }
        console2.log("broadcaster         ", broadcaster);
        console2.log("balance (wei)       ", broadcaster.balance);
    }

    /// The record, keyed field by field rather than as a whole network entry: this run replaces
    /// one contract, and rewriting the entry would erase every address it did not deploy.
    function _record(TokenLaunchFactory tokenFactory, Rail memory r) private {
        console2.log("tokenLaunchFactory  ", address(tokenFactory));
        console2.log("TokenDeployer       ", address(TokenDeployer));
        console2.log("launchpadAdmitted   ", launchpadAdmitted);
        if (!launchpadAdmitted) {
            console2.log("LAUNCHPAD NOT YET ADMITTED. No launch can be created until this is sent:");
            console2.log(
                string.concat(
                    "setLaunchpad(address,bool) on LaunchHook ",
                    vm.toString(r.hook),
                    " with (",
                    vm.toString(address(tokenFactory)),
                    ", true), sent by its owner ",
                    vm.toString(LaunchHook(r.hook).owner())
                )
            );
        }
        console2.log("ACCEPT OWNERSHIP: acceptOwnership() on the new factory, sent by", r.owner);

        string memory network = _networkKey();
        if (bytes(network).length == 0 || !_writesDeployments()) return;

        // The factory being replaced goes on the end of the legacy list before the live key
        // moves. Every launch it created is still on chain and still keyed to the same hook, so
        // its address stays discoverable: verify.sh walks it, and a reader looking up an older
        // launch has nowhere else to find the factory that made it.
        vm.writeJson(
            _appendLegacy(network, r.previous),
            "./deployments.json",
            string.concat(".", network, ".legacyTokenLaunchFactories")
        );
        vm.writeJson(
            vm.toString(address(tokenFactory)),
            "./deployments.json",
            string.concat(".", network, ".tokenLaunchFactory")
        );
        // The linked libraries are part of the factory's creation code, so verification has to
        // recompile against exactly these. Written for all four because a run that did not pin
        // the unchanged three deployed fresh copies of them, and the record has to say which.
        vm.writeJson(
            _libraryRecord(), "./deployments.json", string.concat(".", network, ".libraries")
        );
        string memory sourceCommit = vm.envOr("SOURCE_COMMIT", string(""));
        if (bytes(sourceCommit).length != 0) {
            vm.writeJson(
                string.concat("\"", sourceCommit, "\""),
                "./deployments.json",
                string.concat(".", network, ".sourceCommit")
            );
        }
    }

    /// The network's existing legacy list with `previous` on the end, as a JSON array. Built by
    /// hand because forge's serializer returns an object around its arrays, and this key holds
    /// the bare list.
    function _appendLegacy(string memory network, address previous)
        private
        view
        returns (string memory)
    {
        string memory record = vm.readFile("./deployments.json");
        string memory key = string.concat(".", network, ".legacyTokenLaunchFactories");
        string memory out = "[";
        if (vm.keyExistsJson(record, key)) {
            address[] memory existing = vm.parseJsonAddressArray(record, key);
            for (uint256 i = 0; i < existing.length; i++) {
                // Re-running a deploy after a failed record write would otherwise list the same
                // factory twice.
                if (existing[i] == previous) continue;
                out = string.concat(out, "\"", vm.toString(existing[i]), "\",");
            }
        }
        return string.concat(out, "\"", vm.toString(previous), "\"]");
    }

    /// The four libraries `TokenLaunchFactory` links. `LockerDeployer` is linked into
    /// `PoolDeployer` rather than into the factory, so this run neither deploys nor moves it and
    /// the record's entry for it stands.
    function _libraryRecord() private returns (string memory) {
        string memory libs = string.concat("libraries:", vm.toString(vm.randomUint()));
        vm.serializeAddress(libs, "CollectionDeployer", address(CollectionDeployer));
        vm.serializeAddress(libs, "PoolDeployer", address(PoolDeployer));
        vm.serializeAddress(libs, "TokenDeployer", address(TokenDeployer));
        string memory body = vm.serializeAddress(libs, "VestingDeployer", address(VestingDeployer));
        // The record's `LockerDeployer` is not this run's to move, and a write to `.libraries`
        // replaces the whole object, so it is carried across.
        string memory record = vm.readFile("./deployments.json");
        string memory key = string.concat(".", _networkKey(), ".libraries.LockerDeployer");
        if (!vm.keyExistsJson(record, key)) return body;
        return vm.serializeAddress(libs, "LockerDeployer", vm.parseJsonAddress(record, key));
    }

    function _recordedAddress(string memory field) private view returns (address) {
        string memory network = _networkKey();
        if (bytes(network).length == 0) return address(0);
        string memory record = vm.readFile("./deployments.json");
        string memory key = string.concat(".", network, ".", field);
        if (!vm.keyExistsJson(record, key)) return address(0);
        return vm.parseJsonAddress(record, key);
    }

    /// True when this run will edit deployments.json. A dry run, a fork rehearsal or a test
    /// prints its addresses and stops.
    function _writesDeployments() private view returns (bool) {
        return
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    function _networkKey() private view returns (string memory) {
        if (block.chainid == RH_MAINNET) return "robinhoodMainnet";
        if (block.chainid == RH_TESTNET) return "robinhoodTestnet";
        return "";
    }
}
