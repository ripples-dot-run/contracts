// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { LaunchParams } from "./TokenLaunchFactory.sol";
import { FundedLink } from "./FundedTokenLaunchFactory.sol";
import { CollectionParams, Collection721 } from "./Collection721.sol";
import { LPLocker } from "./LPLocker.sol";
import { ILaunchHook } from "./hook/interfaces/ILaunchHook.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";
import { HolderDistributorFactory } from "./HolderDistributorFactory.sol";
import { IWETH9 } from "./DualFill.sol";

struct FundedFillInit {
    bytes32 key;
    bytes32 assetId;
    bytes32 paramsHash;
    address creator;
    address token;
    address quote;
    address feeToken;
    address keeper;
    bool nativeWrap;
    address hook;
    address holderFactory;
    bool routeToHolders;
    uint256 inventory;
    uint256 target;
    uint256 minTokensOut;
    uint256 feeBudget;
    uint64 publicUntil;
    uint64 deadline;
}

interface IFundedFillCoordinator {
    function launchFee() external view returns (uint256);
    function openMarket(
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) external returns (address locker, address collection, address vesting);
}

/// Contributor deposits and the creator's arrived bridge inventory have separate claims.
/// Neither the coordinator nor the keeper can withdraw either balance for itself.
contract FundedFill is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Filling,
        Full,
        Opened,
        Cancelled
    }

    uint64 public constant OPEN_GRACE = 15 minutes;
    uint64 public constant WITHDRAW_FREEZE = 5 minutes;
    uint256 public constant MAX_WALLET_SHARE_BPS = 2_500;
    address public immutable COORDINATOR;
    bytes32 public immutable KEY;
    bytes32 public immutable ASSET_ID;
    bytes32 public immutable PARAMS_HASH;
    address public immutable CREATOR;
    address public immutable TOKEN;
    address public immutable QUOTE;
    address public immutable FEE_TOKEN;
    address public immutable KEEPER;
    bool public immutable NATIVE_WRAP;
    address public immutable HOOK;
    address public immutable HOLDER_FACTORY;
    bool public immutable ROUTE_TO_HOLDERS;
    uint256 public immutable INVENTORY;
    uint256 public immutable TARGET;
    uint256 public immutable MIN_TOKENS_OUT;
    uint256 public immutable FEE_BUDGET;
    uint64 public immutable PUBLIC_UNTIL;
    uint64 public immutable DEADLINE;

    Status private _stored;
    address public locker;
    address public collection;
    address public vesting;
    address public holderDistributor;
    uint64 public openedAt;
    bool public inventoryReturned;
    bool public feeBudgetSettled;
    bool public feesHandedOver;
    uint256 public totalDeposited;
    uint256 public contributorCount;
    uint256 public tokensForFill;
    uint256 public quoteBack;
    uint256 public claimedDeposits;
    uint256 public claimedTokens;
    uint256 public claimedQuote;
    mapping(address account => uint256 amount) public depositOf;

    event Deposited(address indexed account, uint256 amount, uint256 total);
    event Withdrawn(address indexed account, uint256 amount);
    event Cancelled();
    event Opened(address indexed locker, uint256 tokens, uint256 quoteBack);
    event Claimed(address indexed account, uint256 tokens, uint256 quote);
    event Refunded(address indexed account, uint256 amount);
    event InventoryReturned(uint256 amount);
    event FeeBudgetReturned(uint256 amount);
    event CreatorFeesForwarded(uint256 quote, uint256 tokens);
    event HolderRoutePrepared(address indexed distributor);

    error NotCreator();
    error NotKeeper();
    error NotFilling();
    error NotFull();
    error NotOpened();
    error NotRefundable();
    error DeadlinePassed();
    error WithdrawalsFrozen();
    error ZeroAmount();
    error WalletLimitReached();
    error NothingDeposited();
    error AlreadySettled();
    error ParamsMismatch();
    error FeeAboveBudget();
    error WrongPayment();
    error NativeUnsupported();
    error TransferFailed();
    error SnipeWindowOpen();

    constructor(FundedFillInit memory init) {
        COORDINATOR = msg.sender;
        KEY = init.key;
        ASSET_ID = init.assetId;
        PARAMS_HASH = init.paramsHash;
        CREATOR = init.creator;
        TOKEN = init.token;
        QUOTE = init.quote;
        FEE_TOKEN = init.feeToken;
        KEEPER = init.keeper;
        NATIVE_WRAP = init.nativeWrap;
        HOOK = init.hook;
        HOLDER_FACTORY = init.holderFactory;
        ROUTE_TO_HOLDERS = init.routeToHolders;
        INVENTORY = init.inventory;
        TARGET = init.target;
        MIN_TOKENS_OUT = init.minTokensOut;
        FEE_BUDGET = init.feeBudget;
        PUBLIC_UNTIL = init.publicUntil;
        DEADLINE = init.deadline;
    }

    receive() external payable { }

    function deposit(uint256 amount) external nonReentrant returns (uint256 accepted) {
        accepted = _accepted(msg.sender, amount);
        IERC20 quote = IERC20(QUOTE);
        uint256 before = quote.balanceOf(address(this));
        uint256 fromBefore = quote.balanceOf(msg.sender);
        uint256 supplyBefore = quote.totalSupply();
        quote.safeTransferFrom(msg.sender, address(this), accepted);
        if (
            quote.balanceOf(address(this)) != before + accepted
                || quote.balanceOf(msg.sender) != fromBefore - accepted
                || quote.totalSupply() != supplyBefore
        ) revert WrongPayment();
        _book(msg.sender, accepted);
    }

    function depositEth() external payable nonReentrant returns (uint256 accepted) {
        if (!NATIVE_WRAP) revert NativeUnsupported();
        accepted = _accepted(msg.sender, msg.value);
        _book(msg.sender, accepted);
        uint256 before = IERC20(QUOTE).balanceOf(address(this));
        IWETH9(QUOTE).deposit{ value: accepted }();
        if (IERC20(QUOTE).balanceOf(address(this)) != before + accepted) revert WrongPayment();
        if (msg.value != accepted) {
            (bool ok,) = msg.sender.call{ value: msg.value - accepted }("");
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
        totalDeposited -= amount;
        if (held == amount) contributorCount--;
        _transferExact(QUOTE, msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function cancel() external nonReentrant {
        if (msg.sender != CREATOR) revert NotCreator();
        if (status() != Status.Filling) revert NotFilling();
        if (block.timestamp >= DEADLINE) revert DeadlinePassed();
        _stored = Status.Cancelled;
        emit Cancelled();
    }

    function abort() external nonReentrant {
        if (msg.sender != KEEPER) revert NotKeeper();
        if (_stored != Status.Filling) revert NotFilling();
        _stored = Status.Cancelled;
        emit Cancelled();
    }

    function open(LaunchParams calldata p, CollectionParams calldata np, FundedLink calldata link)
        external
        nonReentrant
    {
        if (msg.sender != KEEPER) revert NotKeeper();
        if (status() != Status.Full) revert NotFull();
        if (block.timestamp >= uint256(DEADLINE) + OPEN_GRACE) revert DeadlinePassed();
        if (keccak256(abi.encode(p, np, link)) != PARAMS_HASH) revert ParamsMismatch();
        uint256 fee = IFundedFillCoordinator(COORDINATOR).launchFee();
        if (fee > FEE_BUDGET) revert FeeAboveBudget();
        // Credits from an unrelated pool must not become this opening buy's rebate.
        _claimOwed(HOOK, QUOTE);
        _claimOwed(HOOK, TOKEN);
        uint256 quoteBefore = IERC20(QUOTE).balanceOf(address(this));
        uint256 tokenBefore = IERC20(TOKEN).balanceOf(address(this));
        if (tokenBefore < INVENTORY) revert WrongPayment();
        IERC20(TOKEN).forceApprove(COORDINATOR, INVENTORY);
        IERC20(QUOTE).forceApprove(COORDINATOR, TARGET + (QUOTE == FEE_TOKEN ? fee : 0));
        if (QUOTE != FEE_TOKEN) IERC20(FEE_TOKEN).forceApprove(COORDINATOR, fee);
        (locker, collection, vesting) = IFundedFillCoordinator(COORDINATOR).openMarket(p, np, link);
        IERC20(TOKEN).forceApprove(COORDINATOR, 0);
        IERC20(QUOTE).forceApprove(COORDINATOR, 0);
        if (QUOTE != FEE_TOKEN) IERC20(FEE_TOKEN).forceApprove(COORDINATOR, 0);
        if (
            LPLocker(locker).TOKEN() != TOKEN || LPLocker(locker).QUOTE() != QUOTE
                || LPLocker(locker).HOOK() != HOOK
        ) {
            revert WrongPayment();
        }
        _claimOwed(HOOK, TOKEN);
        _claimOwed(HOOK, QUOTE);
        tokensForFill = IERC20(TOKEN).balanceOf(address(this)) - (tokenBefore - INVENTORY);
        if (tokensForFill < MIN_TOKENS_OUT) revert WrongPayment();
        uint256 spent = quoteBefore - IERC20(QUOTE).balanceOf(address(this));
        quoteBack = totalDeposited + (QUOTE == FEE_TOKEN ? fee : 0) - spent;
        _stored = Status.Opened;
        openedAt = uint64(block.timestamp);
        feeBudgetSettled = true;
        if (collection != address(0)) Collection721(collection).freezeMetadata();
        if (ROUTE_TO_HOLDERS) {
            holderDistributor = HolderDistributorFactory(HOLDER_FACTORY).createFor(TOKEN);
            emit HolderRoutePrepared(holderDistributor);
        }
        uint256 unspent = FEE_BUDGET - fee;
        if (unspent != 0) _transferExact(FEE_TOKEN, CREATOR, unspent);
        emit FeeBudgetReturned(unspent);
        emit Opened(locker, tokensForFill, quoteBack);
    }

    function claimFor(address account)
        external
        nonReentrant
        returns (uint256 tokens, uint256 quote)
    {
        if (_stored != Status.Opened) revert NotOpened();
        uint256 amount = depositOf[account];
        if (amount == 0) revert NothingDeposited();
        (tokens, quote) = _shares(amount);
        depositOf[account] = 0;
        claimedDeposits += amount;
        claimedTokens += tokens;
        claimedQuote += quote;
        if (tokens != 0) _transferExact(TOKEN, account, tokens);
        if (quote != 0) _transferExact(QUOTE, account, quote);
        emit Claimed(account, tokens, quote);
    }

    function refundFor(address account) external nonReentrant returns (uint256 amount) {
        if (!refundable()) revert NotRefundable();
        amount = depositOf[account];
        if (amount == 0) revert NothingDeposited();
        depositOf[account] = 0;
        totalDeposited -= amount;
        contributorCount--;
        _transferExact(QUOTE, account, amount);
        emit Refunded(account, amount);
    }

    function returnInventory() external nonReentrant {
        if (!refundable()) revert NotRefundable();
        if (inventoryReturned) revert AlreadySettled();
        inventoryReturned = true;
        _transferExact(TOKEN, CREATOR, INVENTORY);
        emit InventoryReturned(INVENTORY);
    }

    function returnFeeBudget() external nonReentrant {
        if (!refundable()) revert NotRefundable();
        if (feeBudgetSettled) revert AlreadySettled();
        feeBudgetSettled = true;
        _transferExact(FEE_TOKEN, CREATOR, FEE_BUDGET);
        emit FeeBudgetReturned(FEE_BUDGET);
    }

    function claimFees() external nonReentrant returns (uint256 quote, uint256 tokens) {
        if (_stored != Status.Opened) revert NotOpened();
        address hook = LPLocker(locker).HOOK();
        _claimOwed(hook, QUOTE);
        _claimOwed(hook, TOKEN);
        _claimOwed(locker, QUOTE);
        _claimOwed(locker, TOKEN);
        if (collection != address(0)) _claimOwed(collection, QUOTE);
        uint256 royalties = address(this).balance;
        if (NATIVE_WRAP && royalties != 0) IWETH9(QUOTE).deposit{ value: royalties }();
        quote = _surplus(QUOTE, quoteBack - claimedQuote);
        tokens = _surplus(TOKEN, tokensForFill - claimedTokens);
        address recipient = feeRecipient();
        if (quote != 0) _transferExact(QUOTE, recipient, quote);
        if (tokens != 0) _transferExact(TOKEN, recipient, tokens);
        emit CreatorFeesForwarded(quote, tokens);
    }

    function handOverFees() external nonReentrant {
        if (_stored != Status.Opened) revert NotOpened();
        if (feesHandedOver) revert AlreadySettled();
        if (block.timestamp < openedAt + 3 seconds) revert SnipeWindowOpen();
        feesHandedOver = true;
        ILaunchHook(LPLocker(locker).HOOK())
            .setCreatorFeeRecipient(PoolId.wrap(LPLocker(locker).poolId()), feeRecipient());
    }

    function feeRecipient() public view returns (address) {
        return ROUTE_TO_HOLDERS ? holderDistributor : CREATOR;
    }

    function status() public view returns (Status) {
        if (_stored != Status.Filling) return _stored;
        if (totalDeposited >= TARGET && block.timestamp >= PUBLIC_UNTIL) return Status.Full;
        return Status.Filling;
    }

    function refundable() public view returns (bool) {
        Status current = status();
        return current == Status.Cancelled
            || (current == Status.Filling && block.timestamp >= DEADLINE)
            || (current == Status.Full && block.timestamp >= uint256(DEADLINE) + OPEN_GRACE);
    }

    function claimable(address account) external view returns (uint256 tokens, uint256 quote) {
        uint256 amount = depositOf[account];
        return _stored == Status.Opened && amount != 0 ? _shares(amount) : (uint256(0), uint256(0));
    }

    function _accepted(address account, uint256 amount) private view returns (uint256) {
        if (status() != Status.Filling) revert NotFilling();
        if (block.timestamp >= DEADLINE) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();
        uint256 room;
        if (block.timestamp < PUBLIC_UNTIL) {
            uint256 ceiling = Math.mulDiv(TARGET, MAX_WALLET_SHARE_BPS, 10_000);
            if (depositOf[account] >= ceiling) revert WalletLimitReached();
            room = ceiling - depositOf[account];
        } else {
            room = TARGET - totalDeposited;
        }
        uint256 accepted = amount > room ? room : amount;
        if (accepted == 0) revert ZeroAmount();
        return accepted;
    }

    function _book(address account, uint256 amount) private {
        if (depositOf[account] == 0) contributorCount++;
        depositOf[account] += amount;
        totalDeposited += amount;
        emit Deposited(account, amount, totalDeposited);
    }

    function _shares(uint256 amount) private view returns (uint256 tokens, uint256 quote) {
        if (claimedDeposits + amount == totalDeposited) {
            return (tokensForFill - claimedTokens, quoteBack - claimedQuote);
        }
        return (
            Math.mulDiv(tokensForFill, amount, totalDeposited),
            Math.mulDiv(quoteBack, amount, totalDeposited)
        );
    }

    function _claimOwed(address escrow, address asset) private {
        if (IPullEscrow(escrow).owed(asset, address(this)) != 0) IPullEscrow(escrow).claim(asset);
    }

    function _surplus(address asset, uint256 reserved) private view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > reserved ? balance - reserved : 0;
    }

    function _transferExact(address asset, address to, uint256 amount) private {
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();
        token.safeTransfer(to, amount);
        if (
            token.balanceOf(address(this)) != before - amount
                || token.balanceOf(to) != toBefore + amount || token.totalSupply() != supplyBefore
        ) revert WrongPayment();
    }
}
