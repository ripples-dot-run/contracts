// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { ILaunchHook } from "./hook/interfaces/ILaunchHook.sol";

/// A launch's creator income, permanently routed to funded holder claims. The publisher
/// computes allocations from finalized logs; the contract enforces budgets, not their fairness.
/// Published claims never expire. There is no sweep, root replacement, or recipient rotation.
///
/// `SUBJECT` is who those holders hold. Zero is the launch's own token, which is every
/// distributor deployed before this field existed. An address is the launch's linked collection,
/// and then the income reaches whoever holds the pieces rather than whoever holds the coin: the
/// answer to a collection that goes quiet the moment its market is live. The factory reads it off
/// the launch rather than taking it, so a distributor cannot be pointed at a collection that has
/// nothing to do with the market funding it.
contract HolderDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Epoch {
        bytes32 root;
        uint64 startTime;
        uint64 endTime;
        uint256 quoteTotal;
        uint256 coinTotal;
        uint256 quoteClaimed;
        uint256 coinClaimed;
    }

    struct Claim {
        uint256 epochId;
        address account;
        uint256 quoteAmount;
        uint256 coinAmount;
        bytes32[] proof;
    }

    bytes32 public constant LEAF_TYPEHASH = keccak256(
        "HolderReward(uint256 chainId,address distributor,uint256 epochId,address account,uint256 quoteAmount,uint256 coinAmount)"
    );
    ILaunchHook public immutable HOOK;
    address public immutable TOKEN;
    /// The collection whose holders these claims are for, or zero for the token's own holders.
    /// It changes who the publisher counts and nothing else: the budgets, the roots and the
    /// claims work the same either way.
    address public immutable SUBJECT;
    address public immutable QUOTE;
    PoolId public immutable POOL_ID;
    address public immutable PUBLISHER;
    uint64 public immutable FINALITY_DELAY;
    uint64 public immutable CREATED_AT;

    uint256 public reservedQuote;
    uint256 public reservedCoin;
    mapping(uint256 epochId => mapping(address account => bool)) public claimed;
    Epoch[] private _epochs;

    event Funded(address indexed asset, uint256 amount);
    event EpochPublished(
        uint256 indexed epochId,
        bytes32 indexed root,
        uint64 startTime,
        uint64 endTime,
        uint256 quoteTotal,
        uint256 coinTotal
    );
    event Claimed(
        uint256 indexed epochId, address indexed account, uint256 quoteAmount, uint256 coinAmount
    );

    error InvalidConfiguration();
    error NotPublisher();
    error NotRouted();
    error InvalidEpoch();
    error NotFinalized();
    error InsufficientFunding();
    error InvalidAccount();
    error InvalidProof();
    error AlreadyClaimed();
    error EpochBudgetExceeded();
    error UnsupportedAsset();
    error TransferMismatch();
    error NativeTransferFailed();

    constructor(
        ILaunchHook hook,
        address token,
        address subject,
        address quote,
        PoolId poolId,
        address publisher,
        uint64 finalityDelay
    ) {
        if (
            address(hook).code.length == 0 || token.code.length == 0 || quote == token
                || (quote != address(0) && quote.code.length == 0) || publisher == address(0)
                || finalityDelay == 0
                || (subject != address(0) && (subject.code.length == 0 || subject == token))
        ) revert InvalidConfiguration();
        HOOK = hook;
        TOKEN = token;
        SUBJECT = subject;
        QUOTE = quote;
        POOL_ID = poolId;
        PUBLISHER = publisher;
        FINALITY_DELAY = finalityDelay;
        CREATED_AT = uint64(block.timestamp);
    }

    receive() external payable { }

    function routed() public view returns (bool) {
        return HOOK.configOf(POOL_ID).creatorFeeRecipient == address(this);
    }

    function epochCount() external view returns (uint256) {
        return _epochs.length;
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        if (epochId >= _epochs.length) revert InvalidEpoch();
        return _epochs[epochId];
    }

    function unallocatedQuote() public view returns (uint256) {
        return _unallocated(QUOTE, reservedQuote);
    }

    function unallocatedCoin() public view returns (uint256) {
        return _unallocated(TOKEN, reservedCoin);
    }

    /// Collect either asset independently when the issuer holds the other one.
    function syncAsset(address asset) external nonReentrant returns (uint256 amount) {
        if (asset != QUOTE && asset != TOKEN) revert UnsupportedAsset();
        return _sync(asset);
    }

    function sync() external nonReentrant returns (uint256 quoteAmount, uint256 coinAmount) {
        quoteAmount = _sync(QUOTE);
        coinAmount = _sync(TOKEN);
    }

    /// Epochs cover [startTime, endTime). The age check does not prove consensus finality:
    /// the publisher must use finalized RPC blocks, whose heights differ from RH block.number.
    /// Totals must equal the sums of the leaves; rounding dust remains unallocated.
    function publishEpoch(
        bytes32 root,
        uint64 startTime,
        uint64 endTime,
        uint256 quoteTotal,
        uint256 coinTotal
    ) external nonReentrant {
        if (msg.sender != PUBLISHER) revert NotPublisher();
        if (!routed()) revert NotRouted();
        uint256 id = _epochs.length;
        if (
            startTime < CREATED_AT || endTime <= startTime
                || (id != 0 && startTime != _epochs[id - 1].endTime)
                || ((root == bytes32(0)) != (quoteTotal == 0 && coinTotal == 0))
        ) revert InvalidEpoch();
        if (endTime > block.timestamp || block.timestamp - endTime < FINALITY_DELAY) {
            revert NotFinalized();
        }
        if (quoteTotal > unallocatedQuote() || coinTotal > unallocatedCoin()) {
            revert InsufficientFunding();
        }
        reservedQuote += quoteTotal;
        reservedCoin += coinTotal;
        _epochs.push(Epoch(root, startTime, endTime, quoteTotal, coinTotal, 0, 0));
        emit EpochPublished(id, root, startTime, endTime, quoteTotal, coinTotal);
    }

    /// Double-hashed abi.encode leaf, followed by sorted-pair keccak256 Merkle nodes.
    /// Amounts are the two tokens' raw units, with no decimals or price conversion.
    function leafHash(uint256 epochId, address account, uint256 quoteAmount, uint256 coinAmount)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        LEAF_TYPEHASH,
                        block.chainid,
                        address(this),
                        epochId,
                        account,
                        quoteAmount,
                        coinAmount
                    )
                )
            )
        );
    }

    function claim(
        uint256 epochId,
        address account,
        uint256 quoteAmount,
        uint256 coinAmount,
        bytes32[] calldata proof
    ) external nonReentrant {
        _claim(epochId, account, quoteAmount, coinAmount, proof);
    }

    /// Atomic across both assets and all requested epochs. A held transfer preserves every claim.
    function claimMany(Claim[] calldata claims) external nonReentrant {
        for (uint256 i; i < claims.length; ++i) {
            Claim calldata c = claims[i];
            _claim(c.epochId, c.account, c.quoteAmount, c.coinAmount, c.proof);
        }
    }

    function _claim(
        uint256 epochId,
        address account,
        uint256 quoteAmount,
        uint256 coinAmount,
        bytes32[] calldata proof
    ) private {
        if (account == address(0) || account == address(this)) {
            revert InvalidAccount();
        }
        if (epochId >= _epochs.length || (quoteAmount == 0 && coinAmount == 0)) {
            revert InvalidEpoch();
        }
        if (claimed[epochId][account]) revert AlreadyClaimed();
        Epoch storage epoch = _epochs[epochId];
        if (!MerkleProof.verifyCalldata(
                proof, epoch.root, leafHash(epochId, account, quoteAmount, coinAmount)
            )) revert InvalidProof();
        if (
            quoteAmount > epoch.quoteTotal - epoch.quoteClaimed
                || coinAmount > epoch.coinTotal - epoch.coinClaimed
        ) revert EpochBudgetExceeded();

        claimed[epochId][account] = true;
        epoch.quoteClaimed += quoteAmount;
        epoch.coinClaimed += coinAmount;
        reservedQuote -= quoteAmount;
        reservedCoin -= coinAmount;
        _pay(QUOTE, account, quoteAmount, reservedQuote);
        _pay(TOKEN, account, coinAmount, reservedCoin);
        emit Claimed(epochId, account, quoteAmount, coinAmount);
    }

    function _sync(address asset) private returns (uint256 amount) {
        amount = HOOK.owed(asset, address(this));
        if (amount == 0) return 0;
        uint256 beforeBalance = _balance(asset);
        uint256 paid = HOOK.claimFor(asset, address(this));
        uint256 afterBalance = _balance(asset);
        if (
            paid != amount || afterBalance < beforeBalance || afterBalance - beforeBalance != amount
        ) {
            revert TransferMismatch();
        }
        emit Funded(asset, amount);
    }

    function _unallocated(address asset, uint256 reserved) private view returns (uint256) {
        uint256 balance = _balance(asset);
        return balance > reserved ? balance - reserved : 0;
    }

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _pay(address asset, address account, uint256 amount, uint256 reserved) private {
        if (amount == 0) return;
        uint256 beforeBalance = _balance(asset);
        if (asset == address(0)) {
            (bool ok,) = account.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20 token = IERC20(asset);
            uint256 beforeRecipient = token.balanceOf(account);
            token.safeTransfer(account, amount);
            uint256 afterRecipient = token.balanceOf(account);
            if (afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount) {
                revert TransferMismatch();
            }
        }
        uint256 afterBalance = _balance(asset);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert TransferMismatch();
        }
        if (afterBalance < reserved) revert InsufficientFunding();
    }
}
