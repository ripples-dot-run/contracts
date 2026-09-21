// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LaunchParams } from "../TokenLaunchFactory.sol";

interface IDualFill {
    enum Status {
        Filling,
        Full,
        Opened,
        Cancelled
    }

    /// `quote` is the asset the side's launch names, and `nativeWrap` says whether the rail
    /// wraps native currency into `feeToken`; the fill answers `NATIVE_WRAP` true only when its
    /// quote is that asset.
    struct Init {
        address launchFactory;
        address quote;
        address feeToken;
        address keeper;
        bool nativeWrap;
        address creator;
        bytes32 dualFillKey;
        uint256 target;
        uint64 deadline;
        uint64 publicUntil;
        bool openAlone;
        uint256 feeBudget;
        bytes32 paramsHash;
    }

    struct Terms {
        address creator;
        bytes32 dualFillKey;
        uint256 target;
        uint64 deadline;
        uint64 publicUntil;
        bool openAlone;
        uint256 feeBudget;
        bytes32 paramsHash;
        address keeper;
        address quote;
        address feeToken;
        bool nativeWrap;
        address launchFactory;
    }

    struct Snapshot {
        Status status;
        uint256 totalDeposited;
        uint256 contributorCount;
        uint256 depositorCount;
        uint64 openedAt;
        address token;
        address locker;
        bytes32 poolId;
        uint256 tokensForFill;
        uint256 quoteBack;
        uint256 claimedDeposits;
        bool refundable;
        bool feesHandedOver;
        bool feeBudgetSettled;
    }

    event Deposited(address indexed account, uint256 amount, uint256 total, bool native);
    event Withdrawn(address indexed account, uint256 amount, uint256 total);
    event Filled(uint256 total);
    event Cancelled();
    event Aborted(address indexed opener);
    event Opened(
        address indexed token,
        address indexed locker,
        bytes32 indexed poolId,
        address opener,
        uint256 launchFee,
        uint256 tokensForFill,
        uint256 quoteBack
    );
    event Claimed(address indexed account, uint256 tokens, uint256 quote);
    event Refunded(address indexed account, uint256 amount);
    event FeeBudgetReturned(uint256 amount);
    event CreatorFeesForwarded(uint256 quote, uint256 token);
    event FeesHandedOver(address indexed creator);

    error NotKeeper();
    error NotCreator();
    error NotFilling();
    error DeadlinePassed();
    error NotFull();
    error OpenWindowClosed();
    error ParamsMismatch();
    error FeeAboveBudget();
    error QuoteMismatch();
    error NotOpened();
    error NothingDeposited();
    error ZeroAmount();
    error NotRefundable();
    error AlreadySettled();
    error AlreadyHandedOver();
    error SnipeWindowOpen();
    error NativeUnsupported();
    error WrongPayment();
    error TransferFailed();
    error OpenAloneFill();
    error WalletLimitReached();
    error WithdrawalsFrozen();

    function OPEN_GRACE() external view returns (uint64); // 15 minutes
    function MAX_WALLET_SHARE_BPS() external view returns (uint256); // 2,500
    function WITHDRAW_FREEZE() external view returns (uint64); // 5 minutes
    function FACTORY() external view returns (address);
    function LAUNCH_FACTORY() external view returns (address);
    function QUOTE() external view returns (address);
    function FEE_TOKEN() external view returns (address);
    function KEEPER() external view returns (address);
    function NATIVE_WRAP() external view returns (bool);
    function CREATOR() external view returns (address);
    function DUAL_FILL_KEY() external view returns (bytes32);
    function TARGET() external view returns (uint256);
    function DEADLINE() external view returns (uint64);
    function PUBLIC_UNTIL() external view returns (uint64);
    function OPEN_ALONE() external view returns (bool);
    function FEE_BUDGET() external view returns (uint256);
    function PARAMS_HASH() external view returns (bytes32);

    function status() external view returns (Status);
    function totalDeposited() external view returns (uint256);
    function contributorCount() external view returns (uint256);
    function depositorCount() external view returns (uint256);
    function depositors(uint256 offset, uint256 limit) external view returns (address[] memory);
    function depositOf(address account) external view returns (uint256);
    function openedAt() external view returns (uint64);
    function token() external view returns (address);
    function locker() external view returns (address);
    function poolId() external view returns (bytes32);
    function tokensForFill() external view returns (uint256);
    function quoteBack() external view returns (uint256);
    function claimedDeposits() external view returns (uint256);
    function claimedTokens() external view returns (uint256);
    function claimedQuote() external view returns (uint256);
    function feesHandedOver() external view returns (bool);
    function feeBudgetSettled() external view returns (bool);

    function deposit(uint256 amount) external returns (uint256 accepted);
    function depositEth() external payable returns (uint256 accepted);
    function withdraw(uint256 amount) external;
    function cancel() external;
    function abort() external;
    function open(LaunchParams calldata p) external returns (address token_, address locker_);
    function claim() external returns (uint256 tokens, uint256 quote);
    function claimFor(address account) external returns (uint256 tokens, uint256 quote);
    function refundFor(address account) external returns (uint256 amount);
    function returnFeeBudget() external returns (uint256 amount);
    function claimFees() external returns (uint256 quote, uint256 tokenAmount);
    function handOverFees() external;

    function refundable() external view returns (bool);
    function remaining() external view returns (uint256);
    function claimable(address account) external view returns (uint256 tokens, uint256 quote);
    function terms() external view returns (Terms memory);
    function snapshot() external view returns (Snapshot memory);
}
