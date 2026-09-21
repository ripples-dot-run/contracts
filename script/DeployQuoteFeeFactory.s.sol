// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { QuoteFeeFactory } from "../src/QuoteFeeFactory.sol";
import { QuoteFeeRouter } from "../src/QuoteFeeRouter.sol";
import { QuoteFeeHook } from "../src/hook/QuoteFeeHook.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// Open the quote-fee rail: `QuoteFeeFactory`, its `QuoteFeeRouter` treasury, and a registry that
/// states WETH's economics correctly for this hook. `Deploy.s.sol` never touches any of the
/// three, so nothing before this script exists to seed them.
///
/// The registry is the reason this is its own script rather than a call to `Deploy.s.sol`'s. That
/// script's `QuoteRegistry` already carries a WETH row for `TokenLaunchFactory`: phantom 5.25,
/// threshold 4.20, standalone phantom 1.68, `apps/web/lib/launch-defaults.ts`'s
/// `CONTRACT_LAUNCH_DEFAULTS` and what `/proof` states as the funding target. `LaunchHook` takes
/// its trade fee out of the launch token, never the quote, so a buyer's whole quote reaches the
/// curve and that row's threshold is exactly the raise buyers send. `QuoteFeeHook` takes the same
/// fee out of the quote itself, in `beforeSwap`, before the curve ever runs: an exact-input buy's
/// curve-visible amount is already net of it. Pointing this factory at the same row would leave
/// `graduationThreshold` true to its own name (the pool really would hold 4.2 WETH at graduation)
/// while quietly asking buyers for `4.2 / (1 - tradeFeeBps) ≈ 4.2424` WETH gross to put it there,
/// about 1.01% more than this chain's other launches take and more than anything this factory's
/// own launches will state.
///
/// `tradeFeeBps` is not the whole skim, though: `creatorTaxBps` is a per-launch choice up to
/// `MAX_CREATOR_TAX_BPS`, and it is the only income a creator has on this factory
/// (`LP_FEE_CREATOR_BPS = 0`). It leaves the quote before the curve exactly as `tradeFeeBps` does,
/// so a launch that sets it skims more than the fixed trade fee alone, and `_requireReserves`
/// holds every launch to the same registry-wide `graduationThreshold` regardless of its own
/// `creatorTaxBps`. Discounting by `tradeFeeBps` alone would understate that launch's real gross
/// requirement by up to `MAX_CREATOR_TAX_BPS`, the opposite of the plain promise this row exists
/// to keep. Scaling the whole row down by `(1 - (tradeFeeBps + MAX_CREATOR_TAX_BPS) / 10_000)`
/// instead sizes for the worst case any launch on this factory can choose: send the same ~4.2 WETH
/// gross, and no launch, whatever its own tax, is ever asked for more than that to graduate. A
/// launch with a lower or zero creator tax simply graduates with a larger reserve than the
/// worst-case figure demands, which is the safe direction for this to be wrong in. `phantomQuote`
/// and `standalonePhantomQuote` scale by the same factor, so the ratio between threshold and
/// phantom lands exactly where `Deploy.s.sol`'s row already sets it (k = 0.8):
/// `QuoteRegistry.approveQuote`'s pairability check and the curve's own shape are unaffected, only
/// its absolute size.
///
/// A **dedicated** registry, not `Deploy.s.sol`'s shared one: `QuoteEconomics` is one row per
/// quote address, `TokenLaunchFactory` already owns the WETH row in the registry that script
/// seeds, and two factories cannot read two different figures off the one field. Deploying a
/// second `QuoteRegistry` instance does not conflict with that contract's own "one registry
/// serves both factories" doc comment; that line is about the NFT and token factories sharing one
/// instance so `LaunchpadFactory` need not carry a second allowlist, not a claim that every
/// factory ever added shares the first instance regardless of what its hook charges.
///
/// This factory is WETH-only today (`docs/plans` name no stock-quoted launch on this rail), so
/// the registry this script seeds carries a WETH row and nothing else. A later stock-quoted
/// launch on this hook needs its own row added the same way `Deploy.s.sol` seeds one, scaled by
/// this same factor.
///
///   Environment:
///     WETH                  the settlement asset. Defaults to the network record's `weth`.
///     POOL_MANAGER          the v4 PoolManager. Defaults to the network record's `poolManager`.
///     QUOTE_FEE_HOOK        the mined `QuoteFeeHook` from `MineQuoteFeeHook.s.sol`. Required:
///                           this factory cannot create a launch until it is wired to one.
///     QUOTE_FEE_ROUTER      an already-deployed `QuoteFeeRouter` to reuse as the factory's
///                           treasury. Absent, a fresh one is deployed from BUYBACK/SAFE/GUARDIAN.
///     BUYBACK, SAFE, GUARDIAN   `QuoteFeeRouter`'s constructor args, read only when this run
///                           deploys its own.
///     PLATFORM_SIGNER       the factory's dev-buy signer.
///     FACTORY_OWNER         who the two-step handoff on the factory and the registry is opened
///                           to. Defaults to the broadcaster.
///     ALLOW_MAINNET_DEPLOY  must be true to broadcast on chain 4663. Nothing in this repo's own
///                           tooling ever sets it.
///     WRITE_DEPLOYMENTS     false to broadcast without touching the record.
contract DeployQuoteFeeFactory is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    address internal constant CANONICAL_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// `QuoteFeeFactory.LAUNCH_HOOK_FLAGS`, restated so this script can check the hook it was
    /// handed before it spends a broadcast on it.
    uint160 internal constant HOOK_FLAGS = 0x2ACC;
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);

    /// `Deploy.s.sol`'s own WETH row, in hundredths of a whole unit: phantom 5.25, threshold
    /// 4.20, standalone phantom 1.68. Restated rather than imported (they are that script's own
    /// `internal` constants) because the two rows are meant to drift independently: this one
    /// tracks `TokenLaunchFactory`'s figure only to derive a discount from it, not to mirror it.
    uint256 internal constant BASE_PHANTOM_CENTIUNITS = 525;
    uint256 internal constant BASE_THRESHOLD_CENTIUNITS = 420;
    uint256 internal constant BASE_STANDALONE_PHANTOM_CENTIUNITS = 168;
    uint256 internal constant CENTIUNIT = 100;
    /// Same rule `Deploy.s.sol`'s `_defaultSeed` uses: a floor far above rounding at every
    /// decimals count this registry accepts, and no closer a reason than that one has.
    uint256 internal constant MIN_PRICE_DIVISOR = 1_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error MainnetNotAuthorized();
    error UnexpectedWeth(address supplied);
    error NoCodeAt(address target);
    error DeploymentAddressRequired(string variableName);
    error HookAddressInvalid(address hook);
    error HookPoolManagerMismatch(address hook);
    error HookNotWired();
    error LaunchpadNotAdmitted();
    error QuoteRegistryNotWired();

    struct Rail {
        address weth;
        address poolManager;
        address hook;
        address existingRouter;
        address buyback;
        address safe;
        address guardian;
        address platformSigner;
        address owner;
        address broadcaster;
    }

    /// Whether the freshly deployed factory could also be admitted on `QUOTE_FEE_HOOK`. Only a
    /// run that owns the hook can do this in the same broadcast; see `_check`.
    bool internal launchpadAdmitted;

    function run()
        external
        returns (QuoteFeeFactory factory, QuoteFeeRouter router, QuoteRegistry registry)
    {
        return deploy(_resolve());
    }

    /// The run itself, taking an already-resolved `Rail` rather than reading the environment: the
    /// one env read left is `ALLOW_MAINNET_DEPLOY`, checked here rather than only in `run()` so a
    /// caller that built its own `Rail` and skipped `_resolve()` (this file's own fork suite
    /// among them) still cannot broadcast to mainnet without it. Every other field arrives
    /// resolved, so this function never touches `vm.setEnv`'s shared, process-wide state, which is
    /// the one thing forge does not sandbox per test.
    function deploy(Rail memory r)
        public
        returns (QuoteFeeFactory factory, QuoteFeeRouter router, QuoteRegistry registry)
    {
        if (block.chainid == RH_MAINNET && !vm.envOr("ALLOW_MAINNET_DEPLOY", false)) {
            revert MainnetNotAuthorized();
        }

        _describe(r);

        vm.startBroadcast();

        router = r.existingRouter != address(0)
            ? QuoteFeeRouter(payable(r.existingRouter))
            : new QuoteFeeRouter(IERC20(r.weth), r.buyback, r.safe, r.guardian);

        factory = new QuoteFeeFactory(
            r.weth, r.poolManager, address(router), r.platformSigner, r.broadcaster
        );
        factory.setLaunchHook(r.hook);
        // Mirrors `Deploy.s.sol` and `DeployTokenFactory.s.sol`: only a run that deployed the
        // hook itself, and so still owns it, can also admit the factory to it in this broadcast.
        if (QuoteFeeHook(payable(r.hook)).owner() == r.broadcaster) {
            QuoteFeeHook(payable(r.hook)).setLaunchpad(address(factory), true);
        }

        registry = new QuoteRegistry(r.weth, r.weth, r.broadcaster);
        registry.approveQuote(
            r.weth, wethEconomics(r.weth, factory.TRADE_FEE_BPS() + factory.MAX_CREATOR_TAX_BPS())
        );
        factory.setQuoteRegistry(address(registry));

        // The two-step handoff, opened last, exactly where `Deploy.s.sol` and
        // `DeployTokenFactory.s.sol` open theirs: the broadcaster holds both contracts only long
        // enough to finish wiring them.
        if (r.owner != r.broadcaster) {
            factory.transferOwnership(r.owner);
            registry.transferOwnership(r.owner);
        }

        vm.stopBroadcast();

        _check(factory, registry, r);
        _record(factory, router, registry, r);
    }

    /// WETH's row for this factory: `Deploy.s.sol`'s figures scaled by
    /// `(1 - worstCaseBps / 10_000)`, where `worstCaseBps` is `TRADE_FEE_BPS` plus
    /// `MAX_CREATOR_TAX_BPS`, both read off the live `QuoteFeeFactory` rather than assumed, so
    /// this can never silently drift from what the deployed factory actually allows a launch to
    /// charge. Sized on the worst case a launch can choose, not the fixed trade fee alone, so a
    /// buyer sending this chain's usual ~4.2 WETH gross graduates the market whatever creator tax
    /// that particular launch set; a launch with a smaller tax graduates with a larger reserve
    /// than this figure demands, which is the safe direction. `minPriceQuote` is untouched: it
    /// floors an NFT drop's mint price, which this discount has no bearing on.
    function wethEconomics(address weth, uint256 worstCaseBps)
        public
        view
        returns (IQuoteRegistry.QuoteEconomics memory e)
    {
        uint8 decimals = IERC20Metadata(weth).decimals();
        uint256 unit = 10 ** decimals;
        uint256 keptBps = BPS_DENOMINATOR - worstCaseBps;
        e.phantomQuote = (BASE_PHANTOM_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.graduationThreshold =
            (BASE_THRESHOLD_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.standalonePhantomQuote =
            (BASE_STANDALONE_PHANTOM_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.decimals = decimals;
        e.minPriceQuote = unit / MIN_PRICE_DIVISOR;
    }

    function _resolve() private view returns (Rail memory r) {
        r.broadcaster = tx.origin;
        r.weth = vm.envOr("WETH", _recordedAddress("weth"));
        r.poolManager = vm.envOr("POOL_MANAGER", _recordedAddress("poolManager"));
        r.hook = vm.envAddress("QUOTE_FEE_HOOK");
        r.existingRouter = vm.envOr("QUOTE_FEE_ROUTER", address(0));
        // Read only when this run will deploy its own router; a run reusing one names none of
        // the three, and requiring them anyway would be an environment demand this run has no
        // use for.
        if (r.existingRouter == address(0)) {
            r.buyback = vm.envAddress("BUYBACK");
            r.safe = vm.envAddress("SAFE");
            r.guardian = vm.envAddress("GUARDIAN");
        }
        r.platformSigner = vm.envAddress("PLATFORM_SIGNER");
        r.owner = vm.envOr("FACTORY_OWNER", r.broadcaster);

        if (r.weth == address(0)) revert DeploymentAddressRequired("WETH");
        if (r.poolManager == address(0)) revert DeploymentAddressRequired("POOL_MANAGER");
        if (r.hook == address(0)) revert DeploymentAddressRequired("QUOTE_FEE_HOOK");
        if (block.chainid == RH_MAINNET && r.weth != CANONICAL_WETH) revert UnexpectedWeth(r.weth);
        if (r.weth.code.length == 0) revert NoCodeAt(r.weth);
        if (r.poolManager.code.length == 0) revert NoCodeAt(r.poolManager);
        if (r.hook.code.length == 0) revert NoCodeAt(r.hook);
        if (r.existingRouter != address(0) && r.existingRouter.code.length == 0) {
            revert NoCodeAt(r.existingRouter);
        }
        if (uint160(r.hook) & HOOK_FLAG_MASK != HOOK_FLAGS) revert HookAddressInvalid(r.hook);
        if (address(QuoteFeeHook(payable(r.hook)).POOL_MANAGER()) != r.poolManager) {
            revert HookPoolManagerMismatch(r.hook);
        }
    }

    function _describe(Rail memory r) private pure {
        console2.log("deploying the quote-fee rail");
        console2.log("  settles in     ", r.weth);
        console2.log("  pool manager   ", r.poolManager);
        console2.log("  quote fee hook ", r.hook);
        console2.log(
            "  quote fee router",
            r.existingRouter == address(0) ? "fresh" : "reused",
            r.existingRouter
        );
        console2.log("  platform signer", r.platformSigner);
        console2.log("  ownership offered to", r.owner);
    }

    /// No launch is possible unless these hold, and each fails silently at the first launch
    /// rather than at deployment, so each is read back here.
    function _check(QuoteFeeFactory factory, QuoteRegistry registry, Rail memory r) private {
        if (factory.launchHook() != r.hook) revert HookNotWired();
        if (factory.quoteRegistry() != address(registry)) revert QuoteRegistryNotWired();
        launchpadAdmitted = QuoteFeeHook(payable(r.hook)).allowedLaunchpad(address(factory));
        if (!launchpadAdmitted && QuoteFeeHook(payable(r.hook)).owner() == r.broadcaster) {
            revert LaunchpadNotAdmitted();
        }
    }

    function _record(
        QuoteFeeFactory factory,
        QuoteFeeRouter router,
        QuoteRegistry registry,
        Rail memory r
    ) private {
        console2.log("quoteFeeFactory ", address(factory));
        console2.log("quoteFeeRouter  ", address(router));
        console2.log("quoteFeeRegistry", address(registry));
        console2.log("launchpadAdmitted", launchpadAdmitted);
        if (!launchpadAdmitted) {
            console2.log("LAUNCHPAD NOT YET ADMITTED. No launch can be created until this is sent:");
            console2.log(
                string.concat(
                    "setLaunchpad(address,bool) on QuoteFeeHook ",
                    vm.toString(r.hook),
                    " with (",
                    vm.toString(address(factory)),
                    ", true), sent by its owner ",
                    vm.toString(QuoteFeeHook(payable(r.hook)).owner())
                )
            );
        }
        if (r.owner != r.broadcaster) {
            console2.log("ACCEPT OWNERSHIP: acceptOwnership() on the factory and the registry,");
            console2.log("  sent by", r.owner);
        }

        string memory network = _networkKey();
        if (bytes(network).length == 0 || !_writesDeployments()) return;

        vm.writeJson(
            vm.toString(address(factory)),
            "./deployments.json",
            string.concat(".", network, ".quoteFeeFactory")
        );
        vm.writeJson(
            vm.toString(r.hook), "./deployments.json", string.concat(".", network, ".quoteFeeHook")
        );
        vm.writeJson(
            vm.toString(address(router)),
            "./deployments.json",
            string.concat(".", network, ".quoteFeeRouter")
        );
        vm.writeJson(
            vm.toString(address(registry)),
            "./deployments.json",
            string.concat(".", network, ".quoteFeeRegistry")
        );
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
