// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { StdAssertions } from "forge-std/StdAssertions.sol";
import { Vm } from "forge-std/Vm.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Charter } from "../src/AgentTreasury.sol";
import { AllocationVesting } from "../src/AllocationVesting.sol";
import { Collection721, CollectionParams, Mode } from "../src/Collection721.sol";
import { LPLocker } from "../src/LPLocker.sol";
import { LaunchRouter } from "../src/LaunchRouter.sol";
import { LaunchParams, LinkedParams, TokenLaunchFactory } from "../src/TokenLaunchFactory.sol";
import { ILaunchHook } from "../src/hook/interfaces/ILaunchHook.sol";
import { IAllowanceTransfer } from "../src/interfaces/IAllowanceTransfer.sol";
import { IDualFill } from "../src/interfaces/IDualFill.sol";
import { FillTerms, IDualFillAgentFactory } from "../src/interfaces/IDualFillAgentFactory.sol";
import { IDualFillAgentTreasury } from "../src/interfaces/IDualFillAgentTreasury.sol";
import { IDualFillFactory } from "../src/interfaces/IDualFillFactory.sol";
import { ILaunchRouter } from "../src/interfaces/ILaunchRouter.sol";
import { ILinkedDualFill } from "../src/interfaces/ILinkedDualFill.sol";
import { ILinkedDualFillFactory } from "../src/interfaces/ILinkedDualFillFactory.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// The agent and combined Dual Fill shapes on Robinhood Chain testnet, one stage per run, against
/// the factories the record names and with real keys. Each stage asserts what it did before the
/// run ends, and what the next stage needs is kept in `./cache/dual-fill-shapes-46630.json`.
/// Refusals are simulated as the named account rather than sent, so a stage spends gas only on
/// what should land.
///
///   agent-create    the creator funds an agent Dual Fill; the creator as its operator is refused
///   agent-deposit   before the window ends: A and B each join their quarter, A cannot join more,
///                   and the operator cannot buy yet
///   agent-open      after the window: B closes the gap, the keeper opens it, and the bond
///                   remainder is the agent's
///   agent-spend     the operator buys, pays C, and meets each of its limits
///   agent-income    B hands the fees over and trades; the income is claimed and half of it sold
///   agent-retire    the creator retires the operator; the agent's income still comes in
///   agent-return    a second agent Dual Fill, 20% from A, aborted, and its runway returned
///   linked-create   the creator bonds a combined Dual Fill for the V23 launch
///   linked-deposit  before the window ends: A and B each join their quarter, A cannot join more
///   linked-open     after the window: B closes the gap, and the keeper opens it with a
///                   16,000,000 gas limit
///   linked-mint     A mints two pieces and B one
///   linked-fees     B forwards the fill's income to the creator
///   linked-claim    A claims, and sends B's claim for B
///
///   DF_STAGE                which stage to run
///   DF_CREATOR_KEY          the creator, as a uint256 private key
///   DF_CONTRIBUTOR_A_KEY    contributor A
///   DF_CONTRIBUTOR_B_KEY    contributor B, who is also the stranger
///   DF_KEEPER_KEY           the factories' keeper
///   DF_OPERATOR_KEY         the agent's operator
///   DF_AGENT_FACTORY        overrides the record's dualFillAgentFactory
///   DF_LINKED_FACTORY       overrides the record's linkedDualFillFactory
///   DF_TARGET_WEI           default 0.01 WETH
///   DF_DEADLINE_SECONDS     default 3600
///   DF_PUBLIC_SECONDS       default 600
///
/// Testnet only. It spends test WETH and leaves live test markets behind it.
contract RehearseDualFillShapes is Script, StdAssertions {
    uint256 internal constant RH_TESTNET = 46630;
    string internal constant STATE = "./cache/dual-fill-shapes-46630.json";
    string internal constant DEPLOYMENTS = "./deployments.json";
    /// `createFill` holds both windows to their minimums at the block the transaction lands in,
    /// which is later than the block this run simulates against.
    uint64 internal constant INCLUSION_MARGIN = 60;
    uint256 internal constant RUNWAY = 0.05e18;
    uint128 internal constant PER_CALL = 0.005e18;
    uint128 internal constant DAILY = 0.02e18;
    uint128 internal constant DAILY_SELL = 1_000_000e18;
    address internal constant PAYEE_C = 0x4760838dAfDb625D3547301979c6271197848a66;
    uint256 internal constant OPEN_GAS = 16_000_000;
    string internal constant IMAGE =
        "https://api.ripples.run/v1/launch-assets/images/0000000000000000000000000000000000000000000000000000000000000000.png";
    string internal constant BASE_URI =
        "https://api.ripples.run/v1/launch-assets/f/AAECAwQFBgcICQoLDA0ODw/";
    bytes32 internal constant V23_PARAMS_HASH =
        0x183a02901a5e1028d6450c9ab520739812347702a9fa726a83e51a9b0f3db760;

    IERC20 internal weth;
    uint256 internal creatorKey;
    uint256 internal aKey;
    uint256 internal bKey;
    uint256 internal keeperKey;
    uint256 internal operatorKey;

    error TestnetOnly(uint256 chainId);
    error UnknownStage(string stage);
    error TooEarly(string stage, uint256 opensAt);
    error TooLate(string stage, uint256 closedAt);

    function run() external {
        if (block.chainid != RH_TESTNET) revert TestnetOnly(block.chainid);
        uint256 wallClock = vm.unixTime() / 1000;
        if (wallClock > block.timestamp) vm.warp(wallClock);

        weth = IERC20(_recorded(".robinhoodTestnet.defaultQuote"));
        creatorKey = vm.envUint("DF_CREATOR_KEY");
        aKey = vm.envUint("DF_CONTRIBUTOR_A_KEY");
        bKey = vm.envUint("DF_CONTRIBUTOR_B_KEY");
        keeperKey = vm.envUint("DF_KEEPER_KEY");
        operatorKey = vm.envUint("DF_OPERATOR_KEY");
        console2.log("creator", vm.addr(creatorKey));
        console2.log("contributor A", vm.addr(aKey));
        console2.log("contributor B", vm.addr(bKey));
        console2.log("keeper", vm.addr(keeperKey));
        console2.log("operator", vm.addr(operatorKey));
        console2.log("payee C", PAYEE_C);

        string memory stage = vm.envString("DF_STAGE");
        bytes32 id = keccak256(bytes(stage));
        if (id == keccak256("agent-create")) return _agentCreate();
        if (id == keccak256("agent-deposit")) return _agentDeposit();
        if (id == keccak256("agent-open")) return _agentOpen();
        if (id == keccak256("agent-spend")) return _agentSpend();
        if (id == keccak256("agent-income")) return _agentIncome();
        if (id == keccak256("agent-retire")) return _agentRetire();
        if (id == keccak256("agent-return")) return _agentReturn();
        if (id == keccak256("linked-create")) return _linkedCreate();
        if (id == keccak256("linked-deposit")) return _linkedDeposit();
        if (id == keccak256("linked-open")) return _linkedOpen();
        if (id == keccak256("linked-mint")) return _linkedMint();
        if (id == keccak256("linked-fees")) return _linkedFees();
        if (id == keccak256("linked-claim")) return _linkedClaim();
        revert UnknownStage(stage);
    }

    function _agentCreate() private {
        (IDualFillAgentTreasury treasury, IDualFill fill) = _createAgent("agent-create");
        _save("agentTreasury", address(treasury));
        _save("agentFill", address(fill));
        console2.log("treasury", address(treasury));
        console2.log("fill", address(fill));
        console2.log("publicUntil", fill.PUBLIC_UNTIL());
        console2.log("deadline", fill.DEADLINE());
    }

    function _agentDeposit() private {
        IDualFill fill = IDualFill(_load(".agentFill"));
        IDualFillAgentTreasury treasury = IDualFillAgentTreasury(_load(".agentTreasury"));
        if (block.timestamp >= fill.PUBLIC_UNTIL()) {
            revert TooLate("agent-deposit", fill.PUBLIC_UNTIL());
        }
        _joinQuarters(address(fill));
        _expectRefusal(
            vm.addr(operatorKey),
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.buy, (PER_CALL, 1, block.timestamp + 300)),
            IDualFillAgentTreasury.NotOpened.selector
        );
    }

    function _agentOpen() private {
        IDualFill fill = IDualFill(_load(".agentFill"));
        address treasury = _load(".agentTreasury");
        if (block.timestamp < fill.PUBLIC_UNTIL()) {
            revert TooEarly("agent-open", fill.PUBLIC_UNTIL());
        }
        _closeGap(address(fill));
        TokenLaunchFactory launchFactory = TokenLaunchFactory(fill.LAUNCH_FACTORY());
        uint256 fee = launchFactory.launchFee();
        uint256 before = weth.balanceOf(treasury);
        LaunchParams memory p = _tokenParams(fill.LAUNCH_FACTORY());
        assertEq(keccak256(abi.encode(p)), fill.PARAMS_HASH(), "the params the fill committed to");

        vm.startBroadcast(keeperKey);
        (address token, address locker) = fill.open(p);
        vm.stopBroadcast();

        assertEq(uint8(fill.status()), uint8(IDualFill.Status.Opened));
        assertEq(weth.balanceOf(treasury) - before, fill.FEE_BUDGET() - fee, "the bond remainder");
        assertEq(LPLocker(locker).CREATOR(), address(fill), "the fill is the launch's creator");
        _save("agentToken", token);
        _save("agentLocker", locker);
        console2.log("token", token);
        console2.log("locker", locker);
        console2.log("openedAt", fill.openedAt());
        console2.log("tokensForFill", fill.tokensForFill());
    }

    function _agentSpend() private {
        IDualFill fill = IDualFill(_load(".agentFill"));
        IDualFillAgentTreasury treasury = IDualFillAgentTreasury(_load(".agentTreasury"));
        uint256 opensAt = fill.openedAt() + TokenLaunchFactory(fill.LAUNCH_FACTORY()).SNIPE_WINDOW();
        if (block.timestamp < opensAt) revert TooEarly("agent-spend", opensAt);
        address operator = vm.addr(operatorKey);
        uint256 deadline = block.timestamp + 300;

        _operatorBuy(treasury, 0.004e18);
        _assertLeft(treasury, 0.016e18);
        _expectRefusal(
            operator,
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.buy, (0.006e18, 1, deadline)),
            IDualFillAgentTreasury.OverCallSpend.selector
        );
        for (uint256 i = 1; i <= 3; i++) {
            _operatorBuy(treasury, PER_CALL);
            _assertLeft(treasury, 0.016e18 - i * PER_CALL);
        }
        _expectRefusal(
            operator,
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.buy, (PER_CALL, 1, deadline)),
            IDualFillAgentTreasury.OverDailySpend.selector
        );

        uint256 payeeBefore = weth.balanceOf(PAYEE_C);
        vm.startBroadcast(operatorKey);
        treasury.pay(PAYEE_C, 0.001e18);
        vm.stopBroadcast();
        assertEq(weth.balanceOf(PAYEE_C) - payeeBefore, 0.001e18, "C was paid");
        _assertLeft(treasury, 0);

        _expectRefusal(
            operator,
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.pay, (vm.addr(aKey), 0.001e18)),
            IDualFillAgentTreasury.NotPayee.selector
        );
        _expectRefusal(
            operator,
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.sell, (1, 0, deadline)),
            IDualFillAgentTreasury.SellsIncomeOnly.selector
        );
        console2.log("boughtTokens", treasury.boughtTokens());
    }

    function _agentIncome() private {
        IDualFill fill = IDualFill(_load(".agentFill"));
        IDualFillAgentTreasury treasury = IDualFillAgentTreasury(_load(".agentTreasury"));
        LPLocker locker = LPLocker(_load(".agentLocker"));
        bytes memory claimsBefore = _claims(fill);

        vm.startBroadcast(bKey);
        fill.handOverFees();
        vm.stopBroadcast();
        _routerBuy(bKey, locker, treasury.ROUTER(), 0.005e18);
        vm.startBroadcast(aKey);
        fill.claimFees();
        vm.stopBroadcast();
        vm.startBroadcast(bKey);
        (uint256 quoteIn, uint256 tokensIn) = treasury.claimFees();
        vm.stopBroadcast();

        uint256 sellable = treasury.sellableTokens();
        IERC20 token = IERC20(treasury.token());
        assertEq(sellable, token.balanceOf(address(treasury)) - treasury.boughtTokens());
        assertGt(sellable, 0, "the market's income is booked as sellable");
        console2.log("claimed quote", quoteIn);
        console2.log("claimed tokens", tokensIn);
        console2.log("sellableTokens", sellable);

        vm.startBroadcast(operatorKey);
        (uint256 sold, uint256 received) = treasury.sell(sellable / 2, 0, block.timestamp + 300);
        vm.stopBroadcast();
        assertEq(sold, sellable / 2, "half of it sold");
        (, uint256 sellLeft,) = treasury.remainingToday();
        assertEq(sellLeft, DAILY_SELL - sold, "inside the daily sell limit");
        console2.log("sold", sold);
        console2.log("received", received);

        uint256 left = treasury.sellableTokens();
        _expectRefusal(
            vm.addr(operatorKey),
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.sell, (left + 1, 0, block.timestamp + 300)),
            IDualFillAgentTreasury.SellsIncomeOnly.selector
        );
        assertEq(_claims(fill), claimsBefore, "contributors' claims unchanged");
    }

    function _agentRetire() private {
        IDualFill fill = IDualFill(_load(".agentFill"));
        IDualFillAgentTreasury treasury = IDualFillAgentTreasury(_load(".agentTreasury"));
        _expectRefusal(
            vm.addr(aKey),
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.retireOperator, ()),
            IDualFillAgentTreasury.NotCreator.selector
        );

        bytes memory before = _agentBalances(treasury, fill);
        vm.recordLogs();
        vm.startBroadcast(creatorKey);
        treasury.retireOperator();
        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event");
        assertEq(logs[0].topics[0], IDualFillAgentTreasury.OperatorRetired.selector);
        assertEq(_agentBalances(treasury, fill), before, "no balance moved in the retiring call");
        assertTrue(treasury.retired());

        _expectRefusal(
            vm.addr(operatorKey),
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.buy, (0.001e18, 1, block.timestamp + 300)),
            IDualFillAgentTreasury.Retired.selector
        );
        vm.startBroadcast(bKey);
        (uint256 quoteIn, uint256 tokensIn) = treasury.claimFees();
        vm.stopBroadcast();
        console2.log("claimed after retiring, quote", quoteIn);
        console2.log("claimed after retiring, tokens", tokensIn);
    }

    function _agentReturn() private {
        (IDualFillAgentTreasury treasury, IDualFill fill) = _createAgent("agent-return");
        _save("returnTreasury", address(treasury));
        _save("returnFill", address(fill));
        address a = vm.addr(aKey);
        address creator = vm.addr(creatorKey);
        _join(aKey, address(fill), (fill.TARGET() * 20) / 100);

        vm.startBroadcast(keeperKey);
        fill.abort();
        vm.stopBroadcast();
        assertTrue(fill.refundable());

        uint256 creatorBefore = weth.balanceOf(creator);
        uint256 aBefore = weth.balanceOf(a);
        vm.startBroadcast(bKey);
        uint256 returned = treasury.returnRunway();
        fill.refundFor(a);
        vm.stopBroadcast();
        assertEq(returned, RUNWAY, "the runway less the bond, and the bond");
        assertEq(weth.balanceOf(creator) - creatorBefore, RUNWAY, "back to the creator");
        assertEq(weth.balanceOf(a) - aBefore, (fill.TARGET() * 20) / 100, "and A's deposit to A");
        _expectRefusal(
            vm.addr(bKey),
            address(treasury),
            abi.encodeCall(IDualFillAgentTreasury.returnRunway, ()),
            IDualFillAgentTreasury.NothingToReturn.selector
        );
        console2.log("returnTreasury", address(treasury));
        console2.log("returnFill", address(fill));
    }

    function _linkedCreate() private {
        ILinkedDualFillFactory linked = _linkedFactory();
        address creator = vm.addr(creatorKey);
        FillTerms memory t = _terms("linked-create", linked.LAUNCH_FACTORY());
        (LaunchParams memory tp, CollectionParams memory np, LinkedParams memory lp) =
            _linkedParams(linked);
        assertEq(keccak256(abi.encode(tp, np, lp)), V23_PARAMS_HASH, "the V23 launch");

        vm.recordLogs();
        vm.startBroadcast(creatorKey);
        weth.approve(address(linked), t.feeBudget);
        address fill = linked.createFill(
            tp, np, lp, t.dualFillKey, t.target, t.deadline, t.publicUntil, false, t.feeBudget
        );
        vm.stopBroadcast();

        assertEq(linked.fillOf(creator, t.dualFillKey), fill, "fillOf finds it");
        assertEq(weth.balanceOf(fill), t.feeBudget, "the bond is in the fill");
        _assertLinkedAnnounced(vm.getRecordedLogs(), linked, fill, tp, np, lp);
        _save("linkedFill", fill);
        console2.log("linkedFill", fill);
        console2.log("publicUntil", t.publicUntil);
        console2.log("deadline", t.deadline);
    }

    function _linkedDeposit() private {
        ILinkedDualFill fill = ILinkedDualFill(payable(_load(".linkedFill")));
        if (block.timestamp >= fill.PUBLIC_UNTIL()) {
            revert TooLate("linked-deposit", fill.PUBLIC_UNTIL());
        }
        _joinQuarters(address(fill));
    }

    function _linkedOpen() private {
        ILinkedDualFillFactory linked = _linkedFactory();
        ILinkedDualFill fill = ILinkedDualFill(payable(_load(".linkedFill")));
        if (block.timestamp < fill.PUBLIC_UNTIL()) {
            revert TooEarly("linked-open", fill.PUBLIC_UNTIL());
        }
        _closeGap(address(fill));
        (LaunchParams memory tp, CollectionParams memory np, LinkedParams memory lp) =
            _linkedParams(linked);
        address creator = vm.addr(creatorKey);
        uint256 fee = TokenLaunchFactory(fill.LAUNCH_FACTORY()).launchFee();
        uint256 creatorBefore = weth.balanceOf(creator);

        vm.recordLogs();
        vm.startBroadcast(keeperKey);
        (address token, address locker, address collection, address vesting) =
            fill.open{ gas: OPEN_GAS }(tp, np, lp);
        vm.stopBroadcast();

        _assertOpenedThenCollectionOpened(vm.getRecordedLogs(), address(fill));
        assertEq(weth.balanceOf(creator) - creatorBefore, fill.FEE_BUDGET() - fee, "bond remainder");
        _assertCollectionHeldByTheFill(address(fill), token, locker, collection, vesting, lp);
        _save("linkedToken", token);
        _save("linkedLocker", locker);
        _save("linkedCollection", collection);
        _save("linkedVesting", vesting);
        console2.log("token", token);
        console2.log("locker", locker);
        console2.log("collection", collection);
        console2.log("vesting", vesting);
        console2.log("tokensForFill", fill.tokensForFill());
        console2.log("quoteBack", fill.quoteBack());
    }

    function _linkedMint() private {
        LPLocker locker = LPLocker(_load(".linkedLocker"));
        Collection721 collection = Collection721(_load(".linkedCollection"));
        AllocationVesting vesting = AllocationVesting(_load(".linkedVesting"));
        address a = vm.addr(aKey);
        address b = vm.addr(bKey);
        uint256 contributedBefore = locker.contributedQuote();
        uint256 aVest = vesting.contribution(a);
        uint256 bVest = vesting.contribution(b);
        uint256 routedEach = (collection.PRICE_QUOTE() * collection.mintToCurveBps()) / 10_000;

        _mint(aKey, collection, 2);
        _mint(bKey, collection, 1);

        assertEq(locker.contributedQuote() - contributedBefore, 3 * routedEach, "the routed share");
        assertEq(vesting.contribution(a) - aVest, 2 * routedEach, "A's vest recorded");
        assertEq(vesting.contribution(b) - bVest, routedEach, "B's vest recorded");
        console2.log("contributedQuote", locker.contributedQuote());
    }

    function _linkedFees() private {
        ILinkedDualFill fill = ILinkedDualFill(payable(_load(".linkedFill")));
        Collection721 collection = Collection721(_load(".linkedCollection"));
        address creator = vm.addr(creatorKey);
        uint256 share = collection.owed(address(weth), address(fill));
        assertGt(share, 0, "the collection owes the fill its creator share");
        uint256 creatorBefore = weth.balanceOf(creator);

        vm.startBroadcast(bKey);
        (uint256 quote, uint256 tokens) = fill.claimFees();
        vm.stopBroadcast();

        assertGe(quote, share, "the collection's creator share was forwarded");
        assertEq(weth.balanceOf(creator) - creatorBefore, quote, "to the creator");
        assertEq(collection.owed(address(weth), address(fill)), 0);
        console2.log("forwarded quote", quote);
        console2.log("forwarded tokens", tokens);
    }

    function _linkedClaim() private {
        ILinkedDualFill fill = ILinkedDualFill(payable(_load(".linkedFill")));
        IERC20 token = IERC20(fill.token());

        vm.startBroadcast(aKey);
        (uint256 aTokens, uint256 aQuote) = fill.claim();
        (uint256 bTokens, uint256 bQuote) = fill.claimFor(vm.addr(bKey));
        vm.stopBroadcast();

        assertEq(aTokens + bTokens, fill.tokensForFill(), "token claims sum to the pool");
        assertEq(aQuote + bQuote, fill.quoteBack(), "quote claims sum to what came back");
        assertEq(token.balanceOf(address(fill)), 0, "the fill holds no token");
        assertEq(weth.balanceOf(address(fill)), 0, "and no WETH");
        console2.log("A tokens", aTokens);
        console2.log("B tokens", bTokens);
    }

    function _createAgent(string memory label)
        private
        returns (IDualFillAgentTreasury treasury, IDualFill fill)
    {
        IDualFillAgentFactory agents = _agentFactory();
        IDualFillFactory dualFills = IDualFillFactory(agents.DUAL_FILL_FACTORY());
        address creator = vm.addr(creatorKey);
        FillTerms memory t = _terms(label, dualFills.LAUNCH_FACTORY());
        LaunchParams memory p = _tokenParams(dualFills.LAUNCH_FACTORY());
        Charter memory c = _charter();

        Charter memory own = _charter();
        own.operator = creator;
        _expectRefusal(
            creator,
            address(agents),
            abi.encodeCall(IDualFillAgentFactory.createAndFill, (own, p, t, RUNWAY)),
            IDualFillAgentTreasury.CreatorInCharter.selector
        );

        uint256 creatorBefore = weth.balanceOf(creator);
        vm.recordLogs();
        vm.startBroadcast(creatorKey);
        weth.approve(address(agents), RUNWAY);
        (address created, address fill_) = agents.createAndFill(c, p, t, RUNWAY);
        vm.stopBroadcast();
        treasury = IDualFillAgentTreasury(created);
        fill = IDualFill(fill_);

        assertEq(agents.treasuryOf(creator, t.dualFillKey), created, "treasuryOf finds it");
        assertEq(fill.CREATOR(), created, "the treasury is the fill's creator");
        assertEq(creatorBefore - weth.balanceOf(creator), RUNWAY);
        assertEq(weth.balanceOf(created), RUNWAY - t.feeBudget, "the runway less the bond");
        assertEq(weth.balanceOf(fill_), t.feeBudget, "the bond is in the fill");
        _assertAgentAnnounced(vm.getRecordedLogs(), agents, treasury, fill, t);
    }

    function _assertAgentAnnounced(
        Vm.Log[] memory logs,
        IDualFillAgentFactory agents,
        IDualFillAgentTreasury treasury,
        IDualFill fill,
        FillTerms memory t
    ) private {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(agents)) continue;
            assertEq(logs[i].topics[0], IDualFillAgentFactory.AgentDualFillCreated.selector);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(vm.addr(creatorKey)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(treasury)))));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(vm.addr(operatorKey)))));
            assertEq(logs[i].data, abi.encode(address(fill), t.dualFillKey, RUNWAY));
            return;
        }
        fail("no AgentDualFillCreated from the factory");
    }

    function _assertLinkedAnnounced(
        Vm.Log[] memory logs,
        ILinkedDualFillFactory linked,
        address fill,
        LaunchParams memory tp,
        CollectionParams memory np,
        LinkedParams memory lp
    ) private {
        ILinkedDualFill created = ILinkedDualFill(payable(fill));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(linked)) continue;
            assertEq(logs[i].topics[0], ILinkedDualFillFactory.FillCreated.selector);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(fill))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(vm.addr(creatorKey)))));
            assertEq(logs[i].topics[3], created.DUAL_FILL_KEY());
            assertEq(
                logs[i].data,
                abi.encode(
                    created.TARGET(),
                    created.DEADLINE(),
                    created.PUBLIC_UNTIL(),
                    false,
                    created.FEE_BUDGET(),
                    created.PARAMS_HASH(),
                    tp,
                    np,
                    lp
                ),
                "FillCreated carries the terms and the three structs"
            );
            return;
        }
        fail("no FillCreated from the combined factory");
    }

    function _assertOpenedThenCollectionOpened(Vm.Log[] memory logs, address fill) private pure {
        uint256 opened = type(uint256).max;
        uint256 collectionOpened = type(uint256).max;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != fill) continue;
            if (logs[i].topics[0] == ILinkedDualFill.Opened.selector) opened = i;
            if (logs[i].topics[0] == ILinkedDualFill.CollectionOpened.selector) {
                collectionOpened = i;
            }
        }
        assertLt(opened, logs.length, "Opened");
        assertLt(collectionOpened, logs.length, "CollectionOpened");
        assertLt(opened, collectionOpened, "Opened, then CollectionOpened");
    }

    /// L1 and L2 on the live launch.
    function _assertCollectionHeldByTheFill(
        address fill,
        address token,
        address locker,
        address collection,
        address vesting,
        LinkedParams memory lp
    ) private view {
        Collection721 drop = Collection721(collection);
        assertEq(drop.CREATOR(), fill, "L1: creator");
        assertEq(drop.owner(), fill, "L1: owner");
        (address receiver,) = drop.royaltyInfo(1, 10_000);
        assertEq(receiver, fill, "L1: royalty receiver");
        assertTrue(drop.metadataFrozen(), "L1: frozen");
        assertEq(LPLocker(locker).linkedCollection(), collection, "L2: collection");
        assertEq(LPLocker(locker).allocationVesting(), vesting, "L2: vesting");
        assertFalse(LPLocker(locker).wavesOpen(), "L2: no waves");
        assertEq(
            LPLocker(locker).allocationSlice(),
            (1_065_000_000e18 * uint256(lp.nftAllocationBps)) / 10_000,
            "L2: the minters' share"
        );
        assertEq(IERC20(token).totalSupply(), 1_065_000_000e18, "L2: total supply");
        assertEq(
            ILaunchHook(LPLocker(locker).HOOK())
            .configOf(PoolId.wrap(LPLocker(locker).poolId()))
            .creatorFeeRecipient,
            fill,
            "the hook credits the fill"
        );
    }

    /// A fresh key and the stage windows, opened `INCLUSION_MARGIN` after the wall clock, with the
    /// bond at twice the launch fee.
    function _terms(string memory label, address launchFactory)
        private
        view
        returns (FillTerms memory t)
    {
        uint64 opensFrom = uint64(block.timestamp) + INCLUSION_MARGIN;
        t.dualFillKey = keccak256(
            abi.encode("ripples dual fill shapes", label, vm.unixTime(), vm.addr(creatorKey))
        );
        t.target = vm.envOr("DF_TARGET_WEI", uint256(0.01e18));
        t.deadline = opensFrom + uint64(vm.envOr("DF_DEADLINE_SECONDS", uint256(3600)));
        t.publicUntil = opensFrom + uint64(vm.envOr("DF_PUBLIC_SECONDS", uint256(600)));
        t.feeBudget = 2 * TokenLaunchFactory(launchFactory).launchFee();
    }

    function _operatorBuy(IDualFillAgentTreasury treasury, uint256 amount) private {
        vm.startBroadcast(operatorKey);
        (uint256 spent, uint256 received) = treasury.buy(amount, 1, block.timestamp + 300);
        vm.stopBroadcast();
        assertEq(spent, amount, "the whole order filled");
        console2.log("bought, spent", spent);
        console2.log("bought, received", received);
    }

    function _assertLeft(IDualFillAgentTreasury treasury, uint256 spend) private view {
        (uint256 spendLeft, uint256 sellLeft, uint256 mintable) = treasury.remainingToday();
        console2.log("remainingToday spend", spendLeft);
        console2.log("remainingToday sell", sellLeft);
        assertEq(spendLeft, spend, "spend meter");
        assertEq(sellLeft, DAILY_SELL, "sell meter");
        assertEq(mintable, 0);
    }

    /// A refusal, simulated as `caller` and never sent. A script counts a pranked call against the
    /// caller's nonce, which would leave the caller's next real transaction one nonce ahead of the
    /// chain, so the nonce is put back.
    function _expectRefusal(address caller, address target, bytes memory call, bytes4 selector)
        private
    {
        uint64 nonce = vm.getNonce(caller);
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(call);
        vm.setNonceUnsafe(caller, nonce);
        assertFalse(ok, "a call the stage expects refused went through");
        assertEq(bytes4(reason), selector, "refused for the named reason");
    }

    function _routerBuy(uint256 key, LPLocker locker, address router, uint256 amount) private {
        PoolKey memory poolKey = locker.poolKey();
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(weth);
        address permit2 = address(LaunchRouter(router).PERMIT2());
        vm.startBroadcast(key);
        weth.approve(permit2, amount);
        IAllowanceTransfer(permit2)
            .approve(address(weth), router, uint160(amount), uint48(block.timestamp + 300));
        ILaunchRouter(router)
            .swapExactIn(poolKey, zeroForOne, amount, 1, vm.addr(key), block.timestamp + 300);
        vm.stopBroadcast();
    }

    function _mint(uint256 key, Collection721 collection, uint256 qty) private {
        uint256 due = collection.PRICE_QUOTE() * qty;
        vm.startBroadcast(key);
        weth.approve(address(collection), due);
        collection.mint(qty, 1);
        vm.stopBroadcast();
    }

    /// Inside the window one wallet holds at most a quarter of the target, so A and B each join
    /// exactly that and A's next join is refused.
    function _joinQuarters(address fill) private {
        IDualFill side = IDualFill(fill);
        uint256 ceiling = (side.TARGET() * side.MAX_WALLET_SHARE_BPS()) / 10_000;
        _join(aKey, fill, ceiling);
        _join(bKey, fill, ceiling);
        assertEq(side.totalDeposited(), 2 * ceiling, "each at its share ceiling");
        assertEq(side.remaining(), side.TARGET() - 2 * ceiling);
        _expectRefusal(
            vm.addr(aKey),
            fill,
            abi.encodeCall(IDualFill.deposit, (1)),
            IDualFill.WalletLimitReached.selector
        );
    }

    /// Past the window a side below its target takes anyone's deposit up to the gap, which B
    /// closes. A run that stopped after closing it finds no gap the second time.
    function _closeGap(address fill) private {
        IDualFill side = IDualFill(fill);
        uint256 gap = side.remaining();
        if (gap != 0) {
            vm.recordLogs();
            _join(bKey, fill, gap);
            assertEq(_count(vm.getRecordedLogs(), fill, IDualFill.Filled.selector), 1, "Filled");
        }
        assertEq(uint8(side.status()), uint8(IDualFill.Status.Full), "full past the window");
    }

    function _join(uint256 key, address fill, uint256 amount) private {
        vm.startBroadcast(key);
        weth.approve(fill, amount);
        IDualFill(fill).deposit(amount);
        vm.stopBroadcast();
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

    function _charter() private view returns (Charter memory c) {
        c.operator = vm.addr(operatorKey);
        c.dailySpend = DAILY;
        c.perCallSpend = PER_CALL;
        c.dailySell = DAILY_SELL;
        c.payees = new address[](1);
        c.payees[0] = PAYEE_C;
    }

    function _claims(IDualFill fill) private view returns (bytes memory) {
        (uint256 aTokens, uint256 aQuote) = fill.claimable(vm.addr(aKey));
        (uint256 bTokens, uint256 bQuote) = fill.claimable(vm.addr(bKey));
        return abi.encode(aTokens, aQuote, bTokens, bQuote);
    }

    function _agentBalances(IDualFillAgentTreasury treasury, IDualFill fill)
        private
        view
        returns (bytes memory)
    {
        IERC20 token = IERC20(fill.token());
        return abi.encode(
            weth.balanceOf(address(treasury)),
            weth.balanceOf(address(fill)),
            weth.balanceOf(vm.addr(creatorKey)),
            token.balanceOf(address(treasury)),
            token.balanceOf(address(fill))
        );
    }

    /// The V20 identity against the record's quote row, as a token Dual Fill launches it.
    function _tokenParams(address launchFactory) private view returns (LaunchParams memory p) {
        IQuoteRegistry.QuoteEconomics memory e = IQuoteRegistry(
                TokenLaunchFactory(launchFactory).quoteRegistry()
            )
            .quoteEconomics(address(weth));
        p.name = "Dual Fill Rehearsal";
        p.symbol = "DUAL";
        p.curveSupply = 800_000_000e18;
        p.lpTokenSupply = 219_000_000e18;
        p.vQuoteInit = e.standalonePhantomQuote;
        p.vTokenInit = 1_073_000_000e18;
        p.graduationQuote = e.graduationThreshold;
        p.quote = address(weth);
        p.logo = IMAGE;
        p.description = "One coin on two chains.";
        p.website = "https://ripples.run";
    }

    /// V23: the V20 identity on the linked row, the V22 collection on the Wave coupling.
    function _linkedParams(ILinkedDualFillFactory linked)
        private
        view
        returns (LaunchParams memory tp, CollectionParams memory np, LinkedParams memory lp)
    {
        IQuoteRegistry.QuoteEconomics memory e = IQuoteRegistry(
                TokenLaunchFactory(linked.LAUNCH_FACTORY()).quoteRegistry()
            )
            .quoteEconomics(address(weth));
        lp = LinkedParams({
            nftAllocationBps: 500,
            mintToCurveBps: 2_000,
            vestDuration: 31_536_000,
            vestCliff: 2_592_000,
            objectClaim: false,
            wavesOpen: false
        });
        tp.name = "Dual Fill Rehearsal";
        tp.symbol = "DUAL";
        tp.curveSupply = linked.curveSupplyFor(lp.nftAllocationBps);
        tp.lpTokenSupply = linked.LP_SUPPLY();
        tp.vQuoteInit = e.phantomQuote;
        tp.vTokenInit = linked.V_TOKEN_INIT();
        tp.graduationQuote = e.graduationThreshold;
        tp.quote = address(weth);
        tp.logo = IMAGE;
        tp.description = "One coin on two chains.";
        tp.website = "https://ripples.run";
        np.name = tp.name;
        np.symbol = tp.symbol;
        np.priceQuote = 0.01e18;
        np.maxSupply = 140;
        np.mode = Mode.PREGEN;
        np.baseURI = BASE_URI;
        np.royaltyBps = 500;
        np.quote = address(weth);
    }

    function _agentFactory() private view returns (IDualFillAgentFactory agents) {
        agents = IDualFillAgentFactory(
            vm.envOr("DF_AGENT_FACTORY", _recorded(".robinhoodTestnet.dualFillAgentFactory"))
        );
        IDualFillFactory dualFills = IDualFillFactory(agents.DUAL_FILL_FACTORY());
        assertEq(vm.addr(keeperKey), dualFills.KEEPER(), "the keeper key is the Dual Fill keeper");
        assertEq(agents.RUNWAY_ASSET(), address(weth), "the agent runway is the record's quote");
        console2.log("dualFillAgentFactory", address(agents));
        console2.log("dualFillFactory", address(dualFills));
    }

    function _linkedFactory() private view returns (ILinkedDualFillFactory linked) {
        linked = ILinkedDualFillFactory(
            vm.envOr("DF_LINKED_FACTORY", _recorded(".robinhoodTestnet.linkedDualFillFactory"))
        );
        assertEq(vm.addr(keeperKey), linked.KEEPER(), "the keeper key is the combined keeper");
        assertEq(linked.QUOTE(), address(weth), "the combined quote is the record's");
        console2.log("linkedDualFillFactory", address(linked));
    }

    function _recorded(string memory path) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(DEPLOYMENTS), path);
    }

    function _load(string memory path) private view returns (address) {
        return vm.parseJsonAddress(vm.readFile(STATE), path);
    }

    function _save(string memory key, address value) private {
        string memory state = vm.isFile(STATE) ? vm.readFile(STATE) : "{}";
        vm.serializeJson("state", state);
        vm.writeJson(vm.serializeAddress("state", key, value), STATE);
    }
}
