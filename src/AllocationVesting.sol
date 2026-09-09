// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The early-backer allocation for a linked launch. While the linked collection
///         mints, it records how much quote each minter routed into the curve here. At
///         graduation the curve hands over the reserved token slice and stamps the clock;
///         from then on each minter can claim their pro-rata share of the slice, released
///         linearly over `VEST_DURATION` once `VEST_CLIFF` has passed.
///
///         Two properties hold and are covered by the invariant suite. Nothing is claimable
///         before graduation. And the sum of every minter's claimed-plus-claimable can never
///         exceed the slice: each allocation floors `slice * contribution / total`, so the
///         allocations sum to at most the slice, and no minter's vested amount ever exceeds
///         their allocation.
contract AllocationVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable TOKEN;
    /// The bonding curve that funds the slice and stamps graduation. Nobody else can.
    address public immutable CURVE;
    /// The deployer, permitted to bind the collection once. In a factory launch this is the
    /// TokenLaunchFactory (the vesting is deployed in its context).
    address public immutable FACTORY;
    uint64 public immutable VEST_DURATION;
    uint64 public immutable VEST_CLIFF;

    /// The one collection whose mints record contributions here. Set once by the factory.
    address public collection;
    /// Graduation timestamp. `graduated` distinguishes an unset clock from timestamp zero.
    uint64 public graduatedAt;
    bool public graduated;
    /// The reserved token slice the curve reports at graduation. The curve transfers exactly
    /// this before stamping the clock, so a stray token donation cannot inflate what vests.
    ///
    /// **Two assets, two scales, and neither is named here (DQ5).** `slice` and `claimed` are
    /// raw units of `TOKEN`, which is the launch's own 18-decimal ERC-20. `contribution` and
    /// `totalContribution` are raw units of the **launch's quote**, whatever asset the linked
    /// collection settles in, at whatever decimals that asset has: 18 for WETH, 6 for a
    /// USDG-style quote, 8 for a stock token. This contract never reads either `decimals()` and
    /// never needs to, because every use of a contribution is a *ratio* against another
    /// contribution in the same asset: an allocation is `Math.mulDiv(slice, contribution,
    /// totalContribution)`, so the quote's scale cancels and only `TOKEN`'s scale survives into
    /// the payout. That is why this contract is quote-free rather than quote-parametrised, and
    /// why it needs no change for stock pairing. The consequences to keep in mind: a raw
    /// `contribution` figure is meaningless to a reader or a UI without
    /// `Collection721.QUOTE_DECIMALS()` beside it, and a 6-decimal launch's `totalContribution`
    /// is twelve orders of magnitude smaller than an 18-decimal one's for the same money. So
    /// no threshold, floor or display rule anywhere may be written against these numbers as if
    /// they were wei. `VestingFactoryAdversarial.t.sol` fuzzes the slice over a 1e6..1e18
    /// contribution scale to hold that.
    uint256 public slice;
    uint256 public totalContribution;
    mapping(address minter => uint256) public contribution;
    mapping(address minter => uint256) public claimed;
    mapping(address minter => bool) public finalized;
    uint256 public totalClaimed;
    uint256 public totalFinalizedContribution;

    event CollectionSet(address indexed collection);
    event ContributionRecorded(address indexed minter, uint256 amount, uint256 total);
    event Graduated(uint64 timestamp, uint256 slice);
    event Claimed(address indexed minter, uint256 amount);
    event BeneficiaryFinalized(address indexed minter, uint256 contribution);
    event SurplusBurned(uint256 amount);

    error ZeroAddress();
    error NotAContract();
    error NotFactory();
    error NotCollection();
    error NotCurve();
    error CollectionAlreadySet();
    error CollectionUnset();
    error AlreadyGraduated();
    error NothingToClaim();
    error InvalidGraduation();
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

    /// @notice Bind the recording collection, once, at deploy time. Only the factory that
    ///         deployed this contract can, and only before any contribution could be recorded.
    function setCollection(address collection_) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (collection != address(0)) revert CollectionAlreadySet();
        if (collection_ == address(0)) revert ZeroAddress();
        if (collection_.code.length == 0) revert NotAContract();
        collection = collection_;
        emit CollectionSet(collection_);
    }

    /// @notice Credit a minter's routed quote toward their future allocation. Only the linked
    ///         collection may call, and only before graduation snapshots the contributions.
    function recordContribution(address minter, uint256 amount) external {
        if (msg.sender != collection) revert NotCollection();
        if (graduated) revert AlreadyGraduated();
        if (amount == 0) return;
        if (minter == address(0)) revert ZeroAddress();
        contribution[minter] += amount;
        uint256 total = totalContribution + amount;
        totalContribution = total;
        emit ContributionRecorded(minter, amount, total);
    }

    /// @notice Snapshot the contributions and start the vesting clock. Called by the curve
    ///         during `graduate()`, after it has transferred the reserved slice here. The
    ///         slice is the figure the curve reports, not the contract balance, so a token
    ///         donation before graduation cannot inflate what the minters can draw.
    function onGraduation(uint256 slice_) external nonReentrant {
        if (msg.sender != CURVE) revert NotCurve();
        if (collection == address(0)) revert CollectionUnset();
        if (graduated) revert AlreadyGraduated();
        if (slice_ == 0 || totalContribution == 0) revert InvalidGraduation();
        if (TOKEN.balanceOf(address(this)) < slice_) revert Underfunded();
        if (block.timestamp > type(uint64).max) revert TimestampOverflow();

        graduated = true;
        graduatedAt = uint64(block.timestamp);
        slice = slice_;
        emit Graduated(graduatedAt, slice_);
    }

    /// A minter's full allocation once graduation has fixed the slice: pro-rata to their
    /// contribution, floored so the allocations across all minters sum to at most the slice.
    function allocationOf(address minter) public view returns (uint256) {
        uint256 total = totalContribution;
        if (total == 0) return 0;
        return Math.mulDiv(slice, contribution[minter], total);
    }

    /// How much of a minter's allocation has vested by now: zero before graduation and before
    /// the cliff, then linear over the duration, capped at the full allocation.
    function vestedOf(address minter) public view returns (uint256) {
        if (!graduated) return 0;
        uint64 g = graduatedAt;
        uint256 start = uint256(g) + VEST_CLIFF;
        if (block.timestamp < start) return 0;
        uint256 alloc = allocationOf(minter);
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= VEST_DURATION) return alloc;
        return Math.mulDiv(alloc, elapsed, VEST_DURATION);
    }

    function claimable(address minter) public view returns (uint256) {
        uint256 vested = vestedOf(minter);
        uint256 taken = claimed[minter];
        return vested > taken ? vested - taken : 0;
    }

    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[msg.sender] += amount;
        totalClaimed += amount;
        if (claimed[msg.sender] == allocationOf(msg.sender)) _finalize(msg.sender);
        _transferExact(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Mark a zero-allocation beneficiary complete so the final rounding dust can be
    ///         burned once every contribution is accounted for. Positive allocations finalize
    ///         automatically when their beneficiary claims in full.
    function finalizeBeneficiary(address minter) external {
        if (!graduated) revert InvalidGraduation();
        if (finalized[minter]) revert AlreadyFinalized();
        if (contribution[minter] == 0 || claimed[minter] != allocationOf(minter)) {
            revert NothingToFinalize();
        }
        _finalize(minter);
    }

    /// @notice Burn tokens donated above the still-reserved vesting balance. The full unclaimed
    ///         slice remains protected, so calling this cannot reduce any beneficiary's claim.
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

    function _finalize(address minter) private {
        finalized[minter] = true;
        uint256 weight = contribution[minter];
        totalFinalizedContribution += weight;
        emit BeneficiaryFinalized(minter, weight);
    }
}
