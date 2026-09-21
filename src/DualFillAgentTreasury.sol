// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Charter } from "./AgentTreasury.sol";
import { LPLocker } from "./LPLocker.sol";
import { LaunchParams, TokenLaunchFactory } from "./TokenLaunchFactory.sol";
import { IAllowanceTransfer } from "./interfaces/IAllowanceTransfer.sol";
import { IDualFill } from "./interfaces/IDualFill.sol";
import { FillTerms } from "./interfaces/IDualFillAgentFactory.sol";
import { IDualFillAgentTreasury } from "./interfaces/IDualFillAgentTreasury.sol";
import { IDualFillFactory } from "./interfaces/IDualFillFactory.sol";
import { ILaunchRouter } from "./interfaces/ILaunchRouter.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";

/// @title DualFillAgentTreasury
/// @notice The creator of one side of an agent Dual Fill: it bonds the side's fill, holds the
///         runway its funder put in, and after the market opens spends it under a charter fixed
///         at deployment.
///
/// **Until the market opens, the runway is its funder's.** The fill takes its bond out of the
/// runway when it is created, and after that quote leaves only through `returnRunway`, to the
/// wallet that funded the treasury, once the fill can never open. Until the fill opens the
/// operator can write to the run log and do nothing else, and nothing here can join the fill.
///
/// **Once it opens, quote leaves only as a buy on this market or a payment to a listed payee,
/// and tokens only as a sell.** Buys and payments share one meter per call and per UTC day, and a
/// sell reaches only tokens the treasury did not buy. These routes fix where value can go, not
/// what comes back for it: `minAmountOut` is the operator's to choose, so an operator that trades
/// against the treasury's own orders can keep up to `DAILY_SPEND` of quote and `DAILY_SELL` of
/// tokens a day. That bound is why the funder can retire the operator, for good. Retiring moves
/// nothing: what the treasury holds, and any income that reaches it later, stays in it.
///
/// **The funder has two calls, and neither moves money.** `cancelFill` stops a fill that is still
/// filling, which brings refunds and the runway back sooner, and `retireOperator` stops the agent.
/// There is no owner, no setter, no sweep, no `receive` and no ERC-721 receiver.
///
/// **The runway is in the market's quote; the bond is in the fee token.** A fill priced in WETH
/// holds both in one asset, as before. A fill priced in USDG or a stock holds its runway and
/// every meter in that asset and its bond in the fee token, which the charter can never spend:
/// what the launch fee leaves of it goes back to the funder through `returnBond` once the market
/// is open, or with the runway through `returnRunway` if it never opens.
contract DualFillAgentTreasury is IDualFillAgentTreasury, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Bound on the payee list, so the charter stays something a person can read in one screen.
    uint256 public constant MAX_PAYEES = 8;
    /// How long a Permit2 grant to the router lives. The grant is made and spent inside one
    /// call; the window only has to cover that call, and a short one means a grant left standing
    /// by a reverted transaction expires rather than waiting for someone to notice.
    uint48 private constant PERMIT_WINDOW = 300;

    /// The wallet that funded the treasury. It can cancel a filling fill and retire the operator,
    /// and it is where the runway goes back to if the fill never opens.
    address public immutable CREATOR;
    address public immutable AGENT_FACTORY;
    address public immutable OPERATOR;
    /// The market's asset: the runway, every meter, every buy, sell and payment are in it.
    address public immutable QUOTE;
    /// The fill factory's bond asset, which is the launch factory's fee token. The same asset
    /// as `QUOTE` on a WETH fill, and one the charter cannot reach on any other.
    address public immutable FEE_TOKEN;
    address public immutable LAUNCH_FACTORY;
    address public immutable FILL_FACTORY;
    /// The venue. Zero is a treasury that can never trade.
    address public immutable ROUTER;
    address public immutable PERMIT2;
    bytes32 public immutable DUAL_FILL_KEY;

    uint128 public immutable DAILY_SPEND;
    uint128 public immutable PER_CALL_SPEND;
    uint128 public immutable DAILY_SELL;

    /// Written once by `startFill`.
    address public fill;
    /// The market the fill opened, written once by `bind`.
    address public token;
    address public locker;
    bool public retired;
    /// Every token this treasury has bought. A sell is held to the balance above it, so the
    /// operator sells only what the market paid the treasury and never unwinds a buy.
    uint256 public boughtTokens;

    /// The day each meter was last touched, as `block.timestamp / 1 days`, beside what it has
    /// counted since. The window is the UTC day, so an operator can spend a full day's limit
    /// either side of midnight.
    struct Meter {
        uint64 day;
        uint192 used;
    }

    Meter private _spend;
    Meter private _sell;

    address[] private _payees;
    mapping(address payee => bool) public isPayee;

    constructor(
        address creator,
        address fillFactory,
        address router,
        address permit2,
        address quote,
        Charter memory c,
        bytes32 dualFillKey
    ) {
        AGENT_FACTORY = msg.sender;
        if (
            creator == address(0) || c.operator == address(0) || fillFactory == address(0)
                || quote == address(0)
        ) revert ZeroAddress();
        if (fillFactory.code.length == 0) revert NotAContract();
        if (router != address(0) && (router.code.length == 0 || permit2.code.length == 0)) {
            revert NotAContract();
        }
        // A charter with either limit at zero can never spend, so its runway and every later
        // income would be stuck for good.
        if (c.perCallSpend == 0 || c.perCallSpend > c.dailySpend) revert InvalidSpendLimits();
        if (c.operator == creator) revert CreatorInCharter();
        if (c.payees.length > MAX_PAYEES) revert TooManyPayees();
        for (uint256 i = 0; i < c.payees.length; i++) {
            address payee = c.payees[i];
            if (payee == address(0)) revert ZeroAddress();
            if (payee == creator) revert CreatorInCharter();
            if (isPayee[payee]) revert DuplicatePayee();
            isPayee[payee] = true;
            _payees.push(payee);
        }

        address feeToken = IDualFillFactory(fillFactory).FEE_TOKEN();
        address launchFactory = IDualFillFactory(fillFactory).LAUNCH_FACTORY();
        if (address(TokenLaunchFactory(launchFactory).FEE_TOKEN()) != feeToken) {
            revert QuoteMismatch();
        }

        CREATOR = creator;
        OPERATOR = c.operator;
        QUOTE = quote;
        FEE_TOKEN = feeToken;
        LAUNCH_FACTORY = launchFactory;
        FILL_FACTORY = fillFactory;
        ROUTER = router;
        PERMIT2 = permit2;
        DUAL_FILL_KEY = dualFillKey;
        DAILY_SPEND = c.dailySpend;
        PER_CALL_SPEND = c.perCallSpend;
        DAILY_SELL = c.dailySell;
    }

    /// @notice Create this treasury's fill, bonded out of the runway, with the treasury as its
    ///         creator. Once, by the agent factory, in the transaction that deployed and funded
    ///         the treasury.
    function startFill(LaunchParams calldata p, FillTerms calldata t)
        external
        nonReentrant
        returns (address fill_)
    {
        if (msg.sender != AGENT_FACTORY) revert NotAgentFactory();
        if (fill != address(0)) revert AlreadyStarted();
        if (t.dualFillKey != DUAL_FILL_KEY) revert FillMismatch();

        IERC20(FEE_TOKEN).forceApprove(FILL_FACTORY, t.feeBudget);
        fill_ = IDualFillFactory(FILL_FACTORY)
            .createFill(
                p, t.dualFillKey, t.target, t.deadline, t.publicUntil, t.openAlone, t.feeBudget
            );
        IERC20(FEE_TOKEN).forceApprove(FILL_FACTORY, 0);
        if (
            !IDualFillFactory(FILL_FACTORY).isFill(fill_)
                || IDualFillFactory(FILL_FACTORY).fillOf(address(this), t.dualFillKey) != fill_
                || IDualFill(fill_).CREATOR() != address(this)
        ) revert FillMismatch();
        if (IDualFill(fill_).QUOTE() != QUOTE) revert QuoteMismatch();

        fill = fill_;
        emit FillStarted(fill_, t.dualFillKey, t.feeBudget);
    }

    /// @notice Record the market the fill opened. Permissionless and idempotent; every call that
    ///         needs the market runs it first, so nobody ever has to.
    function bind() public returns (address token_) {
        token_ = token;
        if (token_ != address(0)) return token_;
        address fill_ = fill;
        if (fill_ == address(0) || IDualFill(fill_).status() != IDualFill.Status.Opened) {
            revert NotOpened();
        }
        address locker_ = IDualFill(fill_).locker();
        if (
            !TokenLaunchFactory(LAUNCH_FACTORY).isFromFactory(locker_)
                || LPLocker(locker_).QUOTE() != QUOTE
        ) revert FillMismatch();

        token_ = IDualFill(fill_).token();
        token = token_;
        locker = locker_;
        emit Bound(token_, locker_);
    }

    /// @notice Buy this market's token into the treasury. Metered on what the router actually
    ///         spent, because it never takes what the curve could not serve.
    /// @dev Refused inside the market's opening charge window: the hook exempts only the fill,
    ///      so a buy there would lose most of what it bought to the burn while the meter counted
    ///      the whole spend.
    function buy(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        _onlyWorkingOperator();
        address token_ = bind();
        uint256 opensAt =
            IDualFill(fill).openedAt() + TokenLaunchFactory(LAUNCH_FACTORY).SNIPE_WINDOW();
        if (block.timestamp < opensAt) revert SnipeWindowOpen();
        if (ROUTER == address(0)) revert NoVenue();
        _bounded(amountIn);

        uint256 quoteBefore = IERC20(QUOTE).balanceOf(address(this));
        uint256 tokenBefore = IERC20(token_).balanceOf(address(this));
        (spent, received) = _swap(true, amountIn, minAmountOut, deadline);
        if (
            quoteBefore - IERC20(QUOTE).balanceOf(address(this)) != spent
                || IERC20(token_).balanceOf(address(this)) - tokenBefore != received
        ) revert UnexpectedBalance();

        boughtTokens += received;
        _spendQuote(spent);
        emit Bought(spent, received);
    }

    /// @notice Sell tokens the market paid the treasury, against the charter's daily sell limit.
    ///         Metered on the whole order rather than the fill, so an oversized order cannot probe
    ///         the limit.
    function sell(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sold, uint256 received)
    {
        _onlyWorkingOperator();
        address token_ = bind();
        if (ROUTER == address(0)) revert NoVenue();
        _bounded(amountIn);
        uint256 sellable = sellableTokens();
        if (amountIn > sellable) revert SellsIncomeOnly(amountIn, sellable);
        uint256 used = _roll(_sell) + amountIn;
        if (used > DAILY_SELL) revert OverDailySell(used, DAILY_SELL);
        _sell.used = uint192(used);

        uint256 tokenBefore = IERC20(token_).balanceOf(address(this));
        uint256 quoteBefore = IERC20(QUOTE).balanceOf(address(this));
        (sold, received) = _swap(false, amountIn, minAmountOut, deadline);
        if (
            tokenBefore - IERC20(token_).balanceOf(address(this)) != sold
                || IERC20(QUOTE).balanceOf(address(this)) - quoteBefore != received
        ) revert UnexpectedBalance();
        emit Sold(sold, received);
    }

    /// @notice Pay one of the charter's listed addresses out of the treasury, once the market has
    ///         opened.
    function pay(address to, uint256 amount) external nonReentrant {
        _onlyWorkingOperator();
        bind();
        if (!isPayee[to]) revert NotPayee(to);
        if (amount == 0) revert ZeroAmount();
        _spendQuote(amount);

        IERC20 quote = IERC20(QUOTE);
        uint256 before = quote.balanceOf(address(this));
        uint256 toBefore = quote.balanceOf(to);
        quote.safeTransfer(to, amount);
        if (
            before - quote.balanceOf(address(this)) != amount
                || quote.balanceOf(to) - toBefore != amount
        ) revert UnexpectedBalance();
        emit Paid(to, amount);
    }

    /// @notice Write an entry in the agent's public run log. The one operator call that works
    ///         before the market opens.
    function note(bytes32 digest, string calldata uri) external {
        _onlyWorkingOperator();
        emit Noted(digest, uri);
    }

    /// @notice Pull the market's creator income in. Permissionless, because every escrow pays what
    ///         it credited to its own recipient and nothing here chooses where it goes.
    /// @dev The fill is the launch's creator of record, so its `claimFees` forwards the locker's
    ///      credit and the hook's until the hand-over; after it the hook credits this contract
    ///      directly. Works on a retired treasury, whose income still belongs here.
    function claimFees() external nonReentrant returns (uint256 quoteAmount, uint256 tokenAmount) {
        address token_ = bind();
        uint256 quoteBefore = IERC20(QUOTE).balanceOf(address(this));
        uint256 tokenBefore = IERC20(token_).balanceOf(address(this));
        IDualFill(fill).claimFees();
        address hook = LPLocker(locker).HOOK();
        _claim(hook, QUOTE);
        _claim(hook, token_);
        quoteAmount = IERC20(QUOTE).balanceOf(address(this)) - quoteBefore;
        tokenAmount = IERC20(token_).balanceOf(address(this)) - tokenBefore;
        emit FeesClaimed(quoteAmount, tokenAmount);
    }

    /// @notice Stop a fill that is still filling. The fill's own rules decide whether it can.
    function cancelFill() external nonReentrant {
        if (msg.sender != CREATOR) revert NotCreator();
        IDualFill(fill).cancel();
        emit FillCancelled(fill);
    }

    /// @notice Stop the operator for good. Moves nothing: whatever the treasury holds, and any
    ///         income that reaches it later, stays. A fill that never opens still returns its
    ///         runway.
    /// @dev No reentrancy guard: it makes no call and moves nothing, so a call made from inside a
    ///      swap is refused for who sent it, like any other.
    function retireOperator() external {
        if (msg.sender != CREATOR) revert NotCreator();
        if (retired) revert AlreadyRetired();
        retired = true;
        emit OperatorRetired();
    }

    /// @notice Send everything the treasury holds back to the wallet that funded it, once its
    ///         fill can never open. Permissionless and repeatable, and the recipient is fixed.
    /// @dev `refundable()` becomes true only for a fill that can never open and stays true, so
    ///      nothing here is reachable while the market could exist. The fill returns the bond
    ///      first, whether or not its contributors have taken their refunds; on a treasury whose
    ///      quote is not the fee token that bond comes back as its own asset and goes with the
    ///      runway.
    function returnRunway() external nonReentrant returns (uint256 amount) {
        address fill_ = fill;
        if (fill_ == address(0) || !IDualFill(fill_).refundable()) revert NotRefundable();
        if (!IDualFill(fill_).feeBudgetSettled()) IDualFill(fill_).returnFeeBudget();
        amount = IERC20(QUOTE).balanceOf(address(this));
        uint256 bond = FEE_TOKEN == QUOTE ? 0 : IERC20(FEE_TOKEN).balanceOf(address(this));
        if (amount == 0 && bond == 0) revert NothingToReturn();
        if (amount != 0) {
            IERC20(QUOTE).safeTransfer(CREATOR, amount);
            emit RunwayReturned(CREATOR, amount);
        }
        if (bond != 0) {
            IERC20(FEE_TOKEN).safeTransfer(CREATOR, bond);
            emit BondReturned(CREATOR, bond);
        }
    }

    /// @notice Send the fee token the treasury holds back to the wallet that funded it, once the
    ///         market is open, on a treasury whose quote is another asset. Permissionless and
    ///         repeatable, and the recipient is fixed.
    /// @dev The bond is the one thing such a treasury ever holds in the fee token, and the fill
    ///      hands back what the launch fee did not use at open. The charter meters the quote and
    ///      can spend nothing else, so leaving it here would strand it. On a treasury whose
    ///      quote is the fee token that residue is runway, and this call has nothing to return.
    function returnBond() external nonReentrant returns (uint256 amount) {
        if (FEE_TOKEN == QUOTE) revert NothingToReturn();
        address fill_ = fill;
        if (fill_ == address(0) || IDualFill(fill_).status() != IDualFill.Status.Opened) {
            revert NotOpened();
        }
        amount = IERC20(FEE_TOKEN).balanceOf(address(this));
        if (amount == 0) revert NothingToReturn();
        IERC20(FEE_TOKEN).safeTransfer(CREATOR, amount);
        emit BondReturned(CREATOR, amount);
    }

    function charter()
        external
        view
        returns (
            address operator,
            uint128 dailySpend,
            uint128 perCallSpend,
            uint128 dailySell,
            uint32 dailyMint,
            address[] memory payees_
        )
    {
        return (OPERATOR, DAILY_SPEND, PER_CALL_SPEND, DAILY_SELL, 0, _payees);
    }

    function remainingToday()
        external
        view
        returns (uint256 spend, uint256 sellable, uint256 mintable)
    {
        uint64 today = uint64(block.timestamp / 1 days);
        spend = DAILY_SPEND - (_spend.day == today ? uint256(_spend.used) : 0);
        sellable = DAILY_SELL - (_sell.day == today ? uint256(_sell.used) : 0);
        mintable = 0;
    }

    /// @notice The tokens a sell can reach: the treasury's balance above what it bought.
    function sellableTokens() public view returns (uint256) {
        address token_ = token;
        if (token_ == address(0)) return 0;
        uint256 balance = IERC20(token_).balanceOf(address(this));
        return balance > boughtTokens ? balance - boughtTokens : 0;
    }

    function payees() external view returns (address[] memory) {
        return _payees;
    }

    function _onlyWorkingOperator() private view {
        if (msg.sender != OPERATOR) revert NotOperator();
        if (retired) revert Retired();
    }

    /// Permit2 carries an allowance in 160 bits, so an order above that is refused here rather
    /// than truncated into a grant that does not cover it.
    function _bounded(uint256 amountIn) private pure {
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > type(uint160).max) revert AmountTooLarge();
    }

    /// One order on this launch's own pool. The key comes from the locker, so a caller names a
    /// size and a floor and nothing else.
    function _swap(bool buying, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        private
        returns (uint256 spent, uint256 amountOut)
    {
        PoolKey memory key = LPLocker(locker).poolKey();
        address input = buying ? QUOTE : token;
        bool zeroForOne = Currency.unwrap(key.currency0) == input;

        // Permit2 is the router's allowance ledger. The ERC-20 approval to it is set to exactly
        // this order and cleared after, and the grant to the router expires within the window
        // above, so neither is left standing between calls.
        IERC20(input).forceApprove(PERMIT2, amountIn);
        IAllowanceTransfer(PERMIT2)
            .approve(input, ROUTER, uint160(amountIn), uint48(block.timestamp) + PERMIT_WINDOW);
        (spent, amountOut) = ILaunchRouter(ROUTER)
            .swapExactIn(key, zeroForOne, amountIn, minAmountOut, address(this), deadline);
        IAllowanceTransfer(PERMIT2).approve(input, ROUTER, 0, 0);
        IERC20(input).forceApprove(PERMIT2, 0);
    }

    function _claim(address escrow, address asset) private returns (uint256 amount) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        // An escrow holding nothing for this treasury in this asset says so by reverting, and
        // that is not a failure of this call. Only that one answer is quiet. Anything else,
        // including a child call that ran out of gas and returned nothing, is a claim that did
        // not happen and must not be reported as one.
        try IPullEscrow(escrow).claim(asset) returns (uint256 claimed) {
            amount = claimed;
        } catch (bytes memory reason) {
            if (bytes4(reason) != IPullEscrow.NothingOwed.selector) revert UnexpectedBalance();
            return 0;
        }
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert UnexpectedBalance();
    }

    /// The spending meter, shared by buys and payments. Both limits are checked against the same
    /// number, so a day's budget cannot be spent as one transaction and a per-call limit cannot
    /// be walked around by repeating it past the day's.
    function _spendQuote(uint256 amount) private {
        if (amount > PER_CALL_SPEND) revert OverCallSpend(amount, PER_CALL_SPEND);
        uint256 used = _roll(_spend) + amount;
        if (used > DAILY_SPEND) revert OverDailySpend(used, DAILY_SPEND);
        _spend.used = uint192(used);
    }

    /// What a meter has counted today, stamping the day when it has rolled over. Written before
    /// the caller adds to `used`, so a stale day is cleared exactly once per day per meter.
    function _roll(Meter storage meter) private returns (uint256) {
        uint64 today = uint64(block.timestamp / 1 days);
        if (meter.day == today) return meter.used;
        meter.day = today;
        meter.used = 0;
        return 0;
    }
}
