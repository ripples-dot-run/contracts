// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The early-backer allocation for a linked launch whose claim belongs to the piece
///         rather than to the wallet that minted it.
///
///         `AllocationVesting` is the same mechanism keyed by minter: sell the NFT and you keep
///         the vest. That rewards early risk and turns the NFT into a receipt. Here the claim
///         travels with the piece, so a buyer on the secondary market buys the remaining stream
///         with it and the collection is worth something to hold. A launch declares which of the
///         two it is at create and can never move between them.
///
///         Keyed by `(collection, tokenId)` rather than by id alone because a launch may open
///         later waves: several collections can record against one market, and piece 1 of the
///         second wave is not piece 1 of the first.
///
///         The claim follows ownership with no transfer hook and no soulbound companion. The
///         ledger is the id, `ownerOf` is read at claim time, and a piece that changes hands
///         mid-stream carries whatever it has not drawn. Nothing is claimable before graduation,
///         and the sum of every piece's claimed-plus-claimable can never exceed the slice: each
///         allocation floors `slice * contribution / total`.
contract ObjectVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable TOKEN;
    /// The locker that funds the slice and stamps graduation. Nobody else can.
    address public immutable CURVE;
    /// The deployer, permitted to bind collections. In a factory launch this is the
    /// TokenLaunchFactory, which deploys this contract in its own context.
    address public immutable FACTORY;
    uint64 public immutable VEST_DURATION;
    uint64 public immutable VEST_CLIFF;

    /// The first collection whose mints record here, bound in the launch transaction. Named the
    /// same as on `AllocationVesting` so one vocabulary reads both kinds of launch.
    address public collection;
    /// Every collection that may record: the first, plus any later wave the launch declared
    /// itself open to. Bound before graduation and never after.
    mapping(address collection => bool) public isRecorder;
    address[] public recorders;

    /// Graduation timestamp. `graduated` distinguishes an unset clock from timestamp zero.
    uint64 public graduatedAt;
    bool public graduated;

    /// The reserved token slice the locker reports at graduation. It transfers exactly this
    /// before stamping the clock, so a stray token donation cannot inflate what vests.
    ///
    /// `slice` and `claimed` are raw units of `TOKEN`. `contribution` and `totalContribution`
    /// are raw units of the launch's quote at that asset's own decimals, and are only ever
    /// divided by another contribution in the same asset, so no decimals reach this contract.
    /// The note on `AllocationVesting.slice` covers the consequences for readers and indexers.
    uint256 public slice;
    uint256 public totalContribution;
    mapping(address collection => mapping(uint256 tokenId => uint256)) public contribution;
    mapping(address collection => mapping(uint256 tokenId => uint256)) public claimed;
    mapping(address collection => mapping(uint256 tokenId => bool)) public finalized;
    uint256 public totalClaimed;
    uint256 public totalFinalizedContribution;

    event CollectionSet(address indexed collection);
    event RecorderAdded(address indexed collection);
    event ContributionRecorded(
        address indexed collection, uint256 indexed tokenId, uint256 amount, uint256 total
    );
    event Graduated(uint64 timestamp, uint256 slice);
    event Claimed(
        address indexed collection, uint256 indexed tokenId, address indexed to, uint256 amount
    );
    event PieceFinalized(address indexed collection, uint256 indexed tokenId, uint256 contribution);
    event SurplusBurned(uint256 amount);

    error ZeroAddress();
    error NotAContract();
    error NotFactory();
    error NotCollection();
    error NotCurve();
    error NotOwner();
    error AlreadyRecorder();
    error CollectionAlreadySet();
    error CollectionUnset();
    error NoRecorder();
    error AlreadyGraduated();
    error NothingToClaim();
    error InvalidGraduation();
    error InvalidRange();
    error Underfunded();
    error TransferMismatch();
    error NothingToBurn();
    error NothingToFinalize();
    error AlreadyFinalized();
    error TimestampOverflow();

    constructor(address token, address curve, uint64 vestDuration, uint64 vestCliff) {
        if (token == address(0) || curve == address(0)) revert ZeroAddress();
        if (token.code.length == 0 || curve.code.length == 0) revert NotAContract();
        TOKEN = IERC20(token);
        CURVE = curve;
        FACTORY = msg.sender;
        VEST_DURATION = vestDuration;
        VEST_CLIFF = vestCliff;
    }

    /// @notice Bind the first recording collection, once, in the launch transaction.
    function setCollection(address collection_) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (collection != address(0)) revert CollectionAlreadySet();
        if (collection_ == address(0)) revert ZeroAddress();
        if (collection_.code.length == 0) revert NotAContract();
        collection = collection_;
        _addRecorder(collection_);
        emit CollectionSet(collection_);
    }

    /// @notice Bind a later wave's collection. Graduation closes the door: after it the
    ///         contributions are snapshotted and a new collection could only dilute claims that
    ///         are already fixed.
    function addCollection(address collection_) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (collection == address(0)) revert CollectionUnset();
        if (graduated) revert AlreadyGraduated();
        if (collection_ == address(0)) revert ZeroAddress();
        if (collection_.code.length == 0) revert NotAContract();
        if (isRecorder[collection_]) revert AlreadyRecorder();
        _addRecorder(collection_);
    }

    /// @notice Credit routed quote to the pieces the mint is about to issue. Called by a bound
    ///         collection from inside its mint, before the ids exist, which is why the range is
    ///         passed rather than read: `startId` is the first id the mint will issue.
    ///
    ///         Every piece in one collection pays the same price, so the routed amount divides
    ///         evenly. The remainder goes to the first piece of the mint rather than being left
    ///         unassigned, which keeps the sum of the pieces equal to the routed total.
    function recordContribution(uint256 startId, uint256 qty, uint256 amount) external {
        if (!isRecorder[msg.sender]) revert NotCollection();
        if (graduated) revert AlreadyGraduated();
        if (amount == 0) return;
        if (qty == 0) revert InvalidRange();

        uint256 each = amount / qty;
        uint256 first = each + (amount - each * qty);
        uint256 total = totalContribution + amount;
        totalContribution = total;
        for (uint256 i = 0; i < qty; i++) {
            uint256 tokenId = startId + i;
            uint256 share = i == 0 ? first : each;
            if (share == 0) continue;
            contribution[msg.sender][tokenId] += share;
            emit ContributionRecorded(msg.sender, tokenId, share, total);
        }
    }

    /// @notice Snapshot the contributions and start the clock. Called by the locker during
    ///         settlement, after it has transferred the reserved slice here. The slice is the
    ///         figure the locker reports, not this contract's balance, so a donation before
    ///         graduation cannot inflate what the pieces can draw.
    function onGraduation(uint256 slice_) external nonReentrant {
        if (msg.sender != CURVE) revert NotCurve();
        if (recorders.length == 0) revert NoRecorder();
        if (graduated) revert AlreadyGraduated();
        if (slice_ == 0 || totalContribution == 0) revert InvalidGraduation();
        if (TOKEN.balanceOf(address(this)) < slice_) revert Underfunded();
        if (block.timestamp > type(uint64).max) revert TimestampOverflow();

        graduated = true;
        graduatedAt = uint64(block.timestamp);
        slice = slice_;
        emit Graduated(graduatedAt, slice_);
    }

    /// One piece's full allocation once graduation has fixed the slice: pro-rata to what it
    /// routed, floored so the allocations across every piece sum to at most the slice.
    function allocationOf(address wave, uint256 tokenId) public view returns (uint256) {
        uint256 total = totalContribution;
        if (total == 0) return 0;
        return Math.mulDiv(slice, contribution[wave][tokenId], total);
    }

    /// How much of a piece's allocation has vested: zero before graduation and before the
    /// cliff, then linear over the duration, capped at the full allocation.
    function vestedOf(address wave, uint256 tokenId) public view returns (uint256) {
        if (!graduated) return 0;
        uint256 start = uint256(graduatedAt) + VEST_CLIFF;
        if (block.timestamp < start) return 0;
        uint256 alloc = allocationOf(wave, tokenId);
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= VEST_DURATION) return alloc;
        return Math.mulDiv(alloc, elapsed, VEST_DURATION);
    }

    function claimable(address wave, uint256 tokenId) public view returns (uint256) {
        uint256 vested = vestedOf(wave, tokenId);
        uint256 taken = claimed[wave][tokenId];
        return vested > taken ? vested - taken : 0;
    }

    /// @notice Draw what a piece has vested. The caller must own it now; what an earlier owner
    ///         drew stays drawn, and the rest belongs to whoever holds the piece when it vests.
    function claim(address wave, uint256 tokenId) external nonReentrant returns (uint256 amount) {
        amount = _claim(wave, tokenId, msg.sender);
        if (amount == 0) revert NothingToClaim();
        _transferExact(msg.sender, amount);
    }

    /// @notice The same for a holder with several pieces of one collection, which is the common
    ///         case: one transfer instead of one per piece. Reverts if none of them owes
    ///         anything, so a caller cannot spend gas to move nothing.
    function claimMany(address wave, uint256[] calldata tokenIds)
        external
        nonReentrant
        returns (uint256 amount)
    {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            amount += _claim(wave, tokenIds[i], msg.sender);
        }
        if (amount == 0) revert NothingToClaim();
        _transferExact(msg.sender, amount);
    }

    /// @notice Mark a piece that routed nothing complete, so the final rounding dust can be
    ///         burned once every contribution is accounted for. A piece with a positive
    ///         allocation finalizes itself when it is drawn in full.
    function finalizePiece(address wave, uint256 tokenId) external {
        if (!graduated) revert InvalidGraduation();
        if (finalized[wave][tokenId]) revert AlreadyFinalized();
        if (
            contribution[wave][tokenId] == 0
                || claimed[wave][tokenId] != allocationOf(wave, tokenId)
        ) revert NothingToFinalize();
        _finalize(wave, tokenId);
    }

    /// @notice Burn tokens donated above the still-reserved balance. The full unclaimed slice
    ///         stays protected, so this can never reduce a piece's claim.
    function burnSurplus() external nonReentrant returns (uint256 amount) {
        if (!graduated) revert InvalidGraduation();
        uint256 balance = TOKEN.balanceOf(address(this));
        uint256 reserved =
            totalFinalizedContribution == totalContribution ? 0 : slice - totalClaimed;
        if (balance <= reserved) revert NothingToBurn();
        amount = balance - reserved;
        _transferExact(BURN, amount);
        emit SurplusBurned(amount);
    }

    /// How many collections record here, which is the wave count.
    function recorderCount() external view returns (uint256) {
        return recorders.length;
    }

    /// @notice Every piece of `wave` that `owner` holds in `[startId, startId + count)` with
    ///         something to draw, and what the lot comes to.
    ///
    ///         A claim that belongs to the piece cannot be read from a wallet: there is no
    ///         balance to ask for, only ids. Without this a page would ask the collection who
    ///         owns each id and then ask here what each id is owed, which is two calls per piece
    ///         for a collection that can hold a hundred thousand of them. `ownerOf` reverts on an
    ///         id that was never minted, so the window is walked rather than trusted.
    function claimableOwnedBy(address wave, address owner, uint256 startId, uint256 count)
        external
        view
        returns (uint256[] memory tokenIds, uint256 total)
    {
        uint256[] memory found = new uint256[](count);
        uint256 n;
        for (uint256 i; i < count; i++) {
            uint256 tokenId = startId + i;
            uint256 amount = claimable(wave, tokenId);
            if (amount == 0) continue;
            try IERC721(wave).ownerOf(tokenId) returns (address holder) {
                if (holder != owner) continue;
            } catch {
                continue;
            }
            found[n++] = tokenId;
            total += amount;
        }
        tokenIds = new uint256[](n);
        for (uint256 i; i < n; i++) {
            tokenIds[i] = found[i];
        }
    }

    function _addRecorder(address collection_) private {
        isRecorder[collection_] = true;
        recorders.push(collection_);
        emit RecorderAdded(collection_);
    }

    function _claim(address wave, uint256 tokenId, address to) private returns (uint256) {
        if (!isRecorder[wave]) revert NotCollection();
        uint256 amount = claimable(wave, tokenId);
        if (amount == 0) return 0;
        if (IERC721(wave).ownerOf(tokenId) != to) revert NotOwner();
        uint256 taken = claimed[wave][tokenId] + amount;
        claimed[wave][tokenId] = taken;
        totalClaimed += amount;
        if (taken == allocationOf(wave, tokenId)) _finalize(wave, tokenId);
        emit Claimed(wave, tokenId, to, amount);
        return amount;
    }

    function _transferExact(address to, uint256 amount) private {
        uint256 balanceBefore = TOKEN.balanceOf(address(this));
        uint256 toBefore = TOKEN.balanceOf(to);
        TOKEN.safeTransfer(to, amount);
        uint256 balanceAfter = TOKEN.balanceOf(address(this));
        uint256 toAfter = TOKEN.balanceOf(to);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || toAfter < toBefore || toAfter - toBefore != amount
        ) revert TransferMismatch();
    }

    function _finalize(address wave, uint256 tokenId) private {
        finalized[wave][tokenId] = true;
        uint256 weight = contribution[wave][tokenId];
        totalFinalizedContribution += weight;
        emit PieceFinalized(wave, tokenId, weight);
    }
}
