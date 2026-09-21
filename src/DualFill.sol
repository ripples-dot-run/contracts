// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { LPLocker } from "./LPLocker.sol";
import { DevBuyParams, LaunchParams, TokenLaunchFactory } from "./TokenLaunchFactory.sol";
import { ILaunchHook } from "./hook/interfaces/ILaunchHook.sol";
import { IDualFill } from "./interfaces/IDualFill.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";

/// The one call a native-wrap rail needs from its quote, which is canonical WETH9 on 4663.
interface IWETH9 {
    function deposit() external payable;
}

/// @title DualFill
/// @notice One side of a Dual Fill before it opens: a pooled opening buy that anyone can join,
///         held until it is full and then spent, whole, as the launch's own first trade.
///
/// **A contribution has three ways out, and each one is its contributor's.** It comes back
/// through `withdraw` while the side is filling or `refundFor` once the side is refundable, or it
/// is spent as part of the opening buy, whose tokens and unspent quote leave only through
/// `claimFor` to the account that paid for them. The keeper can open a full side and abort a side
/// of a default-mode Dual Fill; neither sends money anywhere else, and there is no owner, no
/// sweep and no setter.
///
/// **Everyone on a side pays one price.** Until `PUBLIC_UNTIL` a side takes deposits above its
/// target, so the first block after it was created is worth nothing more than the last. The
/// opening buy is exactly `TARGET`, and each contributor's share of its tokens and of the quote it
/// did not spend is pro rata to what they put in, with the last claim taking the rounding.
///
/// **The last block of the window does not decide the side.** During the window one account holds
/// at most `MAX_WALLET_SHARE_BPS` of the target, so a deposit landed just before `PUBLIC_UNTIL`
/// cannot take most of an oversubscribed opening buy. Withdrawals stop `WITHDRAW_FREEZE` before
/// it, so a total that looks oversubscribed at the end cannot be pulled away in the final block.
/// After the window a side below target takes anyone's deposit up to what it still needs.
///
/// **This contract is the launch's creator of record.** `TokenLaunchFactory` records its caller,
/// so the hook credits the creator's share of every trade here until `handOverFees`, and the
/// locker credits its creator split here for good. `claimFees` forwards all of it to `CREATOR`.
///
/// **A side escrows what its launch settles in.** `QUOTE` is the asset the launch names, WETH or
/// any quote the registry admits, and deposits, refunds, the opening buy and the quote leg of
/// every claim move that asset. The bond is `FEE_TOKEN` whatever the quote, because the launch
/// fee is. On a rail that wraps native currency it wraps into the fee token, so only a side
/// whose quote is the fee token takes native deposits.
contract DualFill is IDualFill, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant OPEN_GRACE = 15 minutes;
    uint256 public constant MAX_WALLET_SHARE_BPS = 2_500;
    uint64 public constant WITHDRAW_FREEZE = 5 minutes;
    uint256 internal constant MAX_PAGE = 500;

    address public immutable FACTORY;
    address public immutable LAUNCH_FACTORY;
    /// The asset this side escrows and its market settles in.
    address public immutable QUOTE;
    /// The asset the bond is held in and the launch fee is paid from.
    address public immutable FEE_TOKEN;
    address public immutable KEEPER;
    /// Whether `depositEth` is open: the rail wraps native currency and this side's quote is what
    /// it wraps into.
    bool public immutable NATIVE_WRAP;
    address public immutable CREATOR;
    bytes32 public immutable DUAL_FILL_KEY;
    uint256 public immutable TARGET;
    uint64 public immutable DEADLINE;
    uint64 public immutable PUBLIC_UNTIL;
    bool public immutable OPEN_ALONE;
    uint256 public immutable FEE_BUDGET;
    bytes32 public immutable PARAMS_HASH;

    /// Only `Filling`, `Opened` and `Cancelled` are ever written. `Full` depends on the clock as
    /// well as the total, so no transaction could keep a stored one true; `status()` derives it.
    Status private _stored;
    uint64 public openedAt;
    address public token;
    bool public feesHandedOver;
    bool public feeBudgetSettled;
    address public locker;
    bytes32 public poolId;
    address private _hook;

    uint256 public totalDeposited;
    uint256 public contributorCount;
    uint256 public tokensForFill;
    uint256 public quoteBack;
    uint256 public claimedDeposits;
    uint256 public claimedTokens;
    uint256 public claimedQuote;

    mapping(address account => uint256) public depositOf;
    mapping(address account => bool) private _hasDeposited;
    address[] private _depositors;

    constructor(Init memory init) {
        FACTORY = msg.sender;
        LAUNCH_FACTORY = init.launchFactory;
        QUOTE = init.quote;
        FEE_TOKEN = init.feeToken;
        KEEPER = init.keeper;
        NATIVE_WRAP = init.nativeWrap && init.quote == init.feeToken;
        CREATOR = init.creator;
        DUAL_FILL_KEY = init.dualFillKey;
        TARGET = init.target;
        DEADLINE = init.deadline;
        PUBLIC_UNTIL = init.publicUntil;
        OPEN_ALONE = init.openAlone;
        FEE_BUDGET = init.feeBudget;
        PARAMS_HASH = init.paramsHash;
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256 accepted) {
        accepted = _accepted(msg.sender, amount);
        IERC20 quote = IERC20(QUOTE);
        uint256 before = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), accepted);
        uint256 received = quote.balanceOf(address(this));
        if (received < before || received - before != accepted) revert WrongPayment();
        _book(msg.sender, accepted, false);
    }

    /// Booked before the wrap and the change, so the only external calls happen once the deposit
    /// is already on the ledger. A contract that re-enters from the change refund meets the guard.
    function depositEth() external payable nonReentrant returns (uint256 accepted) {
        if (!NATIVE_WRAP) revert NativeUnsupported();
        accepted = _accepted(msg.sender, msg.value);
        _book(msg.sender, accepted, true);

        IERC20 quote = IERC20(QUOTE);
        uint256 before = quote.balanceOf(address(this));
        IWETH9(QUOTE).deposit{ value: accepted }();
        if (quote.balanceOf(address(this)) != before + accepted) revert WrongPayment();

        uint256 change = msg.value - accepted;
        if (change != 0) {
            (bool ok,) = msg.sender.call{ value: change }("");
            if (!ok) revert TransferFailed();
        }
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (status() != Status.Filling) revert NotFilling();
        if (block.timestamp >= DEADLINE) revert DeadlinePassed();
        if (block.timestamp >= PUBLIC_UNTIL - WITHDRAW_FREEZE && block.timestamp < PUBLIC_UNTIL) {
            revert WithdrawalsFrozen();
        }
        if (amount == 0) revert ZeroAmount();
        uint256 held = depositOf[msg.sender];
        if (amount > held) revert NothingDeposited();

        depositOf[msg.sender] = held - amount;
        uint256 total = totalDeposited - amount;
        totalDeposited = total;
        if (held == amount) contributorCount--;
        emit Withdrawn(msg.sender, amount, total);
        IERC20(QUOTE).safeTransfer(msg.sender, amount);
    }

    function cancel() external nonReentrant {
        if (msg.sender != CREATOR) revert NotCreator();
        if (status() != Status.Filling) revert NotFilling();
        if (block.timestamp >= DEADLINE) revert DeadlinePassed();
        _stored = Status.Cancelled;
        emit Cancelled();
    }

    /// The keeper's way to hand a side of a Dual Fill that can no longer open back to the people
    /// in it, hours before its own deadline would. An open-alone creator chose to let a full side
    /// trade on its own, so the keeper has no say over whether theirs opens.
    function abort() external nonReentrant {
        if (msg.sender != KEEPER) revert NotKeeper();
        if (OPEN_ALONE) revert OpenAloneFill();
        Status current = status();
        if (current != Status.Filling && current != Status.Full) revert NotFilling();
        _stored = Status.Cancelled;
        emit Aborted(msg.sender);
    }

    /// Create the launch with the whole target as its opening buy. The opening buy runs through
    /// the launch's own locker, which the hook exempts from the opening tax, so the fill pays the
    /// trade fee and nothing else.
    function open(LaunchParams calldata p)
        external
        nonReentrant
        returns (address token_, address locker_)
    {
        if (status() != Status.Full) revert NotFull();
        if (block.timestamp >= uint256(DEADLINE) + OPEN_GRACE) revert OpenWindowClosed();
        if (msg.sender != KEEPER && !(OPEN_ALONE && block.timestamp >= DEADLINE)) {
            revert NotKeeper();
        }
        if (keccak256(abi.encode(p)) != PARAMS_HASH) revert ParamsMismatch();
        uint256 fee = TokenLaunchFactory(LAUNCH_FACTORY).launchFee();
        if (fee > FEE_BUDGET) revert FeeAboveBudget();

        uint256 quoteBefore = IERC20(QUOTE).balanceOf(address(this));
        (token_, locker_) = _launch(p, fee);
        _settleOpening(token_, locker_, fee, quoteBefore);
    }

    function claim() external nonReentrant returns (uint256 tokens, uint256 quote) {
        return _claim(msg.sender);
    }

    function claimFor(address account)
        external
        nonReentrant
        returns (uint256 tokens, uint256 quote)
    {
        return _claim(account);
    }

    function refundFor(address account) external nonReentrant returns (uint256 amount) {
        if (!refundable()) revert NotRefundable();
        amount = depositOf[account];
        if (amount == 0) revert NothingDeposited();
        depositOf[account] = 0;
        totalDeposited -= amount;
        contributorCount--;
        emit Refunded(account, amount);
        IERC20(QUOTE).safeTransfer(account, amount);
    }

    /// The bond comes back the moment the side is refundable, not after the last contributor has
    /// taken theirs: it was only ever there to pay a launch that is no longer going to happen.
    function returnFeeBudget() external nonReentrant returns (uint256 amount) {
        if (!refundable()) revert NotRefundable();
        if (feeBudgetSettled) revert AlreadySettled();
        feeBudgetSettled = true;
        amount = FEE_BUDGET;
        emit FeeBudgetReturned(amount);
        IERC20(FEE_TOKEN).safeTransfer(CREATOR, amount);
    }

    /// Everything this fill holds beyond what contributors can still claim is the creator's.
    /// Measured off the balance rather than off what this call claimed, because `claimFor` on
    /// the hook and on the locker is permissionless and a stranger can move either credit in
    /// here at any time.
    function claimFees() external nonReentrant returns (uint256 quote, uint256 tokenAmount) {
        if (_stored != Status.Opened) revert NotOpened();
        address launched = token;
        address lpLocker = locker;
        _claimOwed(_hook, QUOTE);
        _claimOwed(_hook, launched);
        _claimOwed(lpLocker, QUOTE);
        _claimOwed(lpLocker, launched);

        quote = _surplus(QUOTE, quoteBack - claimedQuote);
        tokenAmount = _surplus(launched, tokensForFill - claimedTokens);
        if (quote != 0) IERC20(QUOTE).safeTransfer(CREATOR, quote);
        if (tokenAmount != 0) IERC20(launched).safeTransfer(CREATOR, tokenAmount);
        emit CreatorFeesForwarded(quote, tokenAmount);
    }

    /// Points the hook's creator share at the creator. Not inside `open`: the hook exempts a new
    /// recipient from the opening tax, and the creator is not owed that exemption.
    function handOverFees() external nonReentrant {
        if (_stored != Status.Opened) revert NotOpened();
        if (feesHandedOver) revert AlreadyHandedOver();
        uint256 window = TokenLaunchFactory(LAUNCH_FACTORY).SNIPE_WINDOW();
        if (block.timestamp < openedAt + window) revert SnipeWindowOpen();
        feesHandedOver = true;
        ILaunchHook(_hook).setCreatorFeeRecipient(PoolId.wrap(poolId), CREATOR);
        emit FeesHandedOver(CREATOR);
    }

    function status() public view returns (Status) {
        Status stored = _stored;
        if (stored != Status.Filling) return stored;
        if (totalDeposited >= TARGET && block.timestamp >= PUBLIC_UNTIL) return Status.Full;
        return Status.Filling;
    }

    function refundable() public view returns (bool) {
        Status current = status();
        if (current == Status.Cancelled) return true;
        if (current == Status.Filling) return block.timestamp >= DEADLINE;
        if (current == Status.Full) return block.timestamp >= uint256(DEADLINE) + OPEN_GRACE;
        return false;
    }

    function remaining() external view returns (uint256) {
        uint256 total = totalDeposited;
        return status() == Status.Filling && total < TARGET ? TARGET - total : 0;
    }

    function claimable(address account) external view returns (uint256 tokens, uint256 quote) {
        uint256 amount = depositOf[account];
        if (_stored != Status.Opened || amount == 0) return (0, 0);
        return _shares(amount);
    }

    function depositorCount() external view returns (uint256) {
        return _depositors.length;
    }

    /// Every account that ever deposited, in first-deposit order, including those now at zero.
    function depositors(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = _depositors.length;
        if (offset >= total) return new address[](0);
        if (limit > MAX_PAGE) limit = MAX_PAGE;
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _depositors[i];
        }
    }

    function terms() external view returns (Terms memory) {
        return Terms({
            creator: CREATOR,
            dualFillKey: DUAL_FILL_KEY,
            target: TARGET,
            deadline: DEADLINE,
            publicUntil: PUBLIC_UNTIL,
            openAlone: OPEN_ALONE,
            feeBudget: FEE_BUDGET,
            paramsHash: PARAMS_HASH,
            keeper: KEEPER,
            quote: QUOTE,
            feeToken: FEE_TOKEN,
            nativeWrap: NATIVE_WRAP,
            launchFactory: LAUNCH_FACTORY
        });
    }

    function snapshot() external view returns (Snapshot memory s) {
        s.status = status();
        s.totalDeposited = totalDeposited;
        s.contributorCount = contributorCount;
        s.depositorCount = _depositors.length;
        s.openedAt = openedAt;
        s.token = token;
        s.locker = locker;
        s.poolId = poolId;
        s.tokensForFill = tokensForFill;
        s.quoteBack = quoteBack;
        s.claimedDeposits = claimedDeposits;
        s.refundable = refundable();
        s.feesHandedOver = feesHandedOver;
        s.feeBudgetSettled = feeBudgetSettled;
    }

    /// What a deposit of `amount` from `account` would be credited with. In the window it is capped
    /// at the account's remaining share of the target; past `PUBLIC_UNTIL` at what the side still
    /// needs, so the window is the only time a side can go above its target.
    function _accepted(address account, uint256 amount) private view returns (uint256 accepted) {
        if (status() != Status.Filling) revert NotFilling();
        if (block.timestamp >= DEADLINE) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();
        uint256 room;
        if (block.timestamp < PUBLIC_UNTIL) {
            uint256 ceiling = TARGET * MAX_WALLET_SHARE_BPS / 10_000;
            uint256 held = depositOf[account];
            if (held >= ceiling) revert WalletLimitReached();
            room = ceiling - held;
        } else {
            room = TARGET - totalDeposited;
        }
        accepted = amount > room ? room : amount;
        if (accepted == 0) revert ZeroAmount();
    }

    function _book(address account, uint256 amount, bool native) private {
        if (!_hasDeposited[account]) {
            _hasDeposited[account] = true;
            _depositors.push(account);
        }
        uint256 held = depositOf[account];
        if (held == 0) contributorCount++;
        depositOf[account] = held + amount;

        uint256 before = totalDeposited;
        uint256 total = before + amount;
        totalDeposited = total;
        emit Deposited(account, amount, total, native);
        if (before < TARGET && total >= TARGET) emit Filled(total);
    }

    /// The approvals cover exactly what the fee and the opening buy can take and are cleared as
    /// soon as the launch returns.
    function _launch(LaunchParams calldata p, uint256 fee)
        private
        returns (address token_, address locker_)
    {
        IERC20 quote = IERC20(QUOTE);
        bool oneAsset = FEE_TOKEN == QUOTE;
        if (oneAsset) {
            quote.forceApprove(LAUNCH_FACTORY, fee + TARGET);
        } else {
            IERC20(FEE_TOKEN).forceApprove(LAUNCH_FACTORY, fee);
            quote.forceApprove(LAUNCH_FACTORY, TARGET);
        }
        (token_, locker_) = TokenLaunchFactory(LAUNCH_FACTORY)
            .createLaunch(
                p,
                DevBuyParams({ initialBuy: TARGET, minTokensOut: 1, snipeExempt: new address[](0) })
            );
        quote.forceApprove(LAUNCH_FACTORY, 0);
        if (!oneAsset) IERC20(FEE_TOKEN).forceApprove(LAUNCH_FACTORY, 0);
        if (LPLocker(locker_).QUOTE() != QUOTE) revert QuoteMismatch();
    }

    /// The opening buy's own trade fee credits the creator's share to this contract as creator of
    /// record. It is claimed here, before the balance is read, so it reaches contributors as
    /// tokens rather than waiting in the hook for the creator's first `claimFees`.
    ///
    /// Only the token side is claimed. The buy is exact input, so its fee comes out of the tokens
    /// and never out of the quote, and any quote the hook owes this address is another launch's
    /// creator income pointed here. Claimed before `spent` is read, it would pass for quote the
    /// buy did not spend, and once larger than the fee and the buy it would stop the open. It is
    /// left for `claimFees`, which pays it to the creator.
    function _settleOpening(address token_, address locker_, uint256 fee, uint256 quoteBefore)
        private
    {
        bytes32 id = LPLocker(locker_).poolId();
        address hook = LPLocker(locker_).HOOK();
        poolId = id;
        _hook = hook;
        _claimOwed(hook, token_);

        uint256 tokens = IERC20(token_).balanceOf(address(this));
        uint256 spent = quoteBefore - IERC20(QUOTE).balanceOf(address(this));
        uint256 back = totalDeposited + (FEE_TOKEN == QUOTE ? fee : 0) - spent;
        tokensForFill = tokens;
        quoteBack = back;

        _stored = Status.Opened;
        openedAt = uint64(block.timestamp);
        token = token_;
        locker = locker_;
        feeBudgetSettled = true;

        uint256 unspent = FEE_BUDGET - fee;
        if (unspent != 0) IERC20(FEE_TOKEN).safeTransfer(CREATOR, unspent);
        emit FeeBudgetReturned(unspent);
        emit Opened(token_, locker_, id, msg.sender, fee, tokens, back);
    }

    function _claim(address account) private returns (uint256 tokens, uint256 quote) {
        if (_stored != Status.Opened) revert NotOpened();
        uint256 amount = depositOf[account];
        if (amount == 0) revert NothingDeposited();
        depositOf[account] = 0;
        (tokens, quote) = _shares(amount);
        claimedDeposits += amount;
        claimedTokens += tokens;
        claimedQuote += quote;
        emit Claimed(account, tokens, quote);
        if (tokens != 0) IERC20(token).safeTransfer(account, tokens);
        if (quote != 0) IERC20(QUOTE).safeTransfer(account, quote);
    }

    /// Pro rata, with the last claim taking whatever the floors left behind, so the pool always
    /// ends at exactly zero.
    function _shares(uint256 amount) private view returns (uint256 tokens, uint256 quote) {
        uint256 total = totalDeposited;
        if (claimedDeposits + amount == total) {
            return (tokensForFill - claimedTokens, quoteBack - claimedQuote);
        }
        return (Math.mulDiv(tokensForFill, amount, total), Math.mulDiv(quoteBack, amount, total));
    }

    function _claimOwed(address escrow, address asset) private {
        if (IPullEscrow(escrow).owed(asset, address(this)) != 0) IPullEscrow(escrow).claim(asset);
    }

    /// Clamped at zero, so a balance somebody has taken from cannot panic the call that forwards
    /// fees; contributors' outstanding claims still come first.
    function _surplus(address asset, uint256 outstanding) private view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > outstanding ? balance - outstanding : 0;
    }
}
