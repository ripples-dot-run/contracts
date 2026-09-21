// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { AllocationVesting } from "./AllocationVesting.sol";
import { Collection721, CollectionParams } from "./Collection721.sol";
import { LPLocker } from "./LPLocker.sol";
import {
    DevBuyParams,
    LaunchParams,
    LinkedParams,
    TokenLaunchFactory
} from "./TokenLaunchFactory.sol";
import { IAllowanceTransfer } from "./interfaces/IAllowanceTransfer.sol";
import { ILaunchRouter } from "./interfaces/ILaunchRouter.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";

/// The charter, as one argument. Everything in it is fixed at construction and readable by
/// anyone before a single piece is minted.
struct Charter {
    /// The key that works the agent. It is the only address that can move money out of here,
    /// and it can only move it the five ways below.
    address operator;
    /// Quote out per day, in the market's asset, covering buys, mints and payouts together.
    /// This is the number that says what the agent costs to run.
    uint128 dailySpend;
    /// Quote out in any single call. At most `dailySpend`, so a day's budget cannot be one
    /// unbounded transaction.
    uint128 perCallSpend;
    /// Token in per day, in the launch token's own units. **Zero means the agent can never sell
    /// its own token**, which is the setting worth having and the default the form offers.
    uint128 dailySell;
    /// Pieces the agent may mint from its own collection per day. Zero means none.
    uint32 dailyMint;
    /// The addresses `pay` may send the market's asset to: the agent's hosting, its inference
    /// bill, a contributor. Fixed here, so an operator key that is taken cannot invent a
    /// recipient, only drain a day's budget to a published one.
    address[] payees;
}

/// @title AgentTreasury
/// @notice The creator of an agent launch, and the only door its money can leave by.
///
/// A Ripples linked launch has no founder allocation: supply is the curve, the pool position and
/// the slice reserved for minters. The one stream that would ordinarily be a founder's is the
/// creator's 70% of trade fees, and on an agent launch that stream credits this contract instead
/// of a person. So the agent's runway is what its creator put in plus what its own market earns,
/// and the charter above says in public, before anyone mints, how fast it can spend it.
///
/// **It is the launch's creator in the literal sense.** `TokenLaunchFactory` records its caller,
/// so the treasury calls `createLinkedLaunch` itself. Everything downstream that keys on the
/// creator, the fee credit and the collection's creator withdrawal, keys on this address.
///
/// **There is no way out other than the four metered calls.** No owner, no pause, no setter, no
/// sweep, no upgrade. The creator funds it and launches it once; after that they have no more
/// power over it than anyone else. An asset that is neither the market's quote nor the launch's
/// token, sent here by mistake, stays here: that is what a vault with no back door costs.
///
/// **Trading is the launch's own pool and nothing else.** The pool key is read from this
/// launch's locker rather than taken from the caller, so there is no foreign market to route
/// through and no argument to get wrong.
contract AgentTreasury is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    /// Bound on the payee list, so the charter stays something a person can read in one screen
    /// and a launch cannot be published with a list nobody checks.
    uint256 public constant MAX_PAYEES = 8;
    /// How long a Permit2 grant to the router lives. The grant is made and spent inside one
    /// call; the window only has to cover that call, and a short one means a grant left standing
    /// by a reverted transaction expires rather than waiting for someone to notice.
    uint48 private constant PERMIT_WINDOW = 300;

    /// Who deployed it. Funds it, launches it once, keeps the collection's metadata calls, and
    /// has no other power here.
    address public immutable CREATOR;
    /// Whoever deployed this treasury. Named as a second caller for `launch` so
    /// `AgentTreasuryFactory.createAndLaunch` can open it in the transaction that deploys this
    /// contract, rather than leaving a funded treasury that never opened. The factory has no
    /// other route to that call.
    address public immutable AGENT_FACTORY;
    address public immutable OPERATOR;
    /// The market's asset. Also the fee token on every Robinhood Chain launch, which is why one
    /// address serves both approvals in `launch`.
    IERC20 public immutable QUOTE;
    TokenLaunchFactory public immutable FACTORY;
    /// The venue. `LaunchRouter` fills to the end of the curve, so an agent's buy behaves like
    /// the site's. Zero is a treasury that cannot trade at all.
    ILaunchRouter public immutable ROUTER;
    IAllowanceTransfer public immutable PERMIT2;

    uint128 public immutable DAILY_SPEND;
    uint128 public immutable PER_CALL_SPEND;
    uint128 public immutable DAILY_SELL;
    uint32 public immutable DAILY_MINT;

    /// The launch, written once by `launch` and never again.
    address public token;
    address public locker;
    address public collection;
    address public vesting;

    /// The day each meter was last touched, as `block.timestamp / 1 days`, beside what it has
    /// counted since. A call on a new day reads the stored day, sees it is stale, and starts the
    /// count again; nothing has to be reset by anyone.
    ///
    /// The window is the UTC day rather than a rolling one, so an operator can spend a full day's
    /// ceiling either side of midnight. That is the cost of a meter that costs one storage slot
    /// and needs nobody to maintain it, and the charter is published in those terms.
    struct Meter {
        uint64 day;
        uint192 used;
    }

    Meter private _spend;
    Meter private _sell;
    Meter private _mint;

    address[] private _payees;
    mapping(address payee => bool) public isPayee;

    event Launched(
        address indexed token, address indexed locker, address collection, address vesting
    );
    event Bought(uint256 spent, uint256 received);
    event Sold(uint256 sold, uint256 received);
    event Minted(uint256 quantity, uint256 cost);
    event Paid(address indexed to, uint256 amount);
    event FeesClaimed(uint256 quoteAmount, uint256 tokenAmount);
    event VestedClaimed(uint256 amount);
    /// The run log. `digest` is whatever the operator commits to, `uri` where it can be read.
    /// Nothing on chain checks either; the value is that the entry is dated, ordered and
    /// unremovable beside the transactions it describes.
    event Noted(bytes32 indexed digest, string uri);

    error ZeroAddress();
    error NotAContract();
    error NotCreator();
    error NotOperator();
    error AlreadyLaunched();
    error NotLaunched();
    error NoCollection();
    error NoVenue();
    error ZeroAmount();
    /// An order larger than the allowance ledger can carry. Separate from `ZeroAmount` so a
    /// revert names which end of the range it fell off.
    error AmountTooLarge();
    error TooManyPayees();
    error DuplicatePayee();
    /// `perCallSpend` above `dailySpend`, which would make the per-call limit no limit at all.
    error InvalidSpendLimits();
    /// Over one of the charter's ceilings. `limit` is the ceiling, `requested` what the call
    /// would have taken it to, both in the meter's own units.
    error OverDailySpend(uint256 requested, uint256 limit);
    error OverCallSpend(uint256 requested, uint256 limit);
    error OverDailySell(uint256 requested, uint256 limit);
    error OverDailyMint(uint256 requested, uint256 limit);
    error NotPayee(address to);
    /// The launch names an asset this treasury does not hold or meter. Every limit here is in
    /// `QUOTE`, which is the launch factory's fee token, so a market settling in anything else
    /// would be bought with an asset the meter does not measure and funded from a balance this
    /// contract never receives.
    error QuoteMismatch();
    /// The quote or the token left this contract by a route other than the one just taken, or
    /// arrived short. Every metered call measures its own balances rather than trusting a
    /// return value, so an asset that reports a move it did not make cannot fill the meter.
    error UnexpectedBalance();

    constructor(
        address creator,
        address factory,
        address router,
        address permit2,
        Charter memory c
    ) {
        if (creator == address(0) || c.operator == address(0) || factory == address(0)) {
            revert ZeroAddress();
        }
        AGENT_FACTORY = msg.sender;
        if (factory.code.length == 0) revert NotAContract();
        if (router != address(0) && (router.code.length == 0 || permit2.code.length == 0)) {
            revert NotAContract();
        }
        // A per-call limit of zero beside a daily budget is not a tight charter, it is a
        // treasury that can hold money and never spend a wei of it, for good.
        if (c.perCallSpend > c.dailySpend || (c.dailySpend != 0 && c.perCallSpend == 0)) {
            revert InvalidSpendLimits();
        }
        if (c.payees.length > MAX_PAYEES) revert TooManyPayees();

        CREATOR = creator;
        OPERATOR = c.operator;
        FACTORY = TokenLaunchFactory(factory);
        QUOTE = TokenLaunchFactory(factory).FEE_TOKEN();
        ROUTER = ILaunchRouter(router);
        PERMIT2 = IAllowanceTransfer(permit2);
        DAILY_SPEND = c.dailySpend;
        PER_CALL_SPEND = c.perCallSpend;
        DAILY_SELL = c.dailySell;
        DAILY_MINT = c.dailyMint;

        for (uint256 i = 0; i < c.payees.length; i++) {
            address payee = c.payees[i];
            if (payee == address(0)) revert ZeroAddress();
            if (isPayee[payee]) revert DuplicatePayee();
            isPayee[payee] = true;
            _payees.push(payee);
        }
    }

    /// @notice Open the agent's launch. The treasury pays the fee out of its own balance and is
    ///         recorded as the launch's creator, so the creator's share of trade fees credits
    ///         here from the first trade.
    /// @dev Once. A second launch would give one charter two markets and two fee streams, and
    ///      the meters, the venue and the collection all name one launch.
    function launch(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d
    ) external nonReentrant returns (address, address, address, address) {
        // The factory is the second caller so a creator can deploy and launch at once; see
        // `AGENT_FACTORY`.
        if (msg.sender != CREATOR && msg.sender != AGENT_FACTORY) revert NotCreator();
        if (token != address(0)) revert AlreadyLaunched();

        // The fee and the opening buy are both pulled by the factory inside this call. The
        // approval is set to exactly what the two of them can take and cleared straight after,
        // so nothing is left standing for a later fee change to reach.
        uint256 allowance = FACTORY.launchFee() + d.initialBuy;
        QUOTE.forceApprove(address(FACTORY), allowance);
        (address t, address l, address c, address v) = FACTORY.createLinkedLaunch(tp, np, lp, d);
        QUOTE.forceApprove(address(FACTORY), 0);

        // One asset, all the way through: the market, the collection, the runway and every limit.
        // Asked of the market that was actually opened rather than of the argument that asked for
        // it, because an empty `quote` means the launch factory's current default and that is a
        // registry setting rather than a promise. A market in anything else would earn a fee
        // stream this contract cannot spend and cannot release.
        if (LPLocker(l).QUOTE() != address(QUOTE)) revert QuoteMismatch();

        token = t;
        locker = l;
        collection = c;
        vesting = v;
        emit Launched(t, l, c, v);
        return (t, l, c, v);
    }

    /// @notice Buy the agent's own token on its own market, into its own treasury.
    /// @param amountIn Quote to offer. Metered on the fill rather than the order: the router
    ///        never takes what the curve could not serve, so a partial fill spends the meter by
    ///        what actually left.
    /// @param minAmountOut The floor over the whole order, as `ILaunchRouter` defines it.
    function buy(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        _onlyOperator();
        if (token == address(0)) revert NotLaunched();
        if (address(ROUTER) == address(0)) revert NoVenue();
        _bounded(amountIn);

        uint256 quoteBefore = QUOTE.balanceOf(address(this));
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        (spent, received) = _swap(true, amountIn, minAmountOut, deadline);
        uint256 quoteOut = quoteBefore - QUOTE.balanceOf(address(this));
        if (quoteOut != spent || IERC20(token).balanceOf(address(this)) - tokenBefore != received) {
            revert UnexpectedBalance();
        }

        _spendQuote(quoteOut);
        emit Bought(spent, received);
    }

    /// @notice Sell the agent's own token back into its market, against the charter's daily
    ///         sell ceiling. A charter with a zero ceiling cannot reach this call at all.
    function sell(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 sold, uint256 received)
    {
        _onlyOperator();
        if (token == address(0)) revert NotLaunched();
        if (address(ROUTER) == address(0)) revert NoVenue();
        _bounded(amountIn);
        // Metered on the whole order rather than the fill, so an operator cannot probe the daily
        // ceiling with an oversized order that the curve clamps.
        uint256 used = _roll(_sell) + amountIn;
        if (used > DAILY_SELL) revert OverDailySell(used, DAILY_SELL);
        _sell.used = uint192(used);

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        uint256 quoteBefore = QUOTE.balanceOf(address(this));
        (sold, received) = _swap(false, amountIn, minAmountOut, deadline);
        if (
            tokenBefore - IERC20(token).balanceOf(address(this)) != sold
                || QUOTE.balanceOf(address(this)) - quoteBefore != received
        ) revert UnexpectedBalance();

        emit Sold(sold, received);
    }

    /// @notice Mint from the agent's own collection. The pieces land here and, on a linked
    ///         launch, the mint routes its share into the raise like anyone else's.
    /// @param minRoutedTotal The floor on quote routed into the curve, passed straight through.
    function mint(uint256 quantity, uint256 minRoutedTotal) external nonReentrant {
        _onlyOperator();
        if (collection == address(0)) revert NotLaunched();
        if (quantity == 0) revert ZeroAmount();

        uint256 minted = _roll(_mint) + quantity;
        if (minted > DAILY_MINT) revert OverDailyMint(minted, DAILY_MINT);
        _mint.used = uint192(minted);

        uint256 cost = Collection721(collection).PRICE_QUOTE() * quantity;
        uint256 before = QUOTE.balanceOf(address(this));
        QUOTE.forceApprove(collection, cost);
        Collection721(collection).mint(quantity, minRoutedTotal);
        QUOTE.forceApprove(collection, 0);
        if (before - QUOTE.balanceOf(address(this)) != cost) revert UnexpectedBalance();

        _spendQuote(cost);
        emit Minted(quantity, cost);
    }

    /// @notice Pay one of the charter's published addresses out of the runway.
    function pay(address to, uint256 amount) external nonReentrant {
        _onlyOperator();
        if (!isPayee[to]) revert NotPayee(to);
        if (amount == 0) revert ZeroAmount();

        _spendQuote(amount);
        uint256 before = QUOTE.balanceOf(address(this));
        uint256 toBefore = QUOTE.balanceOf(to);
        QUOTE.safeTransfer(to, amount);
        if (
            before - QUOTE.balanceOf(address(this)) != amount
                || QUOTE.balanceOf(to) - toBefore != amount
        ) revert UnexpectedBalance();
        emit Paid(to, amount);
    }

    /// @notice Pull the launch's creator fees in. Permissionless, because the money has one
    ///         destination and this call cannot choose it: each escrow pays what it credited to
    ///         this address, here.
    /// @dev Three escrows, because a launch earns in three places. The hook credits the creator's
    ///      share of every trade out of its own escrow, before the target and after it, and that
    ///      is the trade income for the launch's whole life. The collection holds the share of
    ///      each mint that was not routed into the raise, which on a linked launch is the larger
    ///      figure. The locker is asked as well because a pool that ever collects a fee divides
    ///      it there, and a launch normally has a balance in one of the three, so none of them is
    ///      required to answer. Both currencies, because a pool has two sides and a sell pays the
    ///      fee in the quote while a buy pays it in the token.
    function claimFees() external nonReentrant returns (uint256 quoteAmount, uint256 tokenAmount) {
        if (locker == address(0)) revert NotLaunched();
        address hook = LPLocker(locker).HOOK();
        quoteAmount = _claim(hook, address(QUOTE)) + _claim(locker, address(QUOTE));
        if (collection != address(0)) quoteAmount += _claim(collection, address(QUOTE));
        tokenAmount = _claim(hook, token) + _claim(locker, token);
        emit FeesClaimed(quoteAmount, tokenAmount);
    }

    /// @notice Take in the token slice the agent's own mints earned it.
    /// @dev The agent mints from its own collection like anyone else, so the collection records
    ///      it as a minter and the vesting contract holds a slice of supply for it from the
    ///      target onwards. `AllocationVesting.claim` pays its caller, so without this the token
    ///      the charter authorised buying would sit there for good. Permissionless, like
    ///      `claimFees`, because it has one destination and this call cannot choose it.
    function claimVested() external nonReentrant returns (uint256 amount) {
        if (vesting == address(0)) revert NotLaunched();
        uint256 before = IERC20(token).balanceOf(address(this));
        amount = AllocationVesting(vesting).claim();
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert UnexpectedBalance();
        emit VestedClaimed(amount);
    }

    /// @notice The collection's metadata calls, whose owner is this contract rather than the
    ///         person who created it.
    /// @dev Every launch's creator keeps these. Ripples publishes a collection's pictures after
    ///      it exists and points it at them with `setBaseURI`, so without these an agent launch
    ///      would be the one shape whose artwork can never be attached. They move no money, touch
    ///      no meter and reach nothing but this launch's own collection, so the charter means the
    ///      same thing with them as without.
    function setCollectionBaseURI(string calldata uri) external {
        _onlyCreator();
        Collection721(collection).setBaseURI(uri);
    }

    function setCollectionPlaceholderURI(string calldata uri) external {
        _onlyCreator();
        Collection721(collection).setPlaceholderURI(uri);
    }

    function freezeCollectionMetadata() external {
        _onlyCreator();
        Collection721(collection).freezeMetadata();
    }

    /// @notice Write an entry in the agent's public run log.
    function note(bytes32 digest, string calldata uri) external {
        _onlyOperator();
        emit Noted(digest, uri);
    }

    /// @notice The charter, for a reader that wants it in one call.
    function charter()
        external
        view
        returns (
            address operator,
            uint128 dailySpend,
            uint128 perCallSpend,
            uint128 dailySell,
            uint32 dailyMint,
            address[] memory payees
        )
    {
        return (OPERATOR, DAILY_SPEND, PER_CALL_SPEND, DAILY_SELL, DAILY_MINT, _payees);
    }

    /// @notice What is left of each ceiling today, so a form can show the agent's remaining
    ///         budget without knowing how the meters roll.
    function remainingToday()
        external
        view
        returns (uint256 spend, uint256 sellable, uint256 mintable)
    {
        uint64 today = uint64(block.timestamp / 1 days);
        spend = DAILY_SPEND - (_spend.day == today ? uint256(_spend.used) : 0);
        sellable = DAILY_SELL - (_sell.day == today ? uint256(_sell.used) : 0);
        mintable = DAILY_MINT - (_mint.day == today ? uint256(_mint.used) : 0);
    }

    function payees() external view returns (address[] memory) {
        return _payees;
    }

    /// @inheritdoc IERC721Receiver
    /// @dev The agent's own mints arrive here, and `Collection721` mints to its caller with a
    ///      safe transfer. Accepting anything else costs nothing: a piece sent here is stuck by
    ///      the same rule everything else is, and refusing it would only move that surprise to
    ///      the sender.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _onlyOperator() private view {
        if (msg.sender != OPERATOR) revert NotOperator();
    }

    function _onlyCreator() private view {
        if (msg.sender != CREATOR) revert NotCreator();
        if (collection == address(0)) revert NotLaunched();
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
        address input = buying ? address(QUOTE) : token;
        bool zeroForOne = Currency.unwrap(key.currency0) == input;

        // Permit2 is the router's allowance ledger. The ERC-20 approval to it is set to exactly
        // this order and cleared after, and the grant to the router expires within the window
        // above, so neither is left standing between calls.
        IERC20(input).forceApprove(address(PERMIT2), amountIn);
        PERMIT2.approve(
            input, address(ROUTER), uint160(amountIn), uint48(block.timestamp) + PERMIT_WINDOW
        );
        (spent, amountOut) =
            ROUTER.swapExactIn(key, zeroForOne, amountIn, minAmountOut, address(this), deadline);
        PERMIT2.approve(input, address(ROUTER), 0, 0);
        IERC20(input).forceApprove(address(PERMIT2), 0);
    }

    function _claim(address escrow, address asset) private returns (uint256 amount) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        // An escrow holding nothing for this launch in this asset says so by reverting, and that
        // is not a failure of this call: another escrow or the other currency may still have a
        // balance, and a caller topping the agent up should not have to know which. Only that one
        // answer is quiet. Anything else, including a child call that ran out of gas and returned
        // nothing, is a claim that did not happen and must not be reported as one.
        try IPullEscrow(escrow).claim(asset) returns (uint256 claimed) {
            amount = claimed;
        } catch (bytes memory reason) {
            if (bytes4(reason) != IPullEscrow.NothingOwed.selector) revert UnexpectedBalance();
            return 0;
        }
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert UnexpectedBalance();
    }

    /// The spending meter, shared by every call that moves quote out. Both ceilings are checked
    /// against the same number, so a day's budget cannot be spent as one transaction and a
    /// per-call limit cannot be walked around by repeating it past the day's.
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
