// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { HookMiner, Create2Deployer } from "./Deploy.s.sol";
import { LaunchpadFactory } from "../src/LaunchpadFactory.sol";
import { TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";
import { LaunchHook } from "../src/hook/LaunchHook.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { LaunchLens } from "../src/LaunchLens.sol";
import { LaunchRouter } from "../src/LaunchRouter.sol";
import { IAllowanceTransfer } from "../src/interfaces/IAllowanceTransfer.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

interface IArcUSDC {
    function decimals() external view returns (uint8);
    function paused() external view returns (bool);
}

contract DeployArc is Script {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    /// The canonical CREATE2 proxy, at the same address on every chain that carries it. Mining
    /// against it instead of a deployer this run creates makes the hook's address a function of
    /// its creation code and salt alone, so an unchanged rerun lands on the hook already there
    /// rather than standing up a second one beside it.
    address internal constant CANONICAL_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// `LaunchHook`'s permission bitmap. A v4 hook's permissions are the low 14 bits of its own
    /// address, so this is what the address is mined for and what the PoolManager checks on
    /// every pool keyed to it.
    uint160 internal constant LAUNCH_HOOK_FLAGS = 0x2AC4;
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    string public constant HOOK_OVERRIDE_HINT =
        "Arc already has a hook: reuse it with ARC_LAUNCH_HOOK, or set ARC_ALLOW_NEW_LAUNCH_HOOK=true to mine another";

    address private manager;
    address private treasury;
    address private signer;
    address private owner;
    address private deployer;
    string private origin;
    string private revision;
    LaunchpadFactory private collectionFactory;
    TokenLaunchFactory private tokenFactory;
    QuoteRegistry private registry;
    LaunchHook private hook;
    LaunchLens private lens;
    LaunchRouter private router;
    address private create2Deployer;
    bytes32 private hookSalt;
    /// True when this run could admit the token factory on the hook. A reused hook already owned
    /// by the final owner cannot be wired here, and saying so is better than reverting.
    bool private launchpadAdmitted;

    /// What differs between the two Arc networks: where the committed record lives, where a run
    /// stages its own, and the row the registry opens with.
    ///
    /// A run reads the hook out of its own network's record, so a mainnet deploy cannot be
    /// stopped by the test network's hook or overwrite the record that says where the live one
    /// is. It writes to the staging path, never the record: `run()` executes once in simulation
    /// before anything is broadcast, so a redeploy that then hangs or reverts on chain would
    /// otherwise have replaced the only file naming the live rail with addresses that do not
    /// exist. `ops/arc/deploy.sh` moves the staged file into place after the broadcast succeeds.
    ///
    /// The row is sized per network; `ops/arc/network.mjs` carries the same figures with the
    /// reasoning, and the verifier reads the live row off the chain.
    struct Network {
        string recordPath;
        string stagingPath;
        IQuoteRegistry.QuoteEconomics row;
    }

    function _network() private view returns (Network memory) {
        if (block.chainid == 5042) {
            return Network({
                recordPath: "./deployments/arc-mainnet.json",
                stagingPath: "./deployments/arc-mainnet.pending.json",
                row: IQuoteRegistry.QuoteEconomics({
                    phantomQuote: 12_500_000_000,
                    graduationThreshold: 10_000_000_000,
                    decimals: 6,
                    minPriceQuote: 2_400_000,
                    standalonePhantomQuote: 4_000_000_000
                })
            });
        }
        if (block.chainid == 5042002) {
            return Network({
                recordPath: "./deployments/arc-testnet.json",
                stagingPath: "./deployments/arc-testnet.pending.json",
                row: IQuoteRegistry.QuoteEconomics({
                    phantomQuote: 156_250_000,
                    graduationThreshold: 125_000_000,
                    decimals: 6,
                    minPriceQuote: 1_000,
                    standalonePhantomQuote: 50_000_000
                })
            });
        }
        revert("not an Arc network");
    }

    function run() external {
        Network memory network = _network();
        manager = vm.envAddress("ARC_POOL_MANAGER");
        treasury = vm.envAddress("ARC_TREASURY");
        signer = vm.envAddress("ARC_REVEAL_SIGNER");
        owner = vm.envAddress("ARC_FACTORY_OWNER");
        origin = vm.envString("ARC_ASSET_ORIGIN");
        revision = vm.envString("SOURCE_COMMIT");
        require(bytes(revision).length == 40, "source revision required");
        require(
            manager.code.length > 0 && PERMIT2.code.length > 0 && MULTICALL3.code.length > 0,
            "infrastructure missing"
        );
        // The manager is wired immutably into four contracts, and a wrong one is only fixable by
        // redeploying all of them. Code at the address is not evidence it is a PoolManager, so
        // read something only a PoolManager answers before anything is built against it.
        IPoolManager(manager).extsload(bytes32(0));
        require(IArcUSDC(USDC).decimals() == 6 && !IArcUSDC(USDC).paused(), "USDC unavailable");
        // Whether the deployer or the treasury is blocked is checked by the deploy script with
        // `cast`, not here. Arc routes `isBlacklisted` to a chain precompile, and a Solidity
        // script runs in the local EVM before it broadcasts anything, where that precompile does
        // not exist. Asking for it here makes the deployment impossible to run at all.
        require(owner != address(0) && signer != address(0), "missing owner or signer");

        vm.startBroadcast();
        deployer = tx.origin;
        collectionFactory = new LaunchpadFactory(USDC, treasury, signer, deployer);
        tokenFactory = new TokenLaunchFactory(USDC, manager, treasury, signer, deployer);
        registry = new QuoteRegistry(USDC, USDC, deployer);
        registry.approveQuote(USDC, network.row);
        collectionFactory.setLaunchFee(100_000);
        tokenFactory.setLaunchFee(100_000);
        collectionFactory.setQuoteRegistry(address(registry));
        tokenFactory.setQuoteRegistry(address(registry));
        collectionFactory.setAssetOrigin(origin);
        tokenFactory.setAssetOrigin(origin);

        hook = _resolveHook();
        tokenFactory.setLaunchHook(address(hook));
        // `setLaunchpad` is owner-only. A hook reused from an earlier deployment already belongs
        // to the final owner, and a run that cannot send this call records what the owner still
        // owes rather than reverting a deployment that is otherwise complete.
        launchpadAdmitted = hook.owner() == deployer;
        if (launchpadAdmitted) hook.setLaunchpad(address(tokenFactory), true);
        lens = new LaunchLens(ILaunchHook(address(hook)));
        router = new LaunchRouter(
            IPoolManager(manager), ILaunchHook(address(hook)), IAllowanceTransfer(PERMIT2)
        );
        if (owner != deployer) {
            collectionFactory.transferOwnership(owner);
            tokenFactory.transferOwnership(owner);
            registry.transferOwnership(owner);
            if (hook.owner() == deployer) hook.transferOwnership(owner);
        }
        vm.stopBroadcast();

        require(
            uint160(address(hook)) & HOOK_FLAG_MASK == LAUNCH_HOOK_FLAGS, "hook permission bits"
        );
        require(tokenFactory.launchHook() == address(hook), "launch hook not wired");
        require(
            !launchpadAdmitted || hook.allowedLaunchpad(address(tokenFactory)),
            "launchpad not admitted"
        );
        require(
            collectionFactory.quoteRegistry() == address(registry)
                && tokenFactory.quoteRegistry() == address(registry),
            "quote registry not wired"
        );
        require(registry.approvedQuote(USDC), "USDC is not an approved quote");

        string memory key = "arc";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBool(key, "verified", false);
        vm.serializeBool(key, "rehearsed", false);
        vm.serializeString(key, "sourceRevision", revision);
        vm.serializeString(key, "compiler", "0.8.36");
        vm.serializeString(key, "assetOrigin", origin);
        vm.serializeBool(key, "viaIR", false);
        vm.serializeString(key, "evmVersion", "cancun");
        vm.serializeUint(key, "optimizerRuns", 1500);
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "deployer", deployer);
        // The hook is the one address on the rail no getter can vouch for. Its deployer and salt
        // are what let anyone re-derive it from this revision's creation code.
        vm.serializeAddress(key, "create2Deployer", create2Deployer);
        vm.serializeBytes32(key, "launchHookSalt", hookSalt);
        vm.serializeBool(key, "launchpadAdmitted", launchpadAdmitted);
        vm.serializeAddress(key, "treasury", treasury);
        vm.serializeAddress(key, "platformSigner", signer);
        vm.serializeAddress(key, "quote", USDC);
        vm.serializeAddress(key, "poolManager", manager);
        vm.serializeAddress(key, "permit2", PERMIT2);
        vm.serializeAddress(key, "multicall3", MULTICALL3);
        vm.serializeAddress(key, "launchpadFactory", address(collectionFactory));
        vm.serializeAddress(key, "tokenLaunchFactory", address(tokenFactory));
        vm.serializeAddress(key, "quoteRegistry", address(registry));
        vm.serializeAddress(key, "launchHook", address(hook));
        vm.serializeAddress(key, "launchLens", address(lens));
        string memory record = vm.serializeAddress(key, "launchRouter", address(router));
        console2.log(record);
        // Staged. A dry run, a fork rehearsal or a test prints the record and stops; a broadcast
        // run leaves the staged file for deploy.sh to move into place once the chain has taken
        // every transaction.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        vm.writeJson(record, network.stagingPath);
    }

    /// The hook this rail runs on: the one already deployed when `ARC_LAUNCH_HOOK` names it,
    /// and otherwise a freshly mined one.
    ///
    /// A hook's address is a function of its creation code, so a rerun that simply forgot to
    /// name the existing one mines a second hook, keys the new factory to it, and replaces the
    /// only file that says where the first one is. Every market already trading against the
    /// announced hook would be gone from that record.
    function _resolveHook() private returns (LaunchHook resolved) {
        create2Deployer =
            CANONICAL_CREATE2.code.length != 0 ? CANONICAL_CREATE2 : address(new Create2Deployer());

        address supplied = vm.envOr("ARC_LAUNCH_HOOK", address(0));
        if (supplied != address(0)) {
            require(supplied.code.length > 0, "no code at ARC_LAUNCH_HOOK");
            require(
                uint160(supplied) & HOOK_FLAG_MASK == LAUNCH_HOOK_FLAGS,
                "ARC_LAUNCH_HOOK permission bits"
            );
            resolved = LaunchHook(supplied);
            require(address(resolved.POOL_MANAGER()) == manager, "ARC_LAUNCH_HOOK manager");
            return resolved;
        }

        require(
            _recordedHook() == address(0) || vm.envOr("ARC_ALLOW_NEW_LAUNCH_HOOK", false),
            HOOK_OVERRIDE_HINT
        );
        bytes memory initcode = abi.encodePacked(
            type(LaunchHook).creationCode, abi.encode(IPoolManager(manager), deployer)
        );
        (address expected, bytes32 salt) =
            HookMiner.find(create2Deployer, LAUNCH_HOOK_FLAGS, initcode);
        hookSalt = salt;
        // Nothing is sent when the hook is already there. A CREATE2 address is a function of the
        // deployer, the salt and the creation code, so a contract at this one was made from this
        // exact code; deploying anyway is a collision, and a collision burns the whole frame.
        if (expected.code.length == 0) {
            if (create2Deployer == CANONICAL_CREATE2) {
                (bool ok,) = create2Deployer.call(abi.encodePacked(salt, initcode));
                require(ok, "hook deployment failed");
            } else {
                Create2Deployer(create2Deployer).deploy(salt, initcode);
            }
            require(expected.code.length > 0, "hook deployment failed");
        }
        return LaunchHook(expected);
    }

    /// The hook the committed record already names, or zero before the first deployment.
    ///
    /// The existence check is not redundant with the `try`. `vm.readFile` reverts while the
    /// argument is being evaluated, which is before the call the `try` guards, so a missing file
    /// takes the whole frame down rather than returning zero. That never showed on a network
    /// whose record was already committed.
    function _recordedHook() private view returns (address) {
        string memory path = _network().recordPath;
        if (!vm.exists(path)) return address(0);
        try vm.parseJsonAddress(vm.readFile(path), ".launchHook") returns (address prior) {
            return prior;
        } catch {
            return address(0);
        }
    }
}
