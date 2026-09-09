// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { LaunchpadFactory } from "../src/LaunchpadFactory.sol";
import { TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { LaunchHook } from "../src/hook/LaunchHook.sol";
import { LaunchLens } from "../src/LaunchLens.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { ITokenLaunchpad } from "../src/interfaces/ITokenLaunchpad.sol";
import { TestnetWETH } from "../src/TestnetWETH.sol";
import { TestnetStockToken } from "../src/TestnetStockToken.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { CollectionDeployer } from "../src/libraries/CollectionDeployer.sol";
import { PoolDeployer } from "../src/libraries/PoolDeployer.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { LockerDeployer } from "../src/libraries/LockerDeployer.sol";
import { TokenDeployer } from "../src/libraries/TokenDeployer.sol";
import { VestingDeployer } from "../src/libraries/VestingDeployer.sol";

/// The one ArbSys read this script makes. Robinhood Chain is an Arbitrum Orbit chain, where the
/// EVM's own `NUMBER` answers with the parent chain's height; this precompile answers with the
/// height the chain itself is numbered by, which is the one every RPC, explorer and log query on
/// it uses.
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// Mines a CREATE2 salt so a contract's deployed address carries exactly the Uniswap V4 hook
/// permission flags in its low 14 bits. The address math mirrors the CREATE2 opcode: an address
/// is keccak256(0xff, deployer, salt, initcodeHash), so a mined salt reproduces its address only
/// for the exact deployer it was mined against. The canonical proxy and a locally deployed one
/// derive different addresses from the same salt, so `find` takes the deployer that will run.
library HookMiner {
    /// Uniswap `Hooks.ALL_HOOK_MASK`: the low 14 bits of a hook address encode its permissions.
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);
    /// One in 2^14 candidates lands the flags, so this range expects ~64 hits and misses only
    /// with probability ~e^-64. A miss reverts before any broadcast, so it costs nothing but time.
    uint256 internal constant MAX_LOOP = 1_048_576;

    function find(address deployer, uint160 flags, bytes memory initcode)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initcodeHash = keccak256(initcode);
        for (uint256 i = 0; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initcodeHash);
            if (uint160(hook) & FLAG_MASK == flags) return (hook, salt);
        }
        revert("HookMiner: no salt in range");
    }

    /// @dev In assembly, and deliberately: the search runs tens of thousands of times and
    ///      `abi.encodePacked` allocates a fresh 85-byte buffer on every one of them. At a hook
    ///      bitmap with six bits set that is megabytes of memory, and memory is priced
    ///      quadratically, so a mine that should cost a few million gas runs the caller out of
    ///      it. This writes into scratch space above the free-memory pointer and never moves it,
    ///      so the search costs the same on its last iteration as on its first.
    function computeAddress(address deployer, bytes32 salt, bytes32 initcodeHash)
        internal
        pure
        returns (address hook)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initcodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            // 0xff sits in the byte immediately before the 20-byte deployer address, which the
            // word above right-aligns at `ptr + 0x0c`.
            let start := add(ptr, 0x0b)
            mstore8(start, 0xff)
            hook := and(keccak256(start, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}

/// Minimal CREATE2 deployer, deployed only when a chain lacks the canonical
/// deterministic-deployment proxy. It applies the standard CREATE2 rule, but its own address
/// feeds that rule, so a given salt lands the hook at a different address here than under the
/// canonical proxy. `_deployHook` mines the salt against whichever deployer it actually uses.
contract Create2Deployer {
    address private immutable DEPLOYER = msg.sender;

    error Unauthorized();

    function deploy(bytes32 salt, bytes calldata initcode) external returns (address addr) {
        if (msg.sender != DEPLOYER) revert Unauthorized();
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, initcode.offset, initcode.length)
            addr := create2(0, ptr, initcode.length, salt)
            if iszero(addr) { revert(0, 0) }
        }
    }
}

/// Deploys and wires the whole launchpad on Robinhood Chain: the payment token, the NFT rail
/// (LaunchpadFactory), and the token rail (TokenLaunchFactory + the singleton LaunchHook, mined
/// to a valid Uniswap V4 hook address). The payment token is resolved per chain: mainnet insists
/// on canonical WETH, while non-mainnet deployments fall back to an access-controlled TestnetWETH.
///
///   TREASURY              fee recipient for launch fees and the protocol mint share
///   PLATFORM_SIGNER       reveal-worker signer for one-shot LIVE token metadata
///   FACTORY_OWNER         next factory admin; defaults to the broadcasting deployer
///   WETH                  optional payment-token override
///   TESTNET_WETH_OWNER    test-token admin (defaults to FACTORY_OWNER)
///   TESTNET_FAUCET_OPERATOR hot wallet allowed to sponsor bounded test-token claims; required
///                          on Robinhood Chain testnet when WETH is unset
///   TESTNET_FAUCET_RESERVE initial finite faucet reserve in token wei
///   GRADUATION_KEEPER      funded keeper address recorded for service rotation on testnet;
///                          must differ from PLATFORM_SIGNER
///   ASSET_ORIGIN          HTTPS origin serving collection documents, no trailing slash (for
///                          example https://api.ripples.run); required on Robinhood Chain
///   POOL_MANAGER          Uniswap V4 PoolManager (defaults to the 4663 canonical on mainnet)
///   LAUNCH_HOOK           an already-deployed singleton LaunchHook to reuse. Absent, the run
///                         mines and deploys one owned by the broadcaster. A hook owned by
///                         anybody else is used but cannot be wired: the run records the
///                         `setLaunchpad` call its owner still has to send
///   TOKEN_LAUNCH_FEE      optional token-rail launch fee override (WETH, 18 decimals)
///   ALLOW_MAINNET_DEPLOY  must be true to broadcast on chain 4663
///   WRITE_DEPLOYMENTS     set false to skip the deployments.json write on a broadcast run
///   SOURCE_COMMIT         the revision being deployed, recorded so the live bytecode can be
///                         rebuilt later: `SOURCE_COMMIT=$(git rev-parse HEAD)`. Required on
///                         Robinhood Chain whenever the run writes deployments.json
///
/// The quote allowlist, seeded into a freshly deployed `QuoteRegistry` in the same pre-handoff
/// window as `setAssetOrigin` and `setGraduationHook`, and serialized into the record so the
/// next redeploy cannot erase it (a hand-added allowlist would be silently deleted, and unlike
/// the buyback keys a missing one is not obviously broken; every named quote simply disappears
/// from the form):
///
///   QUOTE_ALLOWLIST       comma-separated quote addresses to approve
///   QUOTE_ECONOMICS       parallel list of
///                         `phantom:threshold:decimals:minPrice:standalonePhantom`, each figure
///                         in that quote's own smallest unit. The two phantom reserves are the
///                         opening reserve of a linked launch and of a standalone one; a row
///                         written in the older four-field form is refused rather than defaulted,
///                         because the missing figure is the price half the launches in that
///                         asset would open at
///   QUOTE_KINDS           optional parallel list of record kinds
///                         (weth | stablecoin | robinhoodStockToken | testStock)
///   TESTNET_STOCK_18      46630 only: reuse this 18-decimal TestnetStockToken instead of
///                         deploying a new one
///   TESTNET_STOCK_6       46630 only: the same for the 6-decimal, USDG-shaped one
///   TESTNET_STOCK_FAUCET_RESERVE_UNITS
///                         46630 only: each test stock token's faucet reserve in WHOLE units
///                         (default 1_000_000); the token's own decimals scale it, because
///                         `FAUCET_AMOUNT` is an immutable one whole unit and not a constant 1e18
///   STOCK_LINK_REGISTRY   the deployed StockLinkRegistry to record. Absent, the network's
///                         existing record value is carried forward rather than erased
///
/// The deployer is whichever sender forge is running as (--private-key / --account / --keystore
/// / --sender). No environment variable overrides it, so a key retired from the environment is
/// really retired.
contract Deploy is Script {
    uint256 internal constant RH_MAINNET = 4663;
    uint256 internal constant RH_TESTNET = 46630;
    address internal constant CANONICAL_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant DEFAULT_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CANONICAL_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// Arbitrum's ArbSys, at the same address on every Nitro and Orbit chain.
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    /// What one `arbBlockNumber()` read may cost, succeed or fail. See `recordedBlock`.
    uint256 internal constant ARB_SYS_GAS = 100_000;
    /// `LaunchHook`'s permission bitmap: `beforeInitialize | beforeAddLiquidity |
    /// beforeRemoveLiquidity | beforeSwap | afterSwap | afterSwapReturnsDelta`. The low 14 bits
    /// of a v4 hook's address are its permissions, so this is what the address is mined for and
    /// what the PoolManager checks on every pool keyed to it.
    uint160 internal constant LAUNCH_HOOK_FLAGS = 0x2AC4;
    uint160 internal constant HOOK_FLAG_MASK = uint160((1 << 14) - 1);
    /// A Ripples pool charges no pool fee: the hook charges in `afterSwap` instead, so the fee
    /// schedule is a hook decision rather than a new pool. The spacing is the one the v4 pools
    /// already indexed on this chain use.
    uint256 internal constant DEFAULT_POOL_FEE = 0;
    int256 internal constant DEFAULT_TICK_SPACING = 200;
    uint256 internal constant MAX_TOKEN_LAUNCH_FEE = 1e17;
    /// The widest ratio the two curve reserves of one quote may stand in. It is deliberately
    /// loose: the shape of a curve is the owner's to choose, and what this catches is a
    /// mis-paste: a threshold written at one asset's decimals beside a phantom written at
    /// another's is off by a factor of a million, never by a factor of ten.
    uint256 internal constant MAX_RESERVE_RATIO = 100;
    /// The largest phantom reserve that can be meant seriously, in whole units of the quote.
    /// Wei-shaped reserves handed to a six-decimal asset land far above this.
    uint256 internal constant MAX_PHANTOM_UNITS = 1e12;
    /// The reserves every quote this script seeds itself is approved with, in whole units: the
    /// shape `contracts/test/TokenBase.t.sol` proves at 6, 8 and 18 decimals. `QUOTE_ECONOMICS`
    /// overrides it for any quote named in the environment.
    uint256 internal constant DEFAULT_PHANTOM_UNITS = 30_000;
    uint256 internal constant DEFAULT_THRESHOLD_UNITS = 24_000;
    /// The same shape's standalone opening reserve. A standalone launch takes no contributions,
    /// so it is free to open further below its target: a quarter of the linked reserve, which is
    /// a market that runs 12.25 times from its opening price to the same target instead of 3.24.
    /// `docs/plans/2026-09-07-launch-shape.md` derives the pair and why one cannot serve both.
    uint256 internal constant DEFAULT_STANDALONE_PHANTOM_UNITS = 9_600;
    /// The chain's own asset is the exception, and it is the one figure the product states out
    /// loud: one whole unit is the funding target a launch on this rail opens with, and the
    /// phantom reserve is a quarter above it, which is where every other row sits too. The pair
    /// is `CONTRACT_LAUNCH_DEFAULTS` in `apps/web/lib/launch-defaults.ts`, what the launch form
    /// declares and what `/proof` prints; a registry seeded at anything else makes the site
    /// state a target no launch has. Hundredths, because 1.25 is not a whole number of units.
    uint256 internal constant DEFAULT_QUOTE_PHANTOM_CENTIUNITS = 525;
    uint256 internal constant DEFAULT_QUOTE_THRESHOLD_CENTIUNITS = 420;
    uint256 internal constant DEFAULT_QUOTE_STANDALONE_PHANTOM_CENTIUNITS = 168;
    /// Each 46630 test stock token's faucet reserve, in whole units of its own decimals.
    uint256 internal constant DEFAULT_TESTNET_STOCK_RESERVE_UNITS = 1_000_000;
    /// Both ways past `LaunchHookAlreadyRecorded`, in the error itself: the operator reading it
    /// is mid-redeploy on a live network and should not have to open this file to get out.
    string internal constant HOOK_OVERRIDE_HINT =
        "set LAUNCH_HOOK to the recorded hook, or ALLOW_NEW_LAUNCH_HOOK=true to mine a new one";

    error MainnetNotAuthorized();
    error UnexpectedWeth(address supplied);
    error UnexpectedPoolManager(address supplied);
    error NoCodeAt(address target);
    error PaymentTokenRequired();
    error PoolManagerRequired();
    error HookAddressInvalid(address hook);
    error HookNotWired();
    error HookDeployFailed();
    error HookPoolManagerMismatch(address hook);
    error LaunchHookAlreadyRecorded(address recorded, string howToProceed);
    error LaunchpadNotAdmitted();
    error FaucetOperatorRequired();
    error TestnetPaymentTokenOverrideNotAuthorized(address token);
    error DeploymentMetadataAddressRequired(string variableName);
    error DeploymentSourceCommitRequired();
    error DeploymentAddressRequired(string variableName);
    error GraduationKeeperMatchesPlatformSigner(address account);
    error TokenLaunchFeeTooHigh(uint256 fee);
    error AssetOriginRequired();
    error AssetOriginInvalid(string origin);
    error QuoteListLengthMismatch(uint256 quotes, uint256 economics);
    error QuoteEconomicsMalformed(string entry);
    error QuoteAddressRequired();
    error QuoteListHasDuplicate(address quote);
    error QuoteDecimalsOutOfRange(address quote, uint256 decimals);
    error QuoteDecimalsUnreadable(address quote);
    error QuoteDecimalsMismatch(address quote, uint8 declared, uint8 live);
    error QuoteEconomicsOutOfBand(address quote, string reason);
    error QuoteRaiseNotPairable(address quote, uint256 phantomQuote, uint256 graduationThreshold);
    error QuoteKindUnknown(string kind);
    error DefaultQuoteNotAllowlisted(address defaultQuote);
    error QuoteRegistryNotWired();

    struct DeploymentConfig {
        address treasury;
        address platformSigner;
        address suppliedWeth;
        address poolManager;
        address broadcaster;
        address owner;
        address tokenOwner;
        address faucetOperator;
        uint256 faucetReserve;
        uint256 tokenFee;
        bool deployedTestnetWeth;
        string assetOrigin;
    }

    /// One row of the allowlist: the asset, the economics it is approved with, and the word the
    /// record files it under. `symbol` is read off the asset at seed time, never declared.
    struct QuoteSeed {
        address quote;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
        uint256 minPriceQuote;
        uint256 standalonePhantomQuote;
        string kind;
    }

    bytes32 internal hookSalt;
    /// Whether `hookSalt` is a salt this run actually deployed at. A reuse run mines nothing, and
    /// a zero salt beside a real hook address re-derives some other address entirely.
    bool internal hookMined;
    address internal create2Deployer;
    /// Whether the hook admits the token factory by the time the broadcast closes. False only on
    /// a run against a hook someone else owns, which is a deployment that is finished but not yet
    /// open: the record and the console carry the call that finishes it.
    bool internal launchpadAdmitted;
    /// The record this run produced, kept after `run()` returns so a rehearsal can read back what
    /// a broadcast would have written without writing anything.
    string public deploymentRecord;
    /// The registry deployed by this run, and every row seeded into it. Both are read by
    /// `_report` after the broadcast closes, so they live in storage rather than in `run()`.
    address internal quoteRegistry;
    /// The batch reader this run deployed for its hook. It is a plain contract with no state and
    /// no permissions, so a run against a hook it does not own still deploys one: the lens reads
    /// the hook and never writes to it.
    address internal launchLens;
    QuoteSeed[] internal seeded;

    function run()
        external
        returns (
            LaunchpadFactory nftFactory,
            TokenLaunchFactory tokenFactory,
            LaunchHook hook,
            address weth
        )
    {
        DeploymentConfig memory c;
        c.treasury = vm.envAddress("TREASURY");
        c.platformSigner = vm.envAddress("PLATFORM_SIGNER");
        c.suppliedWeth = vm.envOr("WETH", address(0));
        c.poolManager = _poolManager();
        c.broadcaster = tx.origin;
        c.owner = vm.envOr("FACTORY_OWNER", c.broadcaster);
        c.assetOrigin = vm.envOr("ASSET_ORIGIN", string(""));

        _validateDeploymentAddresses(c.treasury, c.platformSigner, c.owner);
        _validateAssetOrigin(block.chainid, c.assetOrigin);
        _validateOperationalMetadata(block.chainid, c.platformSigner);

        if (block.chainid == RH_MAINNET) {
            if (!vm.envOr("ALLOW_MAINNET_DEPLOY", false)) revert MainnetNotAuthorized();
            if (c.suppliedWeth != address(0) && c.suppliedWeth != CANONICAL_WETH) {
                revert UnexpectedWeth(c.suppliedWeth);
            }
            weth = CANONICAL_WETH;
        } else {
            weth = c.suppliedWeth;
        }
        _guardTestnetPaymentTokenOverride(
            block.chainid, c.suppliedWeth, vm.envOr("ALLOW_TESTNET_WETH_OVERRIDE", false)
        );
        // The token address is immutable in every factory, curve, and collection under it, so a
        // wrong one is only fixable by redeploying the whole launchpad.
        if (weth != address(0) && weth.code.length == 0) revert NoCodeAt(weth);
        if (c.poolManager.code.length == 0) revert NoCodeAt(c.poolManager);
        c.deployedTestnetWeth = weth == address(0);
        if (c.deployedTestnetWeth) {
            c.tokenOwner = vm.envOr("TESTNET_WETH_OWNER", c.owner);
            if (c.tokenOwner == address(0)) {
                revert DeploymentAddressRequired("TESTNET_WETH_OWNER");
            }
            c.faucetOperator = _resolveFaucetOperator(
                block.chainid, vm.envOr("TESTNET_FAUCET_OPERATOR", address(0)), c.tokenOwner
            );
            c.faucetReserve = vm.envOr("TESTNET_FAUCET_RESERVE", uint256(1_000_000e18));
        }
        c.tokenFee = vm.envOr("TOKEN_LAUNCH_FEE", type(uint256).max);
        _guardTokenLaunchFee(c.tokenFee);

        // Parsed, validated and staged before a single transaction leaves: a malformed pair of
        // env lists is a typo, and finding it after the factories are on chain would mean a
        // second broadcast to finish an allowlist the record already claims is seeded.
        _stageEnvQuotes();
        // 4663 is the one network whose default quote is known before anything is sent, and the
        // one that seeds nothing of its own, so a run there with no allowlist would wire both
        // factories to an empty registry while the live registry's row stayed behind on the
        // contract being replaced. Every launch on the new rail would then be refused its own
        // default quote. The 46630 and local branches are held to the same rule inside the
        // broadcast, in `_seedQuotes`, because their default quote may not exist yet.
        if (block.chainid == RH_MAINNET && !_isStaged(weth)) {
            revert DefaultQuoteNotAllowlisted(weth);
        }

        vm.startBroadcast();

        if (c.deployedTestnetWeth) {
            if (block.chainid == RH_MAINNET) revert PaymentTokenRequired();
            weth = address(new TestnetWETH(c.tokenOwner, c.faucetOperator, c.faucetReserve));
        }

        nftFactory = new LaunchpadFactory(weth, c.treasury, c.platformSigner, c.broadcaster);
        tokenFactory = new TokenLaunchFactory(
            weth, c.poolManager, c.treasury, c.platformSigner, c.broadcaster
        );

        // Set before the ownership handoff: a collection reads the origin at creation, so a
        // factory that launches without one publishes drops with no collection document.
        if (bytes(c.assetOrigin).length != 0) {
            nftFactory.setAssetOrigin(c.assetOrigin);
            tokenFactory.setAssetOrigin(c.assetOrigin);
        }

        hook = _resolveHook(c);
        tokenFactory.setLaunchHook(address(hook));
        // The hook is a singleton with its own owner: it outlives every factory that uses it, so
        // admitting a factory is an entry in its mapping rather than a new hook and a new
        // announced address. A run that deployed the hook itself owns it and can do it here; a
        // run reusing an existing hook cannot, and says so in the record instead of pretending.
        if (hook.owner() == c.broadcaster) hook.setLaunchpad(address(tokenFactory), true);

        if (c.tokenFee != type(uint256).max) tokenFactory.setLaunchFee(c.tokenFee);

        // The batch read a terminal prices a board of markets from. It lives outside the hook
        // because a hook is mined to its address and cannot be redeployed without stranding
        // every market keyed to it, while the read that carries an array of nested structs grows
        // with every field a launch gains. Deployed per hook, so a run reusing a hook still gets
        // a lens that matches the config shape that hook actually stores.
        launchLens = address(new LaunchLens(ILaunchHook(address(hook))));

        // One registry, shared by both rails. It is deployed, wired and seeded here rather than
        // taken by either constructor: the factories' constructor shapes are read by verify.sh
        // and by the deployed bytecode's verification, and a registry the broadcaster still owns
        // is the only window in which the allowlist can be seeded without a Safe transaction per
        // asset. Until a factory is wired it launches in the fee token alone, which is exactly
        // what both did before per-launch quotes.
        QuoteRegistry registry = new QuoteRegistry(weth, weth, c.broadcaster);
        quoteRegistry = address(registry);
        nftFactory.setQuoteRegistry(quoteRegistry);
        tokenFactory.setQuoteRegistry(quoteRegistry);
        _seedQuotes(registry, weth, c);

        // The broadcaster owns the factories long enough to finish one-shot hook wiring.
        // A distinct configured owner receives the existing two-step handoff afterward.
        if (c.owner != c.broadcaster) {
            nftFactory.transferOwnership(c.owner);
            tokenFactory.transferOwnership(c.owner);
            if (hook.owner() == c.broadcaster) hook.transferOwnership(c.owner);
            // The registry is Ownable2Step like the factories, so this opens the same handoff:
            // the seeded list is already on chain and the next `approveQuote` is the new
            // owner's, through ops/rh-safe-exec.sh where that owner is a Safe.
            registry.transferOwnership(c.owner);
        }

        vm.stopBroadcast();

        // No launch is possible unless these hold: the address must encode exactly the
        // permission bitmap the PoolManager looks for, the factory must be keyed to the hook, and
        // the hook must admit the factory. The third is the one a reused hook can fail, and it
        // fails silently at the first launch rather than here, so it is read here.
        if (uint160(address(hook)) & HOOK_FLAG_MASK != LAUNCH_HOOK_FLAGS) {
            revert HookAddressInvalid(address(hook));
        }
        if (tokenFactory.launchHook() != address(hook)) revert HookNotWired();
        launchpadAdmitted = hook.allowedLaunchpad(address(tokenFactory));
        // Only a run that owns the hook can be held to the admission, and it did it above, so a
        // gap here would be this script's bug. A run against a hook someone else owns has no way
        // to admit anything and must still write its record: reverting here would abort the
        // simulation, broadcast nothing, and leave the operator with no addresses at all.
        if (!launchpadAdmitted && hook.owner() == c.broadcaster) revert LaunchpadNotAdmitted();
        // A factory left unwired would refuse every named quote with `QuoteNotApproved` while
        // the default kept working, a rail that looks alive and offers one asset.
        if (nftFactory.quoteRegistry() != quoteRegistry) revert QuoteRegistryNotWired();
        if (tokenFactory.quoteRegistry() != quoteRegistry) revert QuoteRegistryNotWired();

        _report(nftFactory, tokenFactory, hook, weth, c);
    }

    /// The singleton launch hook: the one already on chain, or a freshly mined one.
    ///
    /// `LAUNCH_HOOK` names an existing deployment and is how a **factory redeploy** works. The
    /// hook is mined once, its address is announced, and every launch's pool key carries it, so
    /// re-mining one alongside a new factory would leave the markets already trading keyed to a
    /// hook nothing points at. The reused address is checked for both things a wrong one fails
    /// silently on: the permission bits, and the PoolManager it was mined against.
    ///
    /// Absent, the run mines and deploys one owned by the broadcaster, wires it, and hands it
    /// over with the factories. `MineLaunchHook.s.sol` is the other way round and is what a
    /// deploy whose hook must be owned by a Safe from its first block uses: mine and broadcast
    /// there, then pass the address here.
    function _resolveHook(DeploymentConfig memory c) private returns (LaunchHook hook) {
        address dep =
            CANONICAL_CREATE2.code.length != 0 ? CANONICAL_CREATE2 : address(new Create2Deployer());
        create2Deployer = dep;

        address supplied = vm.envOr("LAUNCH_HOOK", address(0));
        if (supplied != address(0)) {
            if (supplied.code.length == 0) revert NoCodeAt(supplied);
            if (uint160(supplied) & HOOK_FLAG_MASK != LAUNCH_HOOK_FLAGS) {
                revert HookAddressInvalid(supplied);
            }
            hook = LaunchHook(payable(supplied));
            if (address(hook.POOL_MANAGER()) != c.poolManager) {
                revert HookPoolManagerMismatch(supplied);
            }
            return hook;
        }

        // A hook address is a function of its creation code, so a redeploy that simply forgot
        // `LAUNCH_HOOK` mines a second one: the new factory would be keyed to it, the record
        // would be rewritten to name it, and every market already trading against the announced
        // hook would be gone from the only file that says where they are.
        address recorded = recordedLaunchHook(_networkKey());
        if (recorded != address(0) && !vm.envOr("ALLOW_NEW_LAUNCH_HOOK", false)) {
            revert LaunchHookAlreadyRecorded(recorded, HOOK_OVERRIDE_HINT);
        }

        bytes memory initcode = abi.encodePacked(
            type(LaunchHook).creationCode, abi.encode(IPoolManager(c.poolManager), c.broadcaster)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(dep, LAUNCH_HOOK_FLAGS, initcode);
        hookSalt = salt;
        hookMined = true;

        // Nothing is sent when the hook is already there. A CREATE2 address is a function of the
        // deployer, the salt and the initcode hash, so a contract at this one was made from this
        // exact creation code and is the hook; issuing the deployment anyway would be a CREATE
        // collision, and a collision consumes every unit of gas the frame was given.
        if (hookAddr.code.length == 0) {
            if (dep == CANONICAL_CREATE2) {
                (bool ok,) = dep.call(abi.encodePacked(salt, initcode));
                if (!ok) revert HookDeployFailed();
            } else {
                Create2Deployer(dep).deploy(salt, initcode);
            }
            if (hookAddr.code.length == 0) revert HookDeployFailed();
        }
        return LaunchHook(payable(hookAddr));
    }

    function _poolManager() private view returns (address pm) {
        return _resolvePoolManager(block.chainid, vm.envOr("POOL_MANAGER", address(0)));
    }

    function _resolvePoolManager(uint256 chainId, address supplied)
        internal
        pure
        returns (address)
    {
        if (chainId == RH_MAINNET) {
            if (supplied != address(0) && supplied != DEFAULT_POOL_MANAGER) {
                revert UnexpectedPoolManager(supplied);
            }
            return DEFAULT_POOL_MANAGER;
        }
        if (supplied == address(0)) revert PoolManagerRequired();
        return supplied;
    }

    function _resolveFaucetOperator(uint256 chainId, address supplied, address fallbackOwner)
        internal
        pure
        returns (address)
    {
        if (supplied != address(0)) return supplied;
        if (chainId == RH_TESTNET) revert FaucetOperatorRequired();
        return fallbackOwner;
    }

    function _guardTestnetPaymentTokenOverride(uint256 chainId, address supplied, bool authorized)
        internal
        pure
    {
        if (chainId == RH_TESTNET && supplied != address(0) && !authorized) {
            revert TestnetPaymentTokenOverrideNotAuthorized(supplied);
        }
    }

    function _guardOperationalRoles(
        uint256 chainId,
        address platformSigner,
        address graduationKeeper
    ) internal pure {
        if (chainId != RH_TESTNET && chainId != RH_MAINNET) return;
        if (graduationKeeper == platformSigner) {
            revert GraduationKeeperMatchesPlatformSigner(platformSigner);
        }
    }

    /// Both real chains publish collection documents, and the origin cannot be added to a
    /// collection after it is created, so a deploy without one ships drops OpenSea reads nothing
    /// from. Local and fork runs may leave it unset. A value that is set at all is held to the
    /// shape the collection appends its path to: an HTTPS origin with no trailing slash. A
    /// scheme-less or slash-terminated origin would be permanent in every collection born from
    /// this factory, so it fails here rather than on a marketplace months later.
    function _validateAssetOrigin(uint256 chainId, string memory origin) internal pure {
        bytes memory raw = bytes(origin);
        if (raw.length == 0) {
            if (chainId == RH_TESTNET || chainId == RH_MAINNET) revert AssetOriginRequired();
            return;
        }
        bytes memory scheme = bytes("https://");
        if (raw.length <= scheme.length) revert AssetOriginInvalid(origin);
        for (uint256 i = 0; i < scheme.length; i++) {
            if (raw[i] != scheme[i]) revert AssetOriginInvalid(origin);
        }
        if (raw[raw.length - 1] == "/") revert AssetOriginInvalid(origin);
    }

    function _guardTokenLaunchFee(uint256 fee) internal pure {
        if (fee != type(uint256).max && fee > MAX_TOKEN_LAUNCH_FEE) {
            revert TokenLaunchFeeTooHigh(fee);
        }
    }

    function _validateDeploymentAddresses(address treasury, address platformSigner, address owner)
        internal
        pure
    {
        if (treasury == address(0)) revert DeploymentAddressRequired("TREASURY");
        if (platformSigner == address(0)) {
            revert DeploymentAddressRequired("PLATFORM_SIGNER");
        }
        if (owner == address(0)) revert DeploymentAddressRequired("FACTORY_OWNER");
    }

    /// Both real chains get the same checks. Separating the keeper from the reveal signer matters
    /// more on the chain holding money, and `deployBlock` cannot be recovered after the fact.
    function _validateOperationalMetadata(uint256 chainId, address platformSigner) private view {
        if (chainId != RH_TESTNET && chainId != RH_MAINNET) return;

        address graduationKeeper = _requiredMetadataAddress("GRADUATION_KEEPER");
        _guardOperationalRoles(chainId, platformSigner, graduationKeeper);

        // Checked here, before anything is broadcast, rather than at the write.
        _guardSourceCommit(_writesDeployments(), vm.envOr("SOURCE_COMMIT", string("")));
    }

    /// A write replaces a network's whole entry in deployments.json, so a run that does not carry
    /// the revision it built from would erase the only record of where the live bytecode came
    /// from, and nothing could be recompiled to match it afterwards.
    function _guardSourceCommit(bool writesDeployments, string memory sourceCommit) internal pure {
        if (writesDeployments && bytes(sourceCommit).length == 0) {
            revert DeploymentSourceCommitRequired();
        }
    }

    // The quote allowlist

    /// Parse and validate `QUOTE_ALLOWLIST` / `QUOTE_ECONOMICS` into `seeded`, before any
    /// broadcast. Nothing here touches a chain except the two reads every seeded asset must
    /// answer: it has code, and it says what its smallest unit means.
    function _stageEnvQuotes() private {
        QuoteSeed[] memory fromEnv = quoteAllowlistFromEnv(
            vm.envOr("QUOTE_ALLOWLIST", string("")), vm.envOr("QUOTE_ECONOMICS", string(""))
        );
        string[] memory kinds =
            _quoteKindsFromEnv(vm.envOr("QUOTE_KINDS", string("")), fromEnv.length);
        for (uint256 i = 0; i < fromEnv.length; i++) {
            fromEnv[i].kind = kinds[i];
            _stageQuote(fromEnv[i]);
        }
    }

    /// Add one row, rejecting a duplicate: approving the same asset twice is always a paste
    /// error, and the second row would silently be the one that stands.
    function _stageQuote(QuoteSeed memory s) private {
        validateQuoteEconomics(s);
        _validateQuoteAsset(s);
        for (uint256 i = 0; i < seeded.length; i++) {
            if (seeded[i].quote == s.quote) revert QuoteListHasDuplicate(s.quote);
        }
        seeded.push(s);
    }

    /// Seed the registry inside the broadcast. On 46630 the two test stock tokens the rehearsal
    /// needs are deployed here first, because no stock token exists on that chain to point at.
    function _seedQuotes(QuoteRegistry registry, address weth, DeploymentConfig memory c) private {
        if (block.chainid == RH_TESTNET) {
            if (!_isStaged(weth)) _stageQuote(_defaultQuoteSeed(weth));
            _stageQuote(_defaultSeed(_testnetStock("Testnet Stock", "TSTKX", 18, c), "testStock"));
            _stageQuote(
                _defaultSeed(_testnetStock("Testnet Global Dollar", "TUSDG", 6, c), "testStock")
            );
        }
        if (seeded.length == 0) return;
        // The default quote is what a launch that names nothing settles in, and the form offers
        // it first. A list that does not carry it publishes an allowlist the default is missing
        // from, and `/proof` would render an asset set that omits the one every launch uses.
        if (!_isStaged(weth)) revert DefaultQuoteNotAllowlisted(weth);
        for (uint256 i = 0; i < seeded.length; i++) {
            QuoteSeed memory s = seeded[i];
            registry.approveQuote(
                s.quote,
                IQuoteRegistry.QuoteEconomics({
                    phantomQuote: s.phantomQuote,
                    graduationThreshold: s.graduationThreshold,
                    decimals: s.decimals,
                    minPriceQuote: s.minPriceQuote,
                    standalonePhantomQuote: s.standalonePhantomQuote
                })
            );
        }
    }

    /// The 46630 test stock token at `dec` decimals: an existing one when the environment names
    /// it, otherwise a fresh deploy. `FAUCET_AMOUNT` on it is an immutable one whole unit, so
    /// the reserve is written in whole units here and never as a hard-coded 1e18.
    function _testnetStock(
        string memory name_,
        string memory symbol_,
        uint8 dec,
        DeploymentConfig memory c
    ) private returns (address token) {
        token = vm.envOr(dec == 6 ? "TESTNET_STOCK_6" : "TESTNET_STOCK_18", address(0));
        if (token != address(0)) {
            if (token.code.length == 0) revert NoCodeAt(token);
            return token;
        }
        address stockOwner = c.tokenOwner == address(0) ? c.owner : c.tokenOwner;
        address operator = c.faucetOperator == address(0) ? stockOwner : c.faucetOperator;
        uint256 reserve = vm.envOr(
            "TESTNET_STOCK_FAUCET_RESERVE_UNITS", DEFAULT_TESTNET_STOCK_RESERVE_UNITS
        ) * (10 ** dec);
        return address(new TestnetStockToken(name_, symbol_, dec, stockOwner, operator, reserve));
    }

    /// The row this script approves an asset with when nothing overrides it: the reserve shape
    /// `contracts/test/TokenBase.t.sol` proves identical at 6, 8 and 18 decimals, restated in
    /// the asset's own smallest unit. Raw units everywhere, no normalisation anywhere (DQ5).
    function _defaultSeed(address quote, string memory kind)
        private
        view
        returns (QuoteSeed memory s)
    {
        uint8 dec = _liveDecimals(quote);
        uint256 unit = 10 ** dec;
        s.quote = quote;
        s.phantomQuote = DEFAULT_PHANTOM_UNITS * unit;
        s.graduationThreshold = DEFAULT_THRESHOLD_UNITS * unit;
        s.decimals = dec;
        // A floor a drop's mint price must reach, not the price itself (DQ1, amended). It exists
        // for one reason: a price whose routed share rounds away at this asset's decimals funds
        // the market with nothing while the minter still pays. At 20% routed that needs a price
        // of five base units, so a whole unit was three orders of magnitude past what the check
        // is for, and it priced every sensible NFT drop out: on 4663 it made the floor one WETH,
        // which is more than every shape the launch form offers.
        //
        // A thousandth of a unit is still far above the rounding limit at every decimal count
        // this registry accepts, and it leaves an ordinary drop room to be priced.
        s.minPriceQuote = unit / 1_000;
        s.standalonePhantomQuote = DEFAULT_STANDALONE_PHANTOM_UNITS * unit;
        s.kind = kind;
    }

    /// The chain's own asset, at the figures the site states for it. Every other seeded row is
    /// sized by value at approval and nothing outside the registry quotes it; this one is quoted
    /// on `/proof`, in the launch form's fact card and in the deployment record, so it is the one
    /// row that has to come out of the same pair of numbers those three read.
    function _defaultQuoteSeed(address quote) private view returns (QuoteSeed memory s) {
        s = _defaultSeed(quote, "weth");
        uint256 unit = 10 ** s.decimals;
        s.phantomQuote = (DEFAULT_QUOTE_PHANTOM_CENTIUNITS * unit) / 100;
        s.graduationThreshold = (DEFAULT_QUOTE_THRESHOLD_CENTIUNITS * unit) / 100;
        s.standalonePhantomQuote = (DEFAULT_QUOTE_STANDALONE_PHANTOM_CENTIUNITS * unit) / 100;
    }

    function _isStaged(address quote) private view returns (bool) {
        for (uint256 i = 0; i < seeded.length; i++) {
            if (seeded[i].quote == quote) return true;
        }
        return false;
    }

    /// @notice Parse the two parallel environment lists into allowlist rows.
    ///
    ///         Positional, and a length mismatch is refused rather than defaulted: the nth
    ///         economics entry belongs to the nth address, and a list one short would shift
    ///         every asset after it onto another asset's reserves.
    function quoteAllowlistFromEnv(string memory addresses, string memory economics)
        internal
        pure
        returns (QuoteSeed[] memory seeds)
    {
        string memory addrList = vm.trim(addresses);
        string memory econList = vm.trim(economics);
        if (bytes(addrList).length == 0 && bytes(econList).length == 0) {
            return new QuoteSeed[](0);
        }
        string[] memory rawAddrs = vm.split(addrList, ",");
        string[] memory rawEcon = vm.split(econList, ",");
        if (rawAddrs.length != rawEcon.length) {
            revert QuoteListLengthMismatch(rawAddrs.length, rawEcon.length);
        }
        seeds = new QuoteSeed[](rawAddrs.length);
        for (uint256 i = 0; i < rawAddrs.length; i++) {
            seeds[i] = _quoteSeedFrom(vm.trim(rawAddrs[i]), vm.trim(rawEcon[i]));
        }
    }

    function _quoteSeedFrom(string memory addr, string memory economics)
        private
        pure
        returns (QuoteSeed memory s)
    {
        string[] memory f = vm.split(economics, ":");
        if (f.length != 5) revert QuoteEconomicsMalformed(economics);
        s.quote = vm.parseAddress(addr);
        s.phantomQuote = vm.parseUint(vm.trim(f[0]));
        s.graduationThreshold = vm.parseUint(vm.trim(f[1]));
        uint256 dec = vm.parseUint(vm.trim(f[2]));
        if (dec == 0 || dec > 18) revert QuoteDecimalsOutOfRange(s.quote, dec);
        s.decimals = uint8(dec);
        s.minPriceQuote = vm.parseUint(vm.trim(f[3]));
        s.standalonePhantomQuote = vm.parseUint(vm.trim(f[4]));
    }

    /// The kind each row is filed under in the record, defaulted when the list is absent. Only
    /// the four words the record's readers know are accepted: an unknown one would reach
    /// `apps/web/lib/evm/deployments.ts` as a type error months later.
    function _quoteKindsFromEnv(string memory kinds, uint256 expected)
        private
        pure
        returns (string[] memory out)
    {
        string memory list = vm.trim(kinds);
        if (bytes(list).length == 0) {
            out = new string[](expected);
            for (uint256 i = 0; i < expected; i++) {
                out[i] = "robinhoodStockToken";
            }
            return out;
        }
        out = vm.split(list, ",");
        if (out.length != expected) revert QuoteListLengthMismatch(expected, out.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = vm.trim(out[i]);
            _requireKnownKind(out[i]);
        }
    }

    function _requireKnownKind(string memory kind) private pure {
        bytes32 h = keccak256(bytes(kind));
        if (
            h != keccak256("weth") && h != keccak256("stablecoin")
                && h != keccak256("robinhoodStockToken") && h != keccak256("testStock")
        ) revert QuoteKindUnknown(kind);
    }

    /// @notice The band a row's economics must land in. Pure, so the boundary is proven without
    ///         a broadcast.
    ///
    ///         The check that actually catches the Pons failure (wei-shaped reserves handed to
    ///         a six-decimal asset) is `decimals` against the asset's own `decimals()`, made in
    ///         `_validateQuoteAsset` and again by the registry itself. What this adds is the
    ///         arithmetic that check cannot see: a reserve pair too far apart to be one curve,
    ///         a phantom reserve outside any plausible size at the declared decimals, and a
    ///         price floor above the whole phantom reserve, which no drop could ever reach.
    function validateQuoteEconomics(QuoteSeed memory s) internal pure {
        if (s.quote == address(0)) revert QuoteAddressRequired();
        if (s.decimals == 0 || s.decimals > 18) {
            revert QuoteDecimalsOutOfRange(s.quote, s.decimals);
        }
        uint256 unit = 10 ** s.decimals;
        uint256 ceiling = MAX_PHANTOM_UNITS * unit;
        if (s.phantomQuote == 0 || s.graduationThreshold == 0 || s.standalonePhantomQuote == 0) {
            revert QuoteEconomicsOutOfBand(s.quote, "every reserve must be non-zero");
        }
        if (s.minPriceQuote == 0) {
            revert QuoteEconomicsOutOfBand(s.quote, "minPriceQuote must be non-zero");
        }
        if (s.phantomQuote < unit || s.phantomQuote > ceiling) {
            revert QuoteEconomicsOutOfBand(s.quote, "phantomQuote is not a plausible size");
        }
        if (s.standalonePhantomQuote < unit || s.standalonePhantomQuote > ceiling) {
            revert QuoteEconomicsOutOfBand(
                s.quote, "standalonePhantomQuote is not a plausible size"
            );
        }
        // The standalone profile is the one that opens further below the target, so its reserve
        // is the smaller of the two. Written the other way round the row reads legal and every
        // market in this asset opens on the wrong profile. The registry refuses it too; here it
        // is refused before anything is broadcast, with the reason in the revert.
        if (s.standalonePhantomQuote > s.phantomQuote) {
            revert QuoteEconomicsOutOfBand(s.quote, "the standalone reserve is the smaller one");
        }
        if (s.graduationThreshold > ceiling) {
            revert QuoteEconomicsOutOfBand(s.quote, "graduationThreshold is not a plausible size");
        }
        if (
            s.graduationThreshold * MAX_RESERVE_RATIO < s.phantomQuote
                || s.phantomQuote * MAX_RESERVE_RATIO < s.graduationThreshold
        ) revert QuoteEconomicsOutOfBand(s.quote, "the two reserves are not one curve");
        // One direction only. The standalone reserve sits under the linked one, which the check
        // above already holds within a hundredfold of the target, so a standalone reserve too
        // large for its target cannot get here; too small for it still can.
        if (s.standalonePhantomQuote * MAX_RESERVE_RATIO < s.graduationThreshold) {
            revert QuoteEconomicsOutOfBand(s.quote, "the standalone reserve is not one curve");
        }
        if (s.minPriceQuote > s.phantomQuote) {
            revert QuoteEconomicsOutOfBand(s.quote, "minPriceQuote is above the phantom reserve");
        }
        _requireTheRaiseCanBePaired(s);
    }

    /// @notice The tighter half of the reserve band, and the one that costs a creator money.
    ///
    ///         `TokenLaunchFactory` sizes a **linked** launch's supply against the raise at the
    ///         **launch** price, and separately admits any curve position that fits inside
    ///         `curveSupply + lpTokenSupply`. What is left to pair the raise into the permanent
    ///         position is the difference between those two, and at the **graduation** price the
    ///         raise buys more token than the difference holds once the phantom reserve sits too
    ///         close to the target. `LPLocker` then credits the quote it cannot pair to the
    ///         treasury rather than to the pool, which is the creator's raise leaving the market
    ///         it was raised for. The approval path is where a row that could reach it is
    ///         refused, because a row outlives the launches made against it.
    ///
    ///         The remainder covers the raise exactly when
    ///         `(phantomQuote + graduationThreshold) / phantomQuote` is at least the golden
    ///         ratio. Phi is the root of `x^2 = x + 1`, so squaring that statement and clearing
    ///         the denominator gives the line below, in integers and with no decimal
    ///         approximation of an irrational number standing in for the boundary. Every row on
    ///         chain sits at 1.8, and so does every default this script seeds itself.
    ///
    ///         `standalonePhantomQuote` needs no line of its own, twice over. It is at or below
    ///         `phantomQuote`, refused above, and the inequality below holds for every reserve
    ///         under `phi * graduationThreshold`, so a row that passes it on the linked reserve
    ///         passes it on the standalone one. And a standalone launch is not sized at the
    ///         launch price at all: it takes no contributions, so the factory holds it to the
    ///         graduation price directly, which is a check on the launch rather than on the row.
    function _requireTheRaiseCanBePaired(QuoteSeed memory s) private pure {
        uint256 target = s.graduationThreshold;
        uint256 phantom = s.phantomQuote;
        // Both are at most `MAX_PHANTOM_UNITS * 1e18`, checked above, so neither product is
        // anywhere near overflowing.
        if (target * (phantom + target) < phantom * phantom) {
            revert QuoteRaiseNotPairable(s.quote, phantom, target);
        }
    }

    /// Code at the address, and decimals that agree with the row. The registry makes the second
    /// check too, but it makes it inside a transaction the deploy has already paid for; here it
    /// is a staticcall before anything is broadcast.
    function _validateQuoteAsset(QuoteSeed memory s) private view {
        if (s.quote.code.length == 0) revert NoCodeAt(s.quote);
        uint8 live = _liveDecimals(s.quote);
        if (live != s.decimals) revert QuoteDecimalsMismatch(s.quote, s.decimals, live);
    }

    /// An asset that will not say what its smallest unit means cannot be settled in: every
    /// figure in this system is raw and nothing normalises anywhere.
    function _liveDecimals(address quote) private view returns (uint8) {
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            return d;
        } catch {
            revert QuoteDecimalsUnreadable(quote);
        }
    }

    function _quoteSymbol(address quote) private view returns (string memory) {
        try IERC20Metadata(quote).symbol() returns (string memory sym) {
            return sym;
        } catch {
            return "";
        }
    }

    /// The allowlist as the record carries it: one object per asset, keyed by address, with
    /// every integer as a decimal string. `phantomQuote` at 18 decimals is past 2^53, and a
    /// JSON number there loses its low digits in every JavaScript reader of this file.
    function _quoteRecord() private returns (string memory) {
        // Both object ids are scoped to this run's registry. forge's JSON serializer keys its
        // buffers by id for the life of the process, so a fixed `"quotes"` would union two runs'
        // allowlists if `run()` were ever called twice in one invocation: a record naming assets
        // that are not on the registry it points at.
        string memory scope = vm.toString(quoteRegistry);
        string memory quotes = string.concat("quotes:", scope);
        string memory out = "{}";
        for (uint256 i = 0; i < seeded.length; i++) {
            QuoteSeed memory s = seeded[i];
            string memory row = string.concat("quote:", scope, ":", vm.toString(s.quote));
            vm.serializeString(row, "symbol", _quoteSymbol(s.quote));
            vm.serializeUint(row, "decimals", s.decimals);
            vm.serializeString(row, "kind", s.kind);
            vm.serializeString(row, "phantomQuote", vm.toString(s.phantomQuote));
            vm.serializeString(row, "graduationThreshold", vm.toString(s.graduationThreshold));
            vm.serializeString(row, "minPriceQuote", vm.toString(s.minPriceQuote));
            vm.serializeString(row, "standalonePhantomQuote", vm.toString(s.standalonePhantomQuote));
            string memory body = vm.serializeUint(row, "approvedAtBlock", recordedBlock());
            out = vm.serializeString(quotes, vm.toString(s.quote), body);
        }
        return out;
    }

    /// The height a deployment is recorded at, in the numbering every reader of this record uses.
    ///
    /// Robinhood Chain is an Arbitrum Orbit chain, and there the EVM's `NUMBER` answers with the
    /// **parent** chain's height rather than this chain's. The two are an order of magnitude
    /// apart, and both are plausible block numbers here, so the mistake is silent: the 2026-09-05
    /// testnet release was first recorded at 11,638,799 while 46630 stood at 113,311,756, and
    /// 11,638,799 is itself a real 46630 block from six months earlier.
    ///
    /// `deployBlock` and `approvedAtBlock` are handed to `eth_getLogs` as `fromBlock` by
    /// `ops/rpls/burner-check.mjs`, by the keeper's `FROM_BLOCK` and by `/proof`, so a parent
    /// chain height there is not cosmetic. It starts every scan long before the release existed.
    ///
    /// ArbSys answers with the chain's own height. The read is a staticcall and every failure
    /// falls back to `block.number` rather than reverting: by the time the record is written the
    /// deployment has already been broadcast, and a run that aborts here leaves contracts live
    /// with nothing committed that names them. Off the two Orbit chains (anvil, a unit test, any
    /// other network) `block.number` is that chain's own height and is used directly.
    ///
    /// **The gas cap is load bearing, and this is the only place in the repository that needs
    /// one.** `eth_getCode` on either Robinhood endpoint answers `0xfe` for every Arbitrum
    /// precompile, so a forked EVM, which is what `forge script` and every fork suite run on,
    /// fetches that byte and executes it as INVALID. An invalid opcode consumes the whole call
    /// frame's gas, and an uncapped staticcall forwards 63/64 of what is left, so each of these
    /// reads used to divide the run's remaining gas by 64. Three of them (one per seeded quote
    /// row plus this one) took a 1.07 billion gas budget to nothing and the script died of
    /// `MemoryOOG` while serializing its own record, after the deploy had already broadcast.
    /// Capped, a failed read costs its cap and nothing else. A live Orbit node answers the same
    /// call natively for about 2,100 gas.
    function recordedBlock() internal view returns (uint256) {
        if (block.chainid != RH_TESTNET && block.chainid != RH_MAINNET) return block.number;
        (bool ok, bytes memory answer) =
            ARB_SYS.staticcall{ gas: ARB_SYS_GAS }(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (!ok || answer.length < 32) return block.number;
        uint256 height = abi.decode(answer, (uint256));
        return height == 0 ? block.number : height;
    }

    /// The registry the record should name, carried forward when this run does not deploy one.
    /// `DeployStockLink.s.sol` deliberately writes nothing, so without this a factory redeploy
    /// would drop the address and the stock-link panel would stop mounting.
    function stockLinkRegistryFor(string memory network) internal view returns (address) {
        address named = vm.envOr("STOCK_LINK_REGISTRY", address(0));
        if (named != address(0)) return named;
        return _recordedAddress(network, "stockLinkRegistry");
    }

    /// The hook a network's record already names, which is the hook every market on that network
    /// is keyed to. Zero before the first deployment, and on any chain the record has no entry
    /// for. Read by `_resolveHook` before it mines.
    function recordedLaunchHook(string memory network) internal view returns (address) {
        return _recordedAddress(network, "launchHook");
    }

    /// One address out of the committed record, or zero when the network, the file or the key is
    /// absent. A local or fork rehearsal passes an empty network and reads nothing.
    function _recordedAddress(string memory network, string memory key)
        private
        view
        returns (address)
    {
        if (bytes(network).length == 0) return address(0);
        string memory path = string.concat(".", network, ".", key);
        try vm.parseJsonAddress(vm.readFile("./deployments.json"), path) returns (address prior) {
            return prior;
        } catch {
            return address(0);
        }
    }

    function _report(
        LaunchpadFactory nftFactory,
        TokenLaunchFactory tokenFactory,
        LaunchHook hook,
        address weth,
        DeploymentConfig memory c
    ) private {
        // Scoped to this run, for the reason `_quoteRecord` gives: forge keys its serializer
        // buffers by id for the life of the process, so a fixed `"deployment"` would carry an
        // earlier run's keys into a later run's record. Every key this function writes
        // conditionally, the salt among them, would then be one run behind. It has to be unique
        // across instances as well as across calls, because a test builds a fresh `Deploy` per
        // scenario; a per-instance counter restarts at one and collides. `address(this)` gave that
        // for free and forge refuses it in a script contract, so this asks for a fresh id instead.
        string memory obj = string.concat("deployment:", vm.toString(vm.randomUint()));
        vm.serializeUint(obj, "chainId", block.chainid);
        // `weth` is the default quote's address under the name every existing reader already
        // uses: DeployBurner.s.sol, verify.sh, the CI manifest gate, apps/web and services/api.
        // `defaultQuote` is the same address under the name the v2 readers ask for, and both
        // stay in the record so neither generation of reader has to be changed to keep working.
        vm.serializeAddress(obj, "weth", weth);
        vm.serializeAddress(obj, "defaultQuote", weth);
        // The launch fee is charged in this asset whatever a launch settles in, and it stays
        // WETH (DQ3). A creator launching against a stock token approves two assets.
        vm.serializeAddress(obj, "feeToken", weth);
        vm.serializeAddress(obj, "quoteRegistry", quoteRegistry);
        // Read off the factory rather than typed, so the redeploy runbook's manual copy-out of
        // this figure into apps/web disappears and /proof can read one file.
        vm.serializeUint(obj, "lockerFeeCreatorBps", tokenFactory.LP_FEE_CREATOR_BPS());
        // Omitted rather than written empty when this run seeded nothing. An absent key is
        // "this network has no allowlist yet", which is 4663's real state until the owner seeds one
        // is answered (DQ14); an empty object is the same fact with a second way to read it,
        // and `/proof` would have to tell them apart to render anything.
        if (seeded.length != 0) vm.serializeString(obj, "quotes", _quoteRecord());
        vm.serializeAddress(obj, "poolManager", c.poolManager);
        vm.serializeAddress(obj, "treasury", c.treasury);
        vm.serializeAddress(obj, "platformSigner", c.platformSigner);
        vm.serializeAddress(obj, "owner", nftFactory.owner());
        vm.serializeAddress(obj, "pendingOwner", nftFactory.pendingOwner());
        vm.serializeString(obj, "assetOrigin", c.assetOrigin);
        vm.serializeAddress(obj, "launchpadFactory", address(nftFactory));
        vm.serializeAddress(obj, "tokenLaunchFactory", address(tokenFactory));
        vm.serializeAddress(obj, "create2Deployer", create2Deployer);
        // Only when this run mined it. A salt is only meaningful beside the deployer and the
        // creation code it was mined against, and a reuse run has neither: writing a zero there
        // would put a salt in the record that re-derives an address the hook is not at.
        if (hookMined) vm.serializeBytes32(obj, "launchHookSalt", hookSalt);
        // Under both names: `graduationHook` is what every deployed reader asks for, and the
        // hook a launch's pool is keyed to is also the hook that settles its graduation, so the
        // two are one address now rather than two contracts.
        vm.serializeAddress(obj, "graduationHook", address(hook));
        // Whether the token rail is open. A hook this run did not deploy belongs to whoever did,
        // and only that owner can admit a factory to it, so the record says plainly that the
        // launchpad is deployed and still shut, and carries the one call that opens it.
        vm.serializeBool(obj, "launchpadAdmitted", launchpadAdmitted);
        string memory pendingHookCall = string.concat(
            "setLaunchpad(address,bool) on LaunchHook ",
            vm.toString(address(hook)),
            " with (",
            vm.toString(address(tokenFactory)),
            ", true), sent by its owner ",
            vm.toString(hook.owner())
        );
        if (!launchpadAdmitted) vm.serializeString(obj, "pendingHookCall", pendingHookCall);
        vm.serializeString(obj, "libraries", _libraryRecord());
        string memory sourceCommit = vm.envOr("SOURCE_COMMIT", string(""));
        if (bytes(sourceCommit).length != 0) {
            vm.serializeString(obj, "sourceCommit", sourceCommit);
        }
        // A write replaces the network's whole entry, so an address this run did not deploy has
        // to be carried forward here or it is erased. Omitted while it is zero: an optional key
        // that is absent reads as "not deployed", and a zero address would read as deployed.
        address stockLink = stockLinkRegistryFor(_networkKey());
        if (stockLink != address(0)) {
            vm.serializeAddress(obj, "stockLinkRegistry", stockLink);
        }
        if (block.chainid == RH_TESTNET || block.chainid == RH_MAINNET) {
            vm.serializeAddress(
                obj, "graduationKeeper", _requiredMetadataAddress("GRADUATION_KEEPER")
            );
            vm.serializeUint(obj, "deployBlock", recordedBlock());
            vm.serializeUint(obj, "poolFee", DEFAULT_POOL_FEE);
            vm.serializeInt(obj, "tickSpacing", DEFAULT_TICK_SPACING);
            vm.serializeString(
                obj,
                "rpc",
                block.chainid == RH_MAINNET
                    ? "https://rpc.mainnet.chain.robinhood.com"
                    : "https://rpc.testnet.chain.robinhood.com"
            );
        }
        vm.serializeAddress(obj, "launchLens", launchLens);
        string memory record = vm.serializeAddress(obj, "launchHook", address(hook));
        deploymentRecord = record;

        console2.log(record);
        if (!launchpadAdmitted) {
            console2.log("LAUNCHPAD NOT YET ADMITTED. No launch can be created until this is sent:");
            console2.log(pendingHookCall);
        }

        // deployments.json is the committed record of what is live, so only a run that actually
        // put these addresses on a known chain may touch it. A dry run, a fork rehearsal or a
        // test prints the record and stops.
        if (!_writesDeployments()) return;
        string memory network = _networkKey();
        if (bytes(network).length != 0) {
            vm.writeJson(record, "./deployments.json", string.concat(".", network));
            if (block.chainid == RH_TESTNET) {
                _writeTestnetPaymentToken(weth, c.deployedTestnetWeth);
            }
        }
    }

    function _requiredMetadataAddress(string memory variableName)
        private
        view
        returns (address value)
    {
        value = vm.envAddress(variableName);
        if (value == address(0)) revert DeploymentMetadataAddressRequired(variableName);
    }

    /// The five deployer libraries the factories delegate to. Their addresses are part of the
    /// factories' creation code, so verification has to recompile against exactly these; the
    /// broadcast record that also holds them is not committed, and a takeover on another
    /// machine has only deployments.json to work from.
    ///
    /// `PoolDeployer` replaced `LaunchDeployer`: there is no bonding-curve creation code left to
    /// carry, and what took its place is the code that opens and seeds a launch's pool. A record
    /// that named only four would leave the one library nothing else can rediscover missing from
    /// every later verification.
    function _libraryRecord() internal returns (string memory) {
        string memory libs = "libraries";
        vm.serializeAddress(libs, "CollectionDeployer", address(CollectionDeployer));
        vm.serializeAddress(libs, "PoolDeployer", address(PoolDeployer));
        vm.serializeAddress(libs, "LockerDeployer", address(LockerDeployer));
        vm.serializeAddress(libs, "TokenDeployer", address(TokenDeployer));
        return vm.serializeAddress(libs, "VestingDeployer", address(VestingDeployer));
    }

    /// True when this run will replace a network's entry in deployments.json.
    function _writesDeployments() private view returns (bool) {
        return
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && vm.envOr("WRITE_DEPLOYMENTS", true);
    }

    function _writeTestnetPaymentToken(address weth, bool deployedTestnetWeth) private {
        string memory token = "testnetPaymentToken";
        vm.serializeString(token, "network", "Robinhood Chain testnet");
        vm.serializeAddress(token, "address", weth);
        // Read, not assumed: `FAUCET_AMOUNT` on both testnet token shapes is an immutable one
        // whole unit rather than a constant 1e18, so a record that hard-codes 18 would misstate
        // a six-decimal payment token by a factor of a trillion.
        vm.serializeUint(token, "decimals", _liveDecimals(weth));
        vm.serializeString(token, "standard", "EIP-2612");
        vm.serializeString(token, "kind", deployedTestnetWeth ? "TestnetWETH" : "supplied token");
        if (deployedTestnetWeth) {
            TestnetWETH payment = TestnetWETH(weth);
            vm.serializeAddress(token, "owner", payment.owner());
            vm.serializeAddress(token, "faucetOperator", payment.faucetOperator());
            vm.serializeUint(token, "faucetAmount", payment.FAUCET_AMOUNT());
            vm.serializeUint(token, "faucetCooldown", payment.FAUCET_COOLDOWN());
            vm.serializeUint(token, "faucetReserve", payment.faucetReserve());
        }
        string memory tokenRecord = vm.serializeString(
            token,
            "note",
            "Active payment token for robinhoodTestnet, not canonical WETH. Deploy.s.sol keeps this address synchronized with robinhoodTestnet.weth."
        );
        vm.writeJson(tokenRecord, "./deployments.json", ".weth.46630");

        string memory domain = "testnetPaymentDomain";
        vm.serializeString(domain, "name", "WETH");
        string memory domainRecord = vm.serializeString(domain, "version", "1");
        vm.writeJson(domainRecord, "./deployments.json", ".weth.46630.domain");
    }

    function _networkKey() private view returns (string memory) {
        if (block.chainid == RH_MAINNET) return "robinhoodMainnet";
        if (block.chainid == RH_TESTNET) return "robinhoodTestnet";
        return "";
    }
}
