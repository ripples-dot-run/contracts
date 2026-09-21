// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// The one call this router makes into a pull-escrow ledger. The hook, the lockers and the
/// collections all expose it with the same shape and none of them will pay anyone but the
/// account named, so the escrow is an argument rather than an immutable: one router serves every
/// contract that owes it without having to trust any of them.
interface IPullEscrow {
    function claimFor(address token, address account) external returns (uint256 amount);
}

/// The one call the guardian can make through this contract. The hook lets only the address
/// currently receiving a launch's creator leg move it, so once that address is this contract,
/// this contract is the only thing that can ever hand it on.
interface ILaunchFeeRecipient {
    function setCreatorFeeRecipient(bytes32 poolId, address recipient) external;
}

/// @title BurnRouter
/// @notice The address a launch's fee share is paid to when that share is meant to be destroyed.
///
/// @dev A Ripples launch splits its trade fee between two recipients the hook fixes when the
///      launch is registered: `creatorFeeBps` to the creator's address and the remainder to the
///      launchpad's treasury. Neither number can be changed afterwards, and the recipient of the
///      creator leg is the only thing about it that can move. On the protocol's own launches
///      that leg is the burn share, so pointing it here is what turns a stated policy into the
///      thing the chain actually does.
///
///      What arrives is decided by the asset, and there are only three cases:
///
///      - The quote, WETH here, goes to the buyback burner. **It is spent, never destroyed.**
///        The burner buys the platform token with it and burns what the purchase delivers, in
///        one transaction. No path in this contract sends the quote to the burn address and
///        there is no configuration under which it could.
///      - The platform token goes to the burn address. It is already what a buyback would have
///        gone to the market to fetch, so spending anything to acquire it would be buying what
///        is in hand.
///      - Anything else goes to operations whole. A stock-denominated fee, or the token leg of
///        somebody else's launch, is revenue this protocol earned and not supply it is entitled
///        to destroy. Burning a stranger's token because it happened to arrive here would be a
///        decision made on their project's behalf.
///
///      The three rules above are fixed at construction and nothing can change them. Not the
///      guardian, not the protocol, not a vote. The quote cannot be made burnable and the
///      platform token cannot be made spendable, because the addresses are immutable and no
///      function takes a destination as an argument.
///
///      The guardian exists for the two failures that rule leaves open, and it is deliberately
///      not able to do anything else:
///
///      - `redirect` hands the fee leg to a different address. If this contract turns out to be
///        wrong, that is how the protocol stops feeding it. It moves where future fees go; it
///        cannot touch a wei already here.
///      - `sweepUnknown` recovers an asset that has no rule, and refuses the quote and the
///        platform token by name. Without it, a stock token whose issuer freezes the operations
///        address would strand itself here forever, because `route` is the only way out and it
///        would revert on every call.
///
///      What that costs, stated plainly: a guardian who loses control of their key can point
///      future fees somewhere else. They cannot make this contract pay them, cannot stop what is
///      already here from reaching the burn, and cannot turn a burn into a spend.
contract BurnRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Where supply goes to stop existing. The same sink the hook uses for the opening tax and
    /// the burner uses for what it buys, so one balance answers for every burn the protocol has
    /// ever made.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// The asset fees arrive in on the sell side. Spent, never burned.
    IERC20 public immutable QUOTE;
    /// The platform token. Burned, never spent.
    IERC20 public immutable TOKEN;
    /// `BuybackBurner`. Holds the quote until its keeper spends it on the market.
    address public immutable BUYBACK;
    /// Where an asset with no rule goes. Never receives the quote or the platform token.
    address public immutable OPS;
    /// May hand the fee leg to a different address, and may recover an asset this contract has
    /// no rule for. May not do anything else, and in particular may not move the quote or the
    /// platform token, which have rules.
    address public immutable GUARDIAN;

    error NothingToRoute();
    error ZeroAddress();
    error DuplicateAsset();
    error NativeTransferFailed();
    error NotGuardian();
    error ProtectedAsset();

    event Routed(address indexed asset, address indexed destination, uint256 amount);
    event NativeRouted(address indexed destination, uint256 amount);
    event Redirected(address indexed hook, bytes32 indexed poolId, address indexed recipient);
    event SweptUnknown(address indexed asset, address indexed to, uint256 amount);

    constructor(IERC20 quote_, IERC20 token_, address buyback_, address ops_, address guardian_) {
        if (
            address(quote_) == address(0) || address(token_) == address(0) || buyback_ == address(0)
                || ops_ == address(0) || guardian_ == address(0)
        ) {
            revert ZeroAddress();
        }
        // A router whose quote and token are the same address would burn the asset it is meant
        // to spend, or spend the asset it is meant to burn, depending on which branch won.
        if (address(quote_) == address(token_)) revert DuplicateAsset();
        QUOTE = quote_;
        TOKEN = token_;
        BUYBACK = buyback_;
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
    function route(IERC20 asset) external nonReentrant returns (uint256 amount, address destination) {
        return _route(asset);
    }

    /// @notice Pull what `escrow` owes this contract and route it in the same transaction.
    ///         `escrow` is the hook for trade fees, a locker for collected pool fees, a
    ///         collection for its share of mints. None of them will pay anyone but this
    ///         contract, so taking the address from the caller costs nothing.
    function claimAndRoute(address escrow, IERC20 asset)
        external
        nonReentrant
        returns (uint256 amount, address destination)
    {
        IPullEscrow(escrow).claimFor(address(asset), address(this));
        return _route(asset);
    }

    /// @notice Forward native currency sent here to operations. Nothing in the protocol pays a
    ///         fee in it; this exists so that a contract which tries cannot be bricked by a
    ///         router that refuses, and so returned gas is not stranded.
    function routeNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToRoute();
        (bool ok,) = OPS.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        emit NativeRouted(OPS, amount);
    }

    /// @notice Hand a launch's fee leg to `recipient`. The way out if this contract is wrong:
    ///         it changes where the next fee is credited and nothing about the fees already
    ///         here, which keep following the same three rules to the same three addresses.
    ///         One-way in the same sense the hook is: whoever receives the leg next is the only
    ///         address that can move it again.
    function redirect(address hook, bytes32 poolId, address recipient) external onlyGuardian {
        if (recipient == address(0)) revert ZeroAddress();
        ILaunchFeeRecipient(hook).setCreatorFeeRecipient(poolId, recipient);
        emit Redirected(hook, poolId, recipient);
    }

    /// @notice Recover an asset this contract has no rule for. The quote and the platform token
    ///         are refused by name: they are the whole point of the contract and the guardian
    ///         has no say over either.
    function sweepUnknown(IERC20 asset, address to) external onlyGuardian nonReentrant returns (uint256 amount) {
        if (asset == QUOTE || asset == TOKEN) revert ProtectedAsset();
        if (to == address(0)) revert ZeroAddress();
        amount = asset.balanceOf(address(this));
        if (amount == 0) revert NothingToRoute();
        asset.safeTransfer(to, amount);
        emit SweptUnknown(address(asset), to, amount);
    }

    /// @notice Where `asset` goes. The whole policy, readable without running it.
    function destinationOf(IERC20 asset) public view returns (address) {
        if (asset == QUOTE) return BUYBACK;
        if (asset == TOKEN) return BURN;
        return OPS;
    }

    /// @notice What `route` would move right now, without moving it.
    function pending(IERC20 asset) external view returns (uint256 amount, address destination) {
        return (asset.balanceOf(address(this)), destinationOf(asset));
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
