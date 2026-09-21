// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { LPLocker } from "../src/LPLocker.sol";
import { LaunchRouter } from "../src/LaunchRouter.sol";
import { LaunchParams } from "../src/TokenLaunchFactory.sol";
import { QuoteFeeFactory } from "../src/QuoteFeeFactory.sol";
import { QuoteFeeRouter } from "../src/QuoteFeeRouter.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";
import { IAllowanceTransfer } from "../src/interfaces/IAllowanceTransfer.sol";
import { ILaunchHook, LaunchConfig } from "../src/hook/interfaces/ILaunchHook.sol";
import { QuoteFeeHook } from "../src/hook/QuoteFeeHook.sol";

/// The two swap shapes `LaunchRouter` has no front door for: exact-output, both directions.
/// `ILaunchRouter.swapExactIn` only ever sends a negative `amountSpecified`, so an exact-output
/// buy or sell trades straight against the manager, the same `unlock`/`settle`/`take` shape
/// `QuoteFeeForkSwapper` in `test/QuoteFeeGraduationFork.t.sol` already proves against this exact
/// hook on a fork. This is that contract's real-broadcast twin: funded with a real balance ahead
/// of each call rather than `deal`, since there is no cheatcode on a live chain.
contract QuoteFeeRehearsalSwapper is IUnlockCallback {
    IPoolManager private immutable POOL_MANAGER;

    error CallbackOnly();

    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// Exact-output buy: name the tokens out, the manager decides the quote in. Unspecified side
    /// is the quote, so `QuoteFeeHook` charges this one in `afterSwap`.
    function buyExactOut(PoolKey calldata key, address quote, uint256 tokensOut, address recipient)
        external
        returns (BalanceDelta)
    {
        bool quoteIsCurrency0 = Currency.unwrap(key.currency0) == quote;
        return _run(
            key,
            quoteIsCurrency0,
            int256(tokensOut),
            quoteIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            recipient
        );
    }

    /// Exact-output sell: name the quote out, the manager decides the tokens in. Unspecified side
    /// is the launch token here, so `QuoteFeeHook` still charges the quote, in `beforeSwap`.
    function sellExactOut(PoolKey calldata key, address token, uint256 quoteOut, address recipient)
        external
        returns (BalanceDelta)
    {
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        return _run(
            key,
            tokenIsCurrency0,
            int256(quoteOut),
            tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            recipient
        );
    }

    /// Sweep this contract's own balance of `asset` to `to`. Both swap shapes above spend out of
    /// whatever this contract already holds rather than pulling from a caller, so a rehearsal
    /// that funded it more than it spent gets the rest back rather than leaving it stranded.
    function sweep(IERC20 asset, address to) external returns (uint256 amount) {
        amount = asset.balanceOf(address(this));
        if (amount != 0) asset.transfer(to, amount);
    }

    function _run(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        address recipient
    ) private returns (BalanceDelta) {
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(key, zeroForOne, amountSpecified, limit, recipient)
        );
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert CallbackOnly();
        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 limit,
            address recipient
        ) = abi.decode(raw, (PoolKey, bool, int256, uint160, address));
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            ""
        );
        _resolve(key.currency0, delta.amount0(), recipient);
        _resolve(key.currency1, delta.amount1(), recipient);
        return abi.encode(delta);
    }

    function _resolve(Currency currency, int128 amount, address recipient) private {
        if (amount == 0) return;
        if (amount < 0) {
            uint256 owedAmount = uint256(uint128(-amount));
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owedAmount);
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, recipient, uint256(uint128(amount)));
        }
    }
}

/// The quote-fee rail's first real lifecycle, end to end, broadcast for real on Robinhood
/// testnet: launch a token through the already-deployed `QuoteFeeFactory`, trade all four swap
/// shapes through it, graduate it, and split its fee.
///
/// Two stages, run as two separate `forge script` invocations rather than one, the same
/// convention `RehearseDualFillShapes.s.sol` uses and for the same reason: a script's own
/// pre-broadcast gas-estimation replay evaluates every call in one batch at essentially one
/// timestamp, which a real broadcast never does (each transaction lands in its own real block,
/// seconds apart). `QuoteFeeHook`'s three-second snipe window and opening-tax decay are real
/// enough that a launch and an exact-output trade or a graduation sent as one batch fail that
/// replay even though sending them for real, minutes apart, does not; confirmed against 46630
/// while drafting this file. Splitting the stages means neither one needs `vm.warp` to make its
/// own replay agree with what a real broadcast will do, because by the time `graduate` runs, the
/// window really has elapsed on chain.
///
///   QF_STAGE=launch      deploy this hook's `LaunchRouter`, create the rehearsal launch, and
///                         trade the two exact-input shapes (buy, sell) through it.
///   QF_STAGE=graduate     trade the two exact-output shapes (buy, sell) direct against the
///                         manager, top up to the real threshold, graduate, and route the fee.
///                         Run only after `launch` has landed and the snipe window has passed.
///   WRITE_DEPLOYMENTS     false to skip the deployments.json write `graduate` makes.
///
/// Deliberately not a fork test: `QuoteFeeGraduationFork.t.sol` and
/// `DeployQuoteFeeFactoryFork.t.sol` already prove every one of these steps against the real
/// PoolManager bytecode under `deal` and local pranks. What neither can prove is that the same
/// calls clear a real mempool, a real `beforeSwapReturnDelta` settlement and a real Permit2
/// allowance on 46630 itself, which is what a broadcast run is for.
contract RehearseQuoteFee is Script {
    using StateLibrary for IPoolManager;

    uint256 internal constant RH_TESTNET = 46630;
    address internal constant WETH = 0x1F852eF3Afa13156b807204d838BbB46B4b452eb;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant DEPLOYMENTS = "./deployments.json";
    string internal constant STATE = "./cache/quote-fee-rehearsal-46630.json";

    address private broadcaster;
    address private safe;
    address private buyback;

    QuoteFeeHook private hook;
    QuoteFeeFactory private factory;
    QuoteFeeRouter private feeRouter;
    QuoteRegistry private registry;

    // `graduate` stage state only, held here rather than as locals: one function carrying the
    // whole stage in its own locals is exactly the shape that blows the stack on this compiler.
    address private tokenAddr;
    LPLocker private locker;
    LaunchRouter private launchRouter;
    PoolId private poolId;
    PoolKey private key;
    bool private quoteIsCurrency0;
    uint256 private deadline;

    function run() external {
        require(block.chainid == RH_TESTNET, "robinhood testnet only");
        broadcaster = tx.origin;

        hook = QuoteFeeHook(payable(_recorded(".robinhoodTestnet.quoteFeeHook")));
        factory = QuoteFeeFactory(_recorded(".robinhoodTestnet.quoteFeeFactory"));
        feeRouter = QuoteFeeRouter(payable(_recorded(".robinhoodTestnet.quoteFeeRouter")));
        registry = QuoteRegistry(_recorded(".robinhoodTestnet.quoteFeeRegistry"));
        buyback = feeRouter.BUYBACK();
        safe = feeRouter.SAFE();
        require(hook.allowedLaunchpad(address(factory)), "launchpad not admitted");

        string memory stage = vm.envOr("QF_STAGE", string("launch"));
        bytes32 stageHash = keccak256(bytes(stage));
        if (stageHash == keccak256(bytes("launch"))) {
            _stageLaunch();
        } else if (stageHash == keccak256(bytes("graduate"))) {
            _stageGraduate();
        } else {
            revert("QF_STAGE must be launch or graduate");
        }
    }

    function _stageLaunch() private {
        IQuoteRegistry.QuoteEconomics memory e = registry.quoteEconomics(WETH);
        console2.log("standalonePhantomQuote", e.standalonePhantomQuote);
        console2.log("graduationThreshold   ", e.graduationThreshold);

        // A `LaunchRouter` is a stateless front door keyed to one hook, not to one launch: any
        // pool on `hook` trades through the same instance. Reusing whatever this network already
        // recorded avoids orphaning a fresh one, and the address the web app is wired to, on every
        // rerun of this script.
        address existing = _existingLaunchRouterOrZero();
        vm.startBroadcast();
        LaunchRouter launchRouter = existing != address(0)
            ? LaunchRouter(existing)
            : new LaunchRouter(
                IPoolManager(POOL_MANAGER), ILaunchHook(address(hook)), IAllowanceTransfer(PERMIT2)
            );
        IERC20(WETH).approve(address(factory), type(uint256).max);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2)
            .approve(WETH, address(launchRouter), type(uint160).max, type(uint48).max);

        LaunchParams memory p = _params(e.standalonePhantomQuote, e.graduationThreshold);
        (address tokenAddr, address lockerAddr) = factory.createLaunch(p);
        console2.log("token ", tokenAddr);
        console2.log("locker", lockerAddr);

        PoolKey memory key = LPLocker(lockerAddr).poolKey();
        bool quoteIsCurrency0 = Currency.unwrap(key.currency0) == WETH;
        uint256 deadline = block.timestamp + 3600;

        // Shape 1: exact-in buy, through the unmodified `LaunchRouter` front door. Charged in
        // `beforeSwap` (quote is specified: this is an exact-input buy). Never blocked by the
        // opening tax, only priced by it, so this needs no elapsed time either.
        (uint256 spent1, uint256 out1) =
            launchRouter.swapExactIn(key, quoteIsCurrency0, 0.1 ether, 0, broadcaster, deadline);
        console2.log("shape 1 exact-in buy : spent", spent1, "received", out1);

        // Shape 2: exact-in sell, through the same front door. Charged in `afterSwap` (quote is
        // unspecified: this is an exact-input sell). A tenth rather than a proper fraction of the
        // shape-1 proceeds, so this never contends with rounding on the balance it just received.
        uint256 sellAmount = IERC20(tokenAddr).balanceOf(broadcaster) / 10;
        IERC20(tokenAddr).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2)
            .approve(tokenAddr, address(launchRouter), type(uint160).max, type(uint48).max);
        (uint256 spent2, uint256 out2) =
            launchRouter.swapExactIn(key, !quoteIsCurrency0, sellAmount, 0, broadcaster, deadline);
        vm.stopBroadcast();
        console2.log("shape 2 exact-in sell: spent", spent2, "received", out2);

        _save("token", tokenAddr);
        _save("locker", lockerAddr);
        _save("launchRouter", address(launchRouter));
    }

    function _stageGraduate() private {
        tokenAddr = _load("token");
        locker = LPLocker(_load("locker"));
        launchRouter = LaunchRouter(_load("launchRouter"));
        poolId = PoolId.wrap(locker.poolId());
        key = locker.poolKey();
        quoteIsCurrency0 = Currency.unwrap(key.currency0) == WETH;
        deadline = block.timestamp + 3600;

        _tradeExactOutputShapes();
        _topUpAndGraduate();
        _claimAndRoute();
        _recordLaunchRouter(address(launchRouter));
    }

    function _tradeExactOutputShapes() private {
        // Shapes 3 & 4: the two exact-output shapes, direct against the manager (`LaunchRouter`
        // has no exact-output front door). Funded ahead of time rather than approved, since
        // `QuoteFeeRehearsalSwapper` spends its own balance.
        //
        // The whole of what stage `launch` left the broadcaster holding, in both assets, rather
        // than a fixed fraction: `sweep` below returns whatever this stage does not spend, so
        // over-funding costs nothing, but a fixed eighth is a bet on the curve's absolute price,
        // and that bet does not carry across a registry change. `RefreshQuoteFeeRegistry.s.sol`
        // resized `standalonePhantomQuote` down 10% ahead of this run, which lowers the curve's
        // starting price against the same `vTokenInit` and raises the tokens a fixed quote target
        // costs: an eighth of the balance this launch actually holds came up short of
        // `sellExactOut`'s own 0.001 ETH target below, confirmed against 46630 while drafting
        // this file.
        vm.startBroadcast();
        QuoteFeeRehearsalSwapper direct = new QuoteFeeRehearsalSwapper(IPoolManager(POOL_MANAGER));
        IERC20(WETH).transfer(address(direct), 0.3 ether);
        IERC20(tokenAddr).transfer(address(direct), IERC20(tokenAddr).balanceOf(broadcaster));
        vm.stopBroadcast();

        // Shape 3: exact-out buy. Charged in `afterSwap` (quote is unspecified: exact-output
        // buy). Refused inside the snipe window; run as its own stage specifically so the window
        // has really elapsed by the time this lands.
        vm.startBroadcast();
        BalanceDelta delta3 = direct.buyExactOut(key, WETH, 5_000_000e18, broadcaster);
        vm.stopBroadcast();
        console2.log(
            "shape 3 exact-out buy : quote in",
            _in(key, WETH, delta3),
            "token out",
            _out(key, tokenAddr, delta3)
        );

        // Shape 4: exact-out sell. Charged in `beforeSwap` (quote is specified: exact-output
        // sell). 0.0005 ETH, not the round 0.001 ETH this shape first shipped with: at this
        // launch's price, 0.001 ETH out costs more of the launch token than the whole balance
        // `_tradeExactOutputShapes` funds the swapper with (confirmed against 46630 while
        // drafting this file), and `standalonePhantomQuote` is 10% smaller than the first
        // rehearsal's, from `RefreshQuoteFeeRegistry.s.sol`'s own correction. Half the round
        // number clears it with room without changing what the shape proves.
        vm.startBroadcast();
        BalanceDelta delta4 = direct.sellExactOut(key, tokenAddr, 0.0005 ether, broadcaster);
        direct.sweep(IERC20(WETH), broadcaster);
        direct.sweep(IERC20(tokenAddr), broadcaster);
        vm.stopBroadcast();
        console2.log(
            "shape 4 exact-out sell: token in",
            _in(key, tokenAddr, delta4),
            "quote out",
            _out(key, WETH, delta4)
        );
    }

    function _topUpAndGraduate() private {
        // Top up to the real graduation threshold, corrected for the fee the way
        // `QuoteFeeGraduationFork.t.sol` derives it: gross that nets `gap` after a
        // `tradeFeeBps` cut is `ceil(gap * 10_000 / (10_000 - tradeFeeBps))`, plus a small buffer
        // so curve-rounding on the way there can never leave the raise a wei short.
        //
        // That fork case, and this formula until this line, only ever ran a `creatorTaxBps: 0`
        // launch, so `tradeFeeBps` alone was the whole cut. `_charge` takes the trade fee and the
        // creator's own tax off the same post-snipe base (see `QuoteFeeHook.sol`), so a launch
        // that sets a real `creatorTaxBps` needs the same correction run against their sum, not
        // the trade fee alone, or this undershoots the real gross by roughly `creatorTaxBps` and
        // graduation stays out of reach after a top-up that looked sufficient.
        LaunchConfig memory cfg = hook.configOf(poolId);
        uint256 totalBps = uint256(cfg.tradeFeeBps) + uint256(cfg.creatorTaxBps);
        uint256 target = hook.graduationQuote(poolId);
        uint256 raised = hook.realQuote(poolId);
        console2.log("raised after four shapes", raised, "target", target);
        console2.log("creatorTaxBps", cfg.creatorTaxBps, "totalBps", totalBps);
        if (raised < target) {
            uint256 gap = target - raised;
            uint256 correctedGross = (gap * 10_000 + (10_000 - totalBps - 1)) / (10_000 - totalBps);
            uint256 topUp = correctedGross + correctedGross / 50;
            vm.startBroadcast();
            launchRouter.swapExactIn(key, quoteIsCurrency0, topUp, 0, broadcaster, deadline);
            vm.stopBroadcast();
            console2.log("top-up exact-in buy", topUp);
        }
        console2.log("raised before graduation", hook.realQuote(poolId));
        require(hook.graduationReady(poolId), "graduation not ready after top-up");

        vm.startBroadcast();
        (uint128 permanentLiquidity, uint256 burned) = locker.settleGraduation();
        vm.stopBroadcast();
        console2.log("permanentLiquidity", permanentLiquidity);
        console2.log("burned            ", burned);
        console2.log(
            "live pool liquidity", uint256(IPoolManager(POOL_MANAGER).getLiquidity(poolId))
        );
        console2.log("locker.liquidity()  ", locker.liquidity());
        console2.log("locker.UNLOCK_AT()  ", locker.UNLOCK_AT());
    }

    function _claimAndRoute() private {
        // Claim both ledgers the router might be owed from before routing once. Permissionless
        // either way: `QuoteFeeGraduationFork.t.sol`'s own end-to-end case claims the same two
        // before checking the split.
        vm.startBroadcast();
        if (hook.owed(WETH, address(feeRouter)) > 0) hook.claimFor(WETH, address(feeRouter));
        if (locker.owed(WETH, address(feeRouter)) > 0) locker.claimFor(WETH, address(feeRouter));
        vm.stopBroadcast();

        uint256 routerHeld = IERC20(WETH).balanceOf(address(feeRouter));
        uint256 buybackBefore = IERC20(WETH).balanceOf(buyback);
        uint256 safeBefore = IERC20(WETH).balanceOf(safe);
        console2.log("router held before route()", routerHeld);

        vm.startBroadcast();
        (uint256 toBuyback, uint256 toSafe) = feeRouter.route();
        vm.stopBroadcast();

        console2.log("toBuyback", toBuyback, "toSafe", toSafe);
        console2.log("buyback balance after", IERC20(WETH).balanceOf(buyback) - buybackBefore);
        console2.log("safe balance after   ", IERC20(WETH).balanceOf(safe) - safeBefore);
        console2.log("router held after route()", IERC20(WETH).balanceOf(address(feeRouter)));
    }

    function _side(PoolKey memory k, address asset, BalanceDelta delta)
        private
        pure
        returns (int128)
    {
        return Currency.unwrap(k.currency0) == asset ? delta.amount0() : delta.amount1();
    }

    function _out(PoolKey memory k, address asset, BalanceDelta delta)
        private
        pure
        returns (uint256)
    {
        int128 amount = _side(k, asset, delta);
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }

    function _in(PoolKey memory k, address asset, BalanceDelta delta)
        private
        pure
        returns (uint256)
    {
        int128 amount = _side(k, asset, delta);
        return amount < 0 ? uint256(uint128(-amount)) : 0;
    }

    function _params(uint256 phantomQuote, uint256 graduationQuote)
        internal
        view
        returns (LaunchParams memory p)
    {
        p.name = "Quote Fee Rehearsal";
        p.symbol = "QFEEX";
        p.logo = "https://ripples.run/icon.png";
        p.description = "Testnet rehearsal of the quote-fee hook lifecycle on Robinhood chain.";
        p.curveSupply = 800_000_000e18;
        p.lpTokenSupply = 219_000_000e18;
        p.vQuoteInit = phantomQuote;
        p.vTokenInit = 1_073_000_000e18;
        p.graduationQuote = graduationQuote;
        p.lpUnlockAt = 0;
        // Zero by default, which is what the first rehearsal on 46630 ran and the only shape
        // `_topUpAndGraduate`'s correction was ever proven against before this file's own fix.
        // Set to exercise a launch whose creator actually earns something, which the registry's
        // worst-case-discounted row is sized to admit.
        p.creatorTaxBps = uint96(vm.envOr("CREATOR_TAX_BPS", uint256(0)));
    }

    function _recorded(string memory path) private view returns (address) {
        address value = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), path);
        require(value.code.length > 0, "no code at recorded address");
        return value;
    }

    function _existingLaunchRouterOrZero() private view returns (address) {
        string memory record = vm.readFile(DEPLOYMENTS);
        string memory path = ".robinhoodTestnet.quoteFeeLaunchRouter";
        if (!vm.keyExistsJson(record, path)) return address(0);
        address value = vm.parseJsonAddress(record, path);
        return value.code.length > 0 ? value : address(0);
    }

    function _load(string memory key) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(STATE), string.concat(".", key));
    }

    function _save(string memory key, address value) private {
        string memory state = vm.isFile(STATE) ? vm.readFile(STATE) : "{}";
        vm.serializeJson("state", state);
        vm.writeJson(vm.serializeAddress("state", key, value), STATE);
    }

    function _recordLaunchRouter(address launchRouter) private {
        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || !vm.envOr("WRITE_DEPLOYMENTS", true)
        ) {
            return;
        }
        vm.writeJson(
            vm.toString(launchRouter), DEPLOYMENTS, ".robinhoodTestnet.quoteFeeLaunchRouter"
        );
    }
}
