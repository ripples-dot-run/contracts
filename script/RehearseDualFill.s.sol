// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { StdAssertions } from "forge-std/StdAssertions.sol";
import { Vm } from "forge-std/Vm.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { DualFill } from "../src/DualFill.sol";
import { DualFillFactory } from "../src/DualFillFactory.sol";
import { LPLocker } from "../src/LPLocker.sol";
import { LaunchParams, TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { IDualFill } from "../src/interfaces/IDualFill.sol";
import { IDualFillFactory } from "../src/interfaces/IDualFillFactory.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// A Dual Fill's whole life on Robinhood Chain testnet, one stage per run, against the factory
/// the record names and with real keys. Each stage asserts what it did before the run ends, and
/// what the next stage needs is kept in `./cache/dual-fill-rehearsal-46630.json`.
///
///   create    the creator bonds a fill for the V9 identity with a random Dual Fill key
///   deposit   before the window ends: A joins 60%, takes 10% back and rejoins it; B joins 50%
///   open      after the window: A cannot withdraw from a full side, and the keeper opens it
///   handover  B hands the fees over and forwards what the fill holds for the creator
///   claim     A claims, and sends B's claim for B
///   abort     a second fill, 20% from A, aborted by the keeper and refunded at once
///   refund    a third fill with a 660 s deadline by default and one partial join; run once to
///             create it and again after its deadline for a stranger's refund and the bond
///
///   DUAL_FILL_STAGE              which stage to run
///   DUAL_FILL_CREATOR_KEY        the creator, as a uint256 private key
///   DUAL_FILL_CONTRIBUTOR_A_KEY  contributor A
///   DUAL_FILL_CONTRIBUTOR_B_KEY  contributor B, who is also the stranger
///   DUAL_FILL_KEEPER_KEY         the factory's keeper
///   DUAL_FILL_FACTORY            overrides the record's dualFillFactory
///   DUAL_FILL_TARGET_WEI         default 0.01 WETH
///   DUAL_FILL_DEADLINE_SECONDS   default 3600, and 660 for the refund drill
///   DUAL_FILL_PUBLIC_SECONDS     default 600
///
/// Testnet only. It spends test WETH and leaves live test markets behind it.
contract RehearseDualFill is Script, StdAssertions {
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant STATE = "./cache/dual-fill-rehearsal-46630.json";
    string internal constant DEPLOYMENTS = "./deployments.json";
    /// `createFill` holds both windows to their minimums at the block the transaction lands in,
    /// which is later than the block this run simulates against. Windows are opened from the
    /// wall clock plus this much, so one sized to its minimum is not refused on arrival.
    uint64 internal constant INCLUSION_MARGIN = 60;

    DualFillFactory internal dualFills;
    IERC20 internal weth;
    uint256 internal creatorKey;
    uint256 internal aKey;
    uint256 internal bKey;
    uint256 internal keeperKey;

    error TestnetOnly(uint256 chainId);
    error UnknownStage(string stage);
    error TooEarly(string stage, uint256 opensAt);
    error TooLate(string stage, uint256 closedAt);

    function run() external {
        if (block.chainid != RH_TESTNET) revert TestnetOnly(block.chainid);
        uint256 wallClock = vm.unixTime() / 1000;
        if (wallClock > block.timestamp) vm.warp(wallClock);

        dualFills = DualFillFactory(vm.envOr("DUAL_FILL_FACTORY", _recordedFactory()));
        weth = IERC20(dualFills.QUOTE());
        creatorKey = vm.envUint("DUAL_FILL_CREATOR_KEY");
        aKey = vm.envUint("DUAL_FILL_CONTRIBUTOR_A_KEY");
        bKey = vm.envUint("DUAL_FILL_CONTRIBUTOR_B_KEY");
        keeperKey = vm.envUint("DUAL_FILL_KEEPER_KEY");
        assertEq(vm.addr(keeperKey), dualFills.KEEPER(), "the keeper key is the factory's keeper");
        console2.log("dualFillFactory", address(dualFills));
        console2.log("creator", vm.addr(creatorKey));
        console2.log("contributor A", vm.addr(aKey));
        console2.log("contributor B", vm.addr(bKey));
        console2.log("keeper", vm.addr(keeperKey));

        string memory stage = vm.envString("DUAL_FILL_STAGE");
        bytes32 id = keccak256(bytes(stage));
        if (id == keccak256("create")) return _create();
        if (id == keccak256("deposit")) return _deposit();
        if (id == keccak256("open")) return _open();
        if (id == keccak256("handover")) return _handover();
        if (id == keccak256("claim")) return _claim();
        if (id == keccak256("abort")) return _abort();
        if (id == keccak256("refund")) return _refund();
        revert UnknownStage(stage);
    }

    function _create() private {
        (DualFill fill, bytes32 dualFillKey) = _createFill("create", 3600);
        _save("fill", address(fill));
        _save("dualFillKey", vm.toString(dualFillKey));
        console2.log("fill", address(fill));
        console2.log("publicUntil", fill.PUBLIC_UNTIL());
        console2.log("deadline", fill.DEADLINE());
    }

    function _deposit() private {
        DualFill fill = DualFill(_load(".fill"));
        if (block.timestamp >= fill.PUBLIC_UNTIL()) revert TooLate("deposit", fill.PUBLIC_UNTIL());
        uint256 target = fill.TARGET();

        uint256 ceiling = (target * fill.MAX_WALLET_SHARE_BPS()) / 10_000;
        _join(aKey, fill, ceiling);
        vm.startBroadcast(aKey);
        fill.withdraw((target * 10) / 100);
        vm.stopBroadcast();
        _join(aKey, fill, (target * 10) / 100);
        _join(bKey, fill, ceiling);

        vm.prank(vm.addr(aKey));
        try fill.deposit(1) {
            fail("A went above its share of the target inside the window");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IDualFill.WalletLimitReached.selector, "A: WalletLimitReached");
        }
        assertEq(fill.totalDeposited(), 2 * ceiling, "each at its ceiling");
        assertEq(uint8(fill.status()), uint8(IDualFill.Status.Filling), "still inside the window");
        assertEq(fill.remaining(), target - 2 * ceiling);
    }

    function _open() private {
        DualFill fill = DualFill(_load(".fill"));
        if (block.timestamp < fill.PUBLIC_UNTIL()) revert TooEarly("open", fill.PUBLIC_UNTIL());
        vm.recordLogs();
        _join(bKey, fill, fill.remaining());
        assertEq(_count(vm.getRecordedLogs(), address(fill), IDualFill.Filled.selector), 1);
        assertEq(
            uint8(fill.status()), uint8(IDualFill.Status.Full), "past the window B closed the gap"
        );

        vm.prank(vm.addr(aKey));
        try fill.withdraw(1) {
            fail("a full side let A withdraw");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IDualFill.NotFilling.selector, "A's withdrawal: NotFilling");
        }

        LaunchParams memory p = _params();
        assertEq(keccak256(abi.encode(p)), fill.PARAMS_HASH(), "the params the fill committed to");
        TokenLaunchFactory launchFactory = TokenLaunchFactory(fill.LAUNCH_FACTORY());
        uint256 launches = launchFactory.launchCount();
        uint256 fee = launchFactory.launchFee();
        address creator = vm.addr(creatorKey);
        uint256 creatorBefore = weth.balanceOf(creator);

        vm.recordLogs();
        vm.startBroadcast(keeperKey);
        (address token, address locker) = fill.open(p);
        vm.stopBroadcast();

        assertEq(_count(vm.getRecordedLogs(), address(fill), IDualFill.Opened.selector), 1);
        assertGt(fill.tokensForFill(), 0);
        assertEq(fill.quoteBack(), 0, "exactly the target was spent");
        assertEq(weth.balanceOf(creator) - creatorBefore, fill.FEE_BUDGET() - fee, "unspent bond");
        _assertCreatorOfRecord(fill, launchFactory, launches, locker);

        _save("token", token);
        _save("locker", locker);
        console2.log("token", token);
        console2.log("locker", locker);
        console2.log("tokensForFill", fill.tokensForFill());
        console2.log("quoteBack", fill.quoteBack());
    }

    function _handover() private {
        DualFill fill = DualFill(_load(".fill"));
        address creator = vm.addr(creatorKey);
        address hook = LPLocker(fill.locker()).HOOK();

        vm.recordLogs();
        vm.startBroadcast(bKey);
        fill.handOverFees();
        (uint256 quote, uint256 tokens) = fill.claimFees();
        vm.stopBroadcast();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(fill), IDualFill.FeesHandedOver.selector), 1);
        assertEq(_count(logs, address(fill), IDualFill.CreatorFeesForwarded.selector), 1);
        assertEq(
            ILaunchHook(hook).configOf(PoolId.wrap(fill.poolId())).creatorFeeRecipient,
            creator,
            "the hook pays the creator from here on"
        );
        console2.log("forwarded quote", quote);
        console2.log("forwarded tokens", tokens);
    }

    function _claim() private {
        DualFill fill = DualFill(_load(".fill"));
        IERC20 token = IERC20(fill.token());

        vm.startBroadcast(aKey);
        (uint256 aTokens, uint256 aQuote) = fill.claim();
        (uint256 bTokens, uint256 bQuote) = fill.claimFor(vm.addr(bKey));
        vm.stopBroadcast();

        assertEq(aTokens + bTokens, fill.tokensForFill(), "token claims sum to the pool");
        assertEq(aQuote + bQuote, fill.quoteBack(), "quote claims sum to what came back");
        assertEq(token.balanceOf(address(fill)), 0, "the fill holds no token");
        assertEq(weth.balanceOf(address(fill)), 0, "and no quote");
        console2.log("A tokens", aTokens);
        console2.log("B tokens", bTokens);
    }

    function _abort() private {
        (DualFill fill,) = _createFill("abort", 3600);
        uint256 target = fill.TARGET();
        address a = vm.addr(aKey);
        _join(aKey, fill, (target * 20) / 100);

        vm.startBroadcast(keeperKey);
        fill.abort();
        vm.stopBroadcast();
        assertEq(uint8(fill.status()), uint8(IDualFill.Status.Cancelled));

        address creator = vm.addr(creatorKey);
        uint256 aBefore = weth.balanceOf(a);
        uint256 creatorBefore = weth.balanceOf(creator);
        vm.startBroadcast(aKey);
        fill.refundFor(a);
        fill.returnFeeBudget();
        vm.stopBroadcast();
        assertEq(weth.balanceOf(a) - aBefore, (target * 20) / 100, "A's refund, at once");
        assertEq(weth.balanceOf(creator) - creatorBefore, fill.FEE_BUDGET(), "and the bond");
        _save("abortFill", address(fill));
        console2.log("abortFill", address(fill));
    }

    /// Two runs of one stage, because the second half has to wait for the deadline.
    function _refund() private {
        string memory state = vm.isFile(STATE) ? vm.readFile(STATE) : "{}";
        if (!vm.keyExistsJson(state, ".refundFill")) {
            (DualFill created,) = _createFill("refund", 660);
            _join(aKey, created, (created.TARGET() * 25) / 100);
            _save("refundFill", address(created));
            console2.log("refundFill", address(created));
            console2.log("run DUAL_FILL_STAGE=refund again from", created.DEADLINE());
            return;
        }

        DualFill fill = DualFill(_load(".refundFill"));
        if (block.timestamp < fill.DEADLINE()) revert TooEarly("refund", fill.DEADLINE());
        address a = vm.addr(aKey);
        address creator = vm.addr(creatorKey);
        uint256 owed = fill.depositOf(a);
        uint256 aBefore = weth.balanceOf(a);
        uint256 creatorBefore = weth.balanceOf(creator);

        vm.startBroadcast(bKey);
        fill.refundFor(a);
        fill.returnFeeBudget();
        vm.stopBroadcast();

        assertEq(weth.balanceOf(a) - aBefore, owed, "A's deposit came back");
        assertEq(weth.balanceOf(creator) - creatorBefore, fill.FEE_BUDGET(), "and the bond");
        assertEq(weth.balanceOf(address(fill)), 0);
        vm.prank(vm.addr(bKey));
        try fill.returnFeeBudget() {
            fail("the bond came back twice");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IDualFill.AlreadySettled.selector, "AlreadySettled");
        }
    }

    function _createFill(string memory label, uint256 defaultDeadlineSeconds)
        private
        returns (DualFill fill, bytes32 dualFillKey)
    {
        address creator = vm.addr(creatorKey);
        uint256 target = vm.envOr("DUAL_FILL_TARGET_WEI", uint256(0.01e18));
        uint256 bond = 2 * TokenLaunchFactory(dualFills.LAUNCH_FACTORY()).launchFee();
        uint64 opensFrom = uint64(block.timestamp) + INCLUSION_MARGIN;
        uint64 deadline =
            opensFrom + uint64(vm.envOr("DUAL_FILL_DEADLINE_SECONDS", defaultDeadlineSeconds));
        uint64 publicUntil = opensFrom + uint64(vm.envOr("DUAL_FILL_PUBLIC_SECONDS", uint256(600)));
        dualFillKey =
            keccak256(abi.encode("ripples dual fill rehearsal", label, vm.unixTime(), creator));
        LaunchParams memory p = _params();

        vm.recordLogs();
        vm.startBroadcast(creatorKey);
        weth.approve(address(dualFills), bond);
        fill = DualFill(
            dualFills.createFill(p, dualFillKey, target, deadline, publicUntil, false, bond)
        );
        vm.stopBroadcast();

        assertEq(dualFills.fillOf(creator, dualFillKey), address(fill), "fillOf finds it");
        IDualFill.Terms memory t = fill.terms();
        assertEq(t.creator, creator);
        assertEq(t.dualFillKey, dualFillKey);
        assertEq(t.target, target);
        assertEq(t.deadline, deadline);
        assertEq(t.publicUntil, publicUntil);
        assertFalse(t.openAlone);
        assertEq(t.feeBudget, bond);
        assertEq(t.paramsHash, keccak256(abi.encode(p)));
        assertEq(t.keeper, dualFills.KEEPER());
        assertEq(t.quote, address(weth));
        assertEq(weth.balanceOf(address(fill)), bond, "the bond is in the fill");
        _assertAnnounced(vm.getRecordedLogs(), fill, p);
    }

    function _assertAnnounced(Vm.Log[] memory logs, DualFill fill, LaunchParams memory p) private {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(dualFills)) continue;
            assertEq(logs[i].topics[0], IDualFillFactory.FillCreated.selector);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(fill)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(fill.CREATOR()))));
            assertEq(logs[i].topics[3], fill.DUAL_FILL_KEY());
            assertEq(
                logs[i].data,
                abi.encode(
                    fill.TARGET(),
                    fill.DEADLINE(),
                    fill.PUBLIC_UNTIL(),
                    fill.OPEN_ALONE(),
                    fill.FEE_BUDGET(),
                    fill.PARAMS_HASH(),
                    p
                ),
                "FillCreated carries the terms and the params"
            );
            return;
        }
        fail("no FillCreated from the factory");
    }

    function _assertCreatorOfRecord(
        DualFill fill,
        TokenLaunchFactory launchFactory,
        uint256 index,
        address locker
    ) private view {
        (,, address hook, address creatorOfRecord) = launchFactory.allLaunches(index);
        assertEq(creatorOfRecord, address(fill), "I9: the registry names the fill");
        assertEq(LPLocker(locker).CREATOR(), address(fill), "I9: so does the locker");
        assertEq(
            ILaunchHook(hook).configOf(PoolId.wrap(fill.poolId())).creatorFeeRecipient,
            address(fill),
            "I9: and the hook"
        );
    }

    function _join(uint256 key, DualFill fill, uint256 amount) private {
        vm.startBroadcast(key);
        weth.approve(address(fill), amount);
        fill.deposit(amount);
        vm.stopBroadcast();
    }

    /// The §4.5 V9 identity against the record's quote row.
    function _params() private view returns (LaunchParams memory p) {
        TokenLaunchFactory launchFactory = TokenLaunchFactory(dualFills.LAUNCH_FACTORY());
        IQuoteRegistry.QuoteEconomics memory e =
            IQuoteRegistry(launchFactory.quoteRegistry()).quoteEconomics(address(weth));
        p.name = "Dual Fill Rehearsal";
        p.symbol = "DUAL";
        p.curveSupply = 800_000_000e18;
        p.lpTokenSupply = 219_000_000e18;
        p.vQuoteInit = e.standalonePhantomQuote;
        p.vTokenInit = 1_073_000_000e18;
        p.graduationQuote = e.graduationThreshold;
        p.quote = address(weth);
        p.logo =
            "https://api.ripples.run/v1/launch-assets/images/0000000000000000000000000000000000000000000000000000000000000000.png";
        p.description = "One coin on two chains.";
        p.website = "https://ripples.run";
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic)
        private
        pure
        returns (uint256 n)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) n++;
        }
    }

    function _recordedFactory() private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), ".robinhoodTestnet.dualFillFactory");
    }

    function _load(string memory path) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(STATE), path);
    }

    function _save(string memory key, address value) private {
        _save(key, vm.toString(value));
    }

    function _save(string memory key, string memory value) private {
        string memory state = vm.isFile(STATE) ? vm.readFile(STATE) : "{}";
        vm.serializeJson("state", state);
        vm.writeJson(vm.serializeString("state", key, value), STATE);
    }
}
