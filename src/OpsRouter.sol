// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The one call this router makes into a pull-escrow ledger. The hook, the lockers and the
/// collections all expose it with the same shape and none of them will pay anyone but the
/// account named, so the escrow is an argument rather than an immutable.
interface IPullEscrow {
    function claimFor(address token, address account) external returns (uint256 amount);
}

/// @title OpsRouter
/// @notice The launchpad treasury: what pays for hosting, infrastructure and marketing.
///
/// @dev A trade fee is charged in whatever the swap hands the trader, so the protocol's share of
///      a buy arrives as the launch token and its share of a sell arrives as the quote. Paid to
///      a wallet, that meant the treasury accumulated the platform token and could only spend it
///      by selling it, which is a protocol funding its electricity bill out of its own supply.
///
///      So the treasury is this contract instead, and the currency decides:
///
///      - The quote, WETH here, goes to operations. This is the money that pays for things.
///      - The platform token goes to the burn address. The protocol does not hold its own token
///        and does not sell it; the share that arrives in it is destroyed instead.
///      - Anything else goes to operations whole. A stock-denominated fee is revenue this
///        protocol earned and not supply it is entitled to destroy, and it is not this
///        contract's business to decide what a stranger's token is worth.
///
///      Unlike the burn side, nothing here is one-way. The launchpad reads `treasury()` live on
///      every fee, so the factory owner can point it somewhere else with `setTreasury` whenever
///      it wants and this contract stops receiving. That is the escape hatch, and it lives where
///      it already lived rather than in a privileged call added here.
///
///      The guardian's one power is `sweepUnknown`, which refuses the quote and the platform
///      token by name. Without it, a stock token whose issuer freezes the operations address
///      would strand itself here for good, because `route` is the only way out and it would
///      revert on every call.
contract OpsRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Where supply goes to stop existing. The same sink the hook uses for the opening tax and
    /// the burner uses for what it buys.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// The settlement asset. This is what pays the bills.
    IERC20 public immutable QUOTE;
    /// The platform token. Burned, never spent and never sold.
    IERC20 public immutable TOKEN;
    /// What operations are paid from, and where an asset with no rule goes.
    address public immutable OPS;
    /// May recover an asset this contract has no rule for, and nothing else.
    address public immutable GUARDIAN;

    error NothingToRoute();
    error ZeroAddress();
    error DuplicateAsset();
    error NativeTransferFailed();
    error NotGuardian();
    error ProtectedAsset();

    event Routed(address indexed asset, address indexed destination, uint256 amount);
    event NativeRouted(address indexed destination, uint256 amount);
    event SweptUnknown(address indexed asset, address indexed to, uint256 amount);

    constructor(IERC20 quote_, IERC20 token_, address ops_, address guardian_) {
        if (
            address(quote_) == address(0) || address(token_) == address(0) || ops_ == address(0)
                || guardian_ == address(0)
        ) {
            revert ZeroAddress();
        }
        // A router whose quote and token are the same address would burn the money it is meant to
        // spend, or spend the supply it is meant to burn, depending on which branch won.
        if (address(quote_) == address(token_)) revert DuplicateAsset();
        QUOTE = quote_;
        TOKEN = token_;
        OPS = ops_;
        GUARDIAN = guardian_;
    }

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _;
    }

    /// @notice Send this contract's whole balance of `asset` where its rule says it goes.
    ///         Permissionless: the destinations are fixed, so a caller chooses nothing except
    ///         when it happens.
    function route(IERC20 asset)
        external
        nonReentrant
        returns (uint256 amount, address destination)
    {
        return _route(asset);
    }

    /// @notice Pull what `escrow` owes this contract and route it in the same transaction.
    function claimAndRoute(address escrow, IERC20 asset)
        external
        nonReentrant
        returns (uint256 amount, address destination)
    {
        IPullEscrow(escrow).claimFor(address(asset), address(this));
        return _route(asset);
    }

    /// @notice Forward native currency sent here to operations. Nothing in the protocol pays a
    ///         fee in it; this exists so a contract that tries cannot be bricked by a router that
    ///         refuses, and so returned gas is not stranded.
    function routeNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToRoute();
        (bool ok,) = OPS.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRouted(OPS, amount);
    }

    /// @notice Recover an asset this contract has no rule for. The quote and the platform token
    ///         are refused by name.
    function sweepUnknown(IERC20 asset, address to)
        external
        onlyGuardian
        nonReentrant
        returns (uint256 amount)
    {
        if (asset == QUOTE || asset == TOKEN) revert ProtectedAsset();
        if (to == address(0)) revert ZeroAddress();
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToRoute();
        asset.safeTransfer(to, amount);
        emit SweptUnknown(address(asset), to, amount);
    }

    /// @notice Where `asset` goes. The whole policy, readable without running it.
    function destinationOf(IERC20 asset) public view returns (address) {
        if (asset == QUOTE) return OPS;
        if (asset == TOKEN) return BURN;
        return OPS;
    }

    /// @notice What `route` would move right now, without moving it.
    function pending(IERC20 asset) external view returns (uint256 amount, address destination) {
        return (asset.balanceOf(address(this)), destinationOf(asset));
    }

    /// @notice The treasury address the launchpad reads. Present so a reader checking the
    ///         factory's `treasury()` against this contract finds the same answer twice.
    function treasury() external view returns (address) {
        return address(this);
    }

    function _route(IERC20 asset) private returns (uint256 amount, address destination) {
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToRoute();
        destination = destinationOf(asset);
        asset.safeTransfer(destination, amount);
        emit Routed(address(asset), destination, amount);
    }

    receive() external payable { }
}
