// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { CustomRevert } from "v4-core/src/libraries/CustomRevert.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { LPLocker } from "../src/LPLocker.sol";
import { LaunchRouter } from "../src/LaunchRouter.sol";
import { ILaunchRouter } from "../src/interfaces/ILaunchRouter.sol";
import { LaunchParams } from "../src/TokenLaunchFactory.sol";
import { QuoteFeeFactory } from "../src/QuoteFeeFactory.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";
import { IAllowanceTransfer } from "../src/interfaces/IAllowanceTransfer.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { QuoteFeeHook } from "../src/hook/QuoteFeeHook.sol";
import { QuoteFeeRehearsalSwapper } from "./RehearseQuoteFee.s.sol";

/// Three mistakes a real trader, or a stray integration, could make against the quote-fee rail,
/// run for real on 46630 rather than argued about: an order too large for the curve to fill
/// whole, an exact-output buy inside the opening tax window, and a swap sent through the OLD
/// `LaunchRouter` (keyed to `LaunchHook`) against a `QuoteFeeHook` pool.
///
/// Two stages, the same reason `RehearseQuoteFee.s.sol` splits into `launch` and `graduate`: the
/// exact-output check only means anything inside `QuoteFeeFactory.SNIPE_WINDOW` (3 seconds) of
/// the launch's own transaction, while the oversized-buy check needs that same window closed.
/// `_charge` prices a buy off the swap's full nominal specified amount, not off whatever the
/// curve can actually absorb (`grossQuote` in `_chargeSpecifiedQuote` is `params.amountSpecified`
/// itself), so inside the window an oversized exact-in buy is mostly opening tax before the
/// curve ever sees it and never stresses the curve's own range end at all; confirmed against
/// 46630 while drafting this file, where a 10 ETH ask landed a 99% tax and left only 0.099 ETH
/// for the curve to price. Run `trade` only after `launch` has landed and the window has passed.
///
///   QF_STAGE=launch   create the mistakes launch and immediately attempt mistake 2.
///   QF_STAGE=trade    attempt mistakes 1 and 3 against the launch `launch` created.
contract QuoteFeeMistakes is Script {
    uint256 internal constant RH_TESTNET = 46630;
    address internal constant WETH = 0x1F852eF3Afa13156b807204d838BbB46B4b452eb;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    string internal constant DEPLOYMENTS = "./deployments.json";
    string internal constant STATE = "./cache/quote-fee-mistakes-46630.json";

    address private broadcaster;
    address private oldLaunchRouter;
    PoolKey private key;
    bool private quoteIsCurrency0;

    function run() external {
        require(block.chainid == RH_TESTNET, "robinhood testnet only");
        broadcaster = tx.origin;
        oldLaunchRouter = _recorded(".robinhoodTestnet.launchRouter");

        string memory stage = vm.envOr("QF_STAGE", string("launch"));
        bytes32 stageHash = keccak256(bytes(stage));
        if (stageHash == keccak256(bytes("launch"))) {
            _stageLaunch();
        } else if (stageHash == keccak256(bytes("trade"))) {
            _stageTrade();
        } else {
            revert("QF_STAGE must be launch or trade");
        }
    }

    function _stageLaunch() private {
        QuoteFeeHook hook = QuoteFeeHook(payable(_recorded(".robinhoodTestnet.quoteFeeHook")));
        QuoteFeeFactory factory = QuoteFeeFactory(_recorded(".robinhoodTestnet.quoteFeeFactory"));
        QuoteRegistry registry = QuoteRegistry(_recorded(".robinhoodTestnet.quoteFeeRegistry"));
        IQuoteRegistry.QuoteEconomics memory e = registry.quoteEconomics(WETH);

        vm.startBroadcast();
        LaunchRouter newRouter = new LaunchRouter(
            IPoolManager(POOL_MANAGER), ILaunchHook(address(hook)), IAllowanceTransfer(PERMIT2)
        );
        IERC20(WETH).approve(address(factory), type(uint256).max);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2)
            .approve(WETH, address(newRouter), type(uint160).max, type(uint48).max);

        LaunchParams memory p = _params(e.standalonePhantomQuote, e.graduationThreshold);
        (, address lockerAddr) = factory.createLaunch(p);
        console2.log("mistakes launch locker", lockerAddr);

        PoolKey memory k = LPLocker(lockerAddr).poolKey();

        // Mistake 2 lands in this same broadcast, as early as possible inside the 3-second
        // window: fund a swapper and try the refused shape immediately.
        QuoteFeeRehearsalSwapper direct = new QuoteFeeRehearsalSwapper(IPoolManager(POOL_MANAGER));
        IERC20(WETH).transfer(address(direct), 1 ether);
        vm.stopBroadcast();

        _mistake2ExactOutputInsideSnipeWindow(direct, k);

        _save("locker", lockerAddr);
        _save("newRouter", address(newRouter));
    }

    function _stageTrade() private {
        address lockerAddr = _load("locker");
        LaunchRouter newRouter = LaunchRouter(_load("newRouter"));
        key = LPLocker(lockerAddr).poolKey();
        quoteIsCurrency0 = Currency.unwrap(key.currency0) == WETH;

        _mistake1OversizedBuy(newRouter);
        _mistake3OldRouterAgainstNewPool();
    }

    /// Mistake 2: an exact-output buy while the opening tax is still live. `QuoteFeeHook.
    /// beforeSwap` refuses it outright (`ExactOutputClosed`) rather than pricing it, the same
    /// refusal `LaunchHook` always carried; see that function's own doc for why lifting the fee
    /// off the launch token did not lift this.
    ///
    /// Sent as a plain call, never wrapped in `vm.startBroadcast()`: a call queued for broadcast
    /// that reverts is not something `try`/`catch` can absorb from forge's own side. The script's
    /// `catch` handles it fine, but forge separately replays every broadcast-recorded call on its
    /// own, outside that `catch`, to estimate its gas, and aborts the whole run the moment one of
    /// them reverts there, confirmed against 46630 while drafting this file, where the run
    /// printed "mistake 2 ok" and then failed anyway with "Simulated execution failed" once forge
    /// reached that replay. A plain call still executes against this run's real, live chain state
    /// (the launch `_stageLaunch` just broadcast for real, read over the same RPC), it is only
    /// never itself sent as a transaction, which a call refused on purpose has no need to be.
    function _mistake2ExactOutputInsideSnipeWindow(
        QuoteFeeRehearsalSwapper direct,
        PoolKey memory k
    ) private {
        try direct.buyExactOut(k, WETH, 1_000_000e18, broadcaster) {
            console2.log(
                "MISTAKE 2 FAILED: an exact-output buy inside the snipe window was not refused"
            );
        } catch (bytes memory reason) {
            bytes4 inner = _unwrap(reason);
            console2.log(
                inner == QuoteFeeHook.ExactOutputClosed.selector
                    ? "mistake 2 ok: exact-output buy inside the snipe window reverted ExactOutputClosed"
                    : "MISTAKE 2 FAILED: it reverted, but not with ExactOutputClosed"
            );
            console2.logBytes(reason);
        }
    }

    /// Mistake 1: an exact-input buy for far more than the curve has left to sell. `LaunchRouter`
    /// fills to the curve's range end and pulls only what it actually spent
    /// (`LaunchRouter.unlockCallback`), so this needs balance for the curve's own remaining
    /// capacity plus the trade fee on the full 10 ETH ask (charged on the nominal amount
    /// regardless of the partial fill; see this file's own top-level doc), not for 10 ETH itself.
    function _mistake1OversizedBuy(LaunchRouter newRouter) private {
        uint256 requested = 10 ether;
        vm.startBroadcast();
        (uint256 spent, uint256 received) = newRouter.swapExactIn(
            key, quoteIsCurrency0, requested, 0, broadcaster, block.timestamp + 3600
        );
        vm.stopBroadcast();
        console2.log("mistake 1: requested", requested, "spent", spent);
        console2.log("mistake 1: tokens received", received);
        if (spent < requested && received > 0) {
            console2.log("mistake 1 ok: the oversized buy partially filled rather than reverting");
        } else {
            console2.log("MISTAKE 1 FAILED: the oversized buy did not partially fill as expected");
        }
    }

    /// Mistake 3: the OLD `LaunchRouter`, keyed to `LaunchHook`, against a pool keyed to
    /// `QuoteFeeHook`. `swapExactIn` checks the pool key's own hook against its immutable `HOOK`
    /// before it reads anything else, so this reverts `NotOurPool` unwrapped, straight out of the
    /// router itself, without the manager ever seeing the call. A plain call, not a broadcast, for
    /// the same reason mistake 2 is one.
    function _mistake3OldRouterAgainstNewPool() private {
        try LaunchRouter(oldLaunchRouter)
            .swapExactIn(
                key, quoteIsCurrency0, 0.01 ether, 0, broadcaster, block.timestamp + 3600
            ) {
            console2.log("MISTAKE 3 FAILED: the old LaunchRouter accepted a QuoteFeeHook pool");
        } catch (bytes memory reason) {
            bool expected =
                reason.length >= 4 && bytes4(reason) == ILaunchRouter.NotOurPool.selector;
            console2.log(
                expected
                    ? "mistake 3 ok: the old LaunchRouter refused the new pool with NotOurPool"
                    : "MISTAKE 3 FAILED: it reverted, but not with NotOurPool"
            );
            console2.logBytes(reason);
        }
    }

    /// `CustomRevert.WrappedError(address target, bytes4 selector, bytes reason, bytes details)`:
    /// the manager wraps a hook's revert in this shape, and `selector` names which hook callback
    /// reverted (`beforeSwap.selector` here, on every hook alike), not the revert itself. The
    /// original error is `reason`, the hook's own raw revert data, so decoding the tuple and
    /// reading the first four bytes of that field is what actually recovers `ExactOutputClosed`.
    /// Confirmed by hand against 46630 while drafting this file: `selector` read 0x575e24b4
    /// (`beforeSwap.selector`), and only `reason` read 0x591d0963 (`ExactOutputClosed.selector`).
    /// Returns zero when `reason` is not a `WrappedError` at all, which never equals a real
    /// error's selector.
    function _unwrap(bytes memory reason) private pure returns (bytes4 inner) {
        if (reason.length < 4 || bytes4(reason) != CustomRevert.WrappedError.selector) {
            return bytes4(0);
        }
        bytes memory payload = new bytes(reason.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = reason[i + 4];
        }
        (,, bytes memory innerReason,) = abi.decode(payload, (address, bytes4, bytes, bytes));
        if (innerReason.length >= 4) inner = bytes4(innerReason);
    }

    function _params(uint256 phantomQuote, uint256 graduationQuote)
        internal
        pure
        returns (LaunchParams memory p)
    {
        p.name = "Quote Fee Mistakes";
        p.symbol = "QFEEMX";
        p.logo = "https://ripples.run/icon.png";
        p.description = "Testnet launch created only to be traded against incorrectly.";
        p.curveSupply = 800_000_000e18;
        p.lpTokenSupply = 219_000_000e18;
        p.vQuoteInit = phantomQuote;
        p.vTokenInit = 1_073_000_000e18;
        p.graduationQuote = graduationQuote;
        p.lpUnlockAt = 0;
    }

    function _recorded(string memory path) private view returns (address) {
        address value = vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), path);
        require(value.code.length > 0, "no code at recorded address");
        return value;
    }

    function _load(string memory k) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(STATE), string.concat(".", k));
    }

    function _save(string memory k, address value) private {
        string memory state = vm.isFile(STATE) ? vm.readFile(STATE) : "{}";
        vm.serializeJson("mistakesState", state);
        vm.writeJson(vm.serializeAddress("mistakesState", k, value), STATE);
    }
}
