// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The one call this router makes into a pull-escrow ledger. The hook and the lockers all expose
/// it with the same shape and none of them will pay anyone but the account named, so the escrow
/// is an argument rather than an immutable: one router serves every contract that owes it
/// without having to trust any of them.
interface IPullEscrow {
    function claimFor(address token, address account) external returns (uint256 amount);
}

/// @title QuoteFeeRouter
/// @notice The treasury for a launch on `QuoteFeeFactory`: every trade's 1% fee is credited here
///         in the quote, always, and this router is the whole policy for what happens to it.
///
/// @dev `LaunchHook` split its fee by whichever currency a trade happened to hand it, which took
///      two contracts to carry: `BurnRouter` for the leg that could arrive in either the quote or
///      the platform token, and `OpsRouter` for the same. `QuoteFeeHook` never credits its
///      treasury anything but the quote, so one contract now carries the whole policy as a
///      percentage split instead of a pair of currency switches:
///
///      - `BURN_SHARE_BPS` (70%) to `BUYBACK`, which spends it buying the platform token on the
///        open market and burns what it buys. Spent, never sent to a burn address directly: the
///        quote itself is never the platform's supply to destroy.
///      - The rest (30%) to `SAFE`, whole. Operating revenue, exactly as `OpsRouter`'s quote leg
///        was.
///
///      Both the split and both destinations are fixed at construction. There is no owner and no
///      setter: nothing here is a decision that gets remade, only arithmetic that gets applied.
///      `sweepUnknown` is the one guardian power, for an asset this router has no rule for, and
///      it refuses the quote by name, so no key can route the fee itself anywhere but the split
///      above.
contract QuoteFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// The share that buys and burns. A real constant: no function on this contract can change
    /// it, and there is no owner to call one if there were.
    uint256 public constant BURN_SHARE_BPS = 7_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// The asset every trade's fee arrives in. Routed by the split below, never swept.
    IERC20 public immutable QUOTE;
    /// `BuybackBurner`. Receives `BURN_SHARE_BPS` of every routed amount and spends it buying and
    /// burning the platform token.
    ///
    /// Fixed at construction with everything else here, so a `BuybackBurner` deployed only to
    /// have an address to point this at, with no keeper and no venue wired yet, cannot be
    /// replaced once this router is live: the only way out is a full redeploy of this contract
    /// and `QuoteFeeFactory.setTreasury()` to the new one. Confirm the burner named here is fully
    /// wired for the real platform token before pointing a factory at this router.
    address public immutable BUYBACK;
    /// The protocol Safe. Receives the remainder of every routed amount, whole.
    address public immutable SAFE;
    /// May recover an asset this contract has no rule for, and nothing else: no other function
    /// here takes a guardian-only modifier, and the quote is refused even to this address.
    address public immutable GUARDIAN;

    error NothingToRoute();
    error ZeroAddress();
    error DuplicateDestination();
    error NativeTransferFailed();
    error NotGuardian();
    error ProtectedAsset();

    event Routed(uint256 total, uint256 toBuyback, uint256 toSafe);
    event NativeRouted(address indexed destination, uint256 amount);
    event SweptUnknown(address indexed asset, address indexed to, uint256 amount);

    constructor(IERC20 quote_, address buyback_, address safe_, address guardian_) {
        if (
            address(quote_) == address(0) || buyback_ == address(0) || safe_ == address(0)
                || guardian_ == address(0)
        ) revert ZeroAddress();
        // Both destinations are real recipients of a real split; the same address in both slots
        // is certainly a wiring mistake, not a policy anyone would choose on purpose.
        if (buyback_ == safe_) revert DuplicateDestination();
        QUOTE = quote_;
        BUYBACK = buyback_;
        SAFE = safe_;
        GUARDIAN = guardian_;
    }

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _;
    }

    /// @notice Split this contract's whole quote balance: `BURN_SHARE_BPS` to `BUYBACK`, the
    ///         rest to `SAFE`. Permissionless: the split and the destinations are fixed, so a
    ///         caller decides nothing except when it happens.
    function route() external nonReentrant returns (uint256 toBuyback, uint256 toSafe) {
        return _route();
    }

    /// @notice Pull what `escrow` owes this router in the quote and route it in the same
    ///         transaction. `escrow` is the hook for trade fees today and any future pull-escrow
    ///         ledger tomorrow; none of them will pay anyone but this contract, so taking the
    ///         address from the caller costs nothing.
    function claimAndRoute(address escrow)
        external
        nonReentrant
        returns (uint256 toBuyback, uint256 toSafe)
    {
        IPullEscrow(escrow).claimFor(address(QUOTE), address(this));
        return _route();
    }

    /// @notice Forward native currency sent here to the Safe. Nothing in the protocol pays a fee
    ///         in it; this exists so a contract that tries cannot be bricked by a router that
    ///         refuses, and so returned gas is not stranded.
    function routeNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToRoute();
        (bool ok,) = SAFE.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRouted(SAFE, amount);
    }

    /// @notice Recover an asset this contract has no rule for. The quote is refused by name: the
    ///         split above is the whole point of this contract, and no guardian may move the fee
    ///         itself anywhere else.
    function sweepUnknown(IERC20 asset, address to)
        external
        onlyGuardian
        nonReentrant
        returns (uint256 amount)
    {
        if (address(asset) == address(QUOTE)) revert ProtectedAsset();
        if (to == address(0)) revert ZeroAddress();
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToRoute();
        asset.safeTransfer(to, amount);
        emit SweptUnknown(address(asset), to, amount);
    }

    /// @notice What `route` would move right now, without moving it.
    function pending() external view returns (uint256 toBuyback, uint256 toSafe) {
        return _split(QUOTE.balanceOf(address(this)));
    }

    function _route() private returns (uint256 toBuyback, uint256 toSafe) {
        uint256 amount = QUOTE.balanceOf(address(this));
        if (amount == 0) revert NothingToRoute();
        (toBuyback, toSafe) = _split(amount);
        if (toBuyback != 0) QUOTE.safeTransfer(BUYBACK, toBuyback);
        if (toSafe != 0) QUOTE.safeTransfer(SAFE, toSafe);
        emit Routed(amount, toBuyback, toSafe);
    }

    /// `amount * BURN_SHARE_BPS / BPS_DENOMINATOR`, floored, to `BUYBACK`; the Safe takes
    /// whatever is left. The same floor-favors-the-remainder shape `HookFeeMath.share` and
    /// `LaunchHook._settle`'s treasury leg already use, so the odd unit on a routed amount that
    /// does not split evenly always lands with the party taking "the rest" rather than the party
    /// taking a named percentage.
    function _split(uint256 amount) private pure returns (uint256 toBuyback, uint256 toSafe) {
        toBuyback = (amount * BURN_SHARE_BPS) / BPS_DENOMINATOR;
        toSafe = amount - toBuyback;
    }

    receive() external payable { }
}
