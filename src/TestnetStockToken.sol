// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// Shared behavior for a Robinhood-shaped stock token: an ERC-20 with EIP-2612 `permit`,
/// constructor decimals, the issuer's `paused()` / `isBlocked(address)` controls gating every
/// mint, burn and transfer from one place, and the ERC-8056 scaled-UI surface. Same shape as
/// `TestWETHBase`, under the names the real beacon implementation uses.
///
/// The scaled-UI rule is the reason this exists: a corporate action moves the *display*
/// multiplier and never a raw balance. `balanceOf` and `totalSupply` are raw units and are
/// byte-identical across a split; `balanceOfUI` and `totalSupplyUI` are the raw amount scaled by
/// `uiMultiplier()`. Every contract in this repo settles in raw units, so a split has to be
/// invisible to a curve, a locker and a collection, and visible only in an interface.
///
/// `uiMultiplier` is an 18-decimal fixed-point fraction: `MULTIPLIER_ONE` (1e18) is "display
/// the raw amount unchanged", 2e18 doubles the displayed amount (a 2-for-1 split), 5e17 halves
/// it (a 1-for-2 reverse split). A change is announced ahead of time through
/// `newUIMultiplier(multiplier, effectiveAt)`: `newUIMultiplier()` / `pendingMultiplier()` and
/// `effectiveAt()` read it before it lands, and `uiMultiplier()` starts returning it the moment
/// `block.timestamp` reaches `effectiveAt`, with no transaction in between.
abstract contract StockTokenBase is ERC20, ERC20Permit {
    /// The fixed-point scale of `uiMultiplier`: 1e18 means "display the raw amount unchanged".
    uint256 public constant MULTIPLIER_ONE = 1e18;

    uint8 private immutable DECIMALS;

    /// Issuer controls. Both belong to the token, not to the platform, and both are holds rather
    /// than losses: a paused token or a blocked counterparty reverts the whole transaction and
    /// leaves the raw ledger exactly where it was.
    bool public paused;
    mapping(address account => bool) public isBlocked;

    /// The multiplier in force until `pendingMultiplier` takes effect.
    uint256 public currentMultiplier;
    /// The announced multiplier; it becomes `uiMultiplier()` at `effectiveAt`.
    uint256 public pendingMultiplier;
    /// Timestamp at which `pendingMultiplier` becomes the live multiplier.
    uint64 public effectiveAt;

    event Paused(address account);
    event Unpaused(address account);
    event BlockedSet(address indexed account, bool blocked);
    event NewUIMultiplier(uint256 multiplier, uint64 effectiveAt);

    error EnforcedPause();
    error ExpectedPause();
    error Blocked(address account);
    error InvalidMultiplier();

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        DECIMALS = decimals_;
        currentMultiplier = MULTIPLIER_ONE;
        pendingMultiplier = MULTIPLIER_ONE;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /// The live display multiplier. An announced change lands on the clock alone.
    function uiMultiplier() public view returns (uint256) {
        return block.timestamp >= effectiveAt ? pendingMultiplier : currentMultiplier;
    }

    /// ERC-8056 reads the announced multiplier under this name; `pendingMultiplier()` is the
    /// same value under its storage name.
    function newUIMultiplier() external view returns (uint256) {
        return pendingMultiplier;
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return (balanceOf(account) * uiMultiplier()) / MULTIPLIER_ONE;
    }

    function totalSupplyUI() external view returns (uint256) {
        return (totalSupply() * uiMultiplier()) / MULTIPLIER_ONE;
    }

    function _setPaused(bool paused_) internal {
        if (paused_) {
            if (paused) revert EnforcedPause();
            paused = true;
            emit Paused(msg.sender);
        } else {
            if (!paused) revert ExpectedPause();
            paused = false;
            emit Unpaused(msg.sender);
        }
    }

    function _setBlocked(address account, bool blocked) internal {
        isBlocked[account] = blocked;
        emit BlockedSet(account, blocked);
    }

    /// Announce a multiplier change. Whatever `uiMultiplier()` reads right now is frozen into
    /// `currentMultiplier` first, so announcing a second change never rewinds a landed one.
    function _newUIMultiplier(uint256 multiplier, uint64 effectiveAt_) internal {
        if (multiplier == 0) revert InvalidMultiplier();
        currentMultiplier = uiMultiplier();
        pendingMultiplier = multiplier;
        effectiveAt = effectiveAt_;
        emit NewUIMultiplier(multiplier, effectiveAt_);
    }

    /// Every mint, burn and transfer runs through here, so the issuer's two controls gate the
    /// whole token from one place, and gate the recipient as well as the sender.
    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        if (isBlocked[from]) revert Blocked(from);
        if (isBlocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// Testnet stand-in for a Robinhood stock token: 46630 carries none, and the decimals,
/// corporate-action and issuer-hold programme needs one to rehearse against. Owner-controlled
/// issuance, the issuer's `pause` / `unpause` / `setBlocked`, the ERC-8056 announcement path,
/// and a finite-rate faucet with the same operator rules as `TestnetWETH` so the API can sponsor
/// a claim for an embedded wallet. Deployed off mainnet only; on 4663 the real stock tokens are
/// referenced instead, and nothing here is ever an issuer of anything.
contract TestnetStockToken is StockTokenBase, Ownable2Step {
    /// One whole unit at this token's own decimals.
    uint256 public immutable FAUCET_AMOUNT;
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    address public faucetOperator;
    mapping(address account => uint256) public nextFaucetAt;

    event FaucetOperatorSet(address indexed previousOperator, address indexed newOperator);
    event FaucetClaimed(address indexed recipient, uint256 amount, uint256 nextClaimAt);

    error InvalidFaucetOperator();
    error FaucetOperatorOnly();
    error FaucetReserveTooSmall(uint256 supplied, uint256 minimum);
    error FaucetCoolingDown(uint256 availableAt);
    error FaucetEmpty(uint256 available, uint256 required);
    error ZeroRecipient();
    error InvalidDecimals();

    modifier onlyFaucetOperator() {
        if (msg.sender != faucetOperator) revert FaucetOperatorOnly();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address initialOwner,
        address initialFaucetOperator,
        uint256 initialFaucetReserve
    ) StockTokenBase(name_, symbol_, decimals_) Ownable(initialOwner) {
        if (decimals_ == 0 || decimals_ > 18) revert InvalidDecimals();
        if (initialFaucetOperator == address(0)) revert InvalidFaucetOperator();

        uint256 unit = 10 ** decimals_;
        if (initialFaucetReserve < unit) revert FaucetReserveTooSmall(initialFaucetReserve, unit);

        FAUCET_AMOUNT = unit;
        faucetOperator = initialFaucetOperator;
        _mint(address(this), initialFaucetReserve);
        emit FaucetOperatorSet(address(0), initialFaucetOperator);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function pause() external onlyOwner {
        _setPaused(true);
    }

    function unpause() external onlyOwner {
        _setPaused(false);
    }

    function setBlocked(address account, bool blocked) external onlyOwner {
        _setBlocked(account, blocked);
    }

    /// Announce a corporate action. Raw balances do not move; only the display multiplier does.
    function newUIMultiplier(uint256 multiplier, uint64 effectiveAt_) external onlyOwner {
        _newUIMultiplier(multiplier, effectiveAt_);
    }

    function setFaucetOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidFaucetOperator();
        address previous = faucetOperator;
        faucetOperator = newOperator;
        emit FaucetOperatorSet(previous, newOperator);
    }

    /// Self-service path for external wallets already holding Robinhood testnet ETH.
    function faucet() external whenNotPaused returns (uint256 amount) {
        return _faucet(msg.sender);
    }

    /// Sponsored path for an API that separately provides the native gas bootstrap.
    function faucet(address recipient)
        external
        onlyFaucetOperator
        whenNotPaused
        returns (uint256 amount)
    {
        return _faucet(recipient);
    }

    function faucetReserve() external view returns (uint256) {
        return balanceOf(address(this));
    }

    function _faucet(address recipient) private returns (uint256 amount) {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 availableAt = nextFaucetAt[recipient];
        if (block.timestamp < availableAt) revert FaucetCoolingDown(availableAt);

        amount = FAUCET_AMOUNT;
        uint256 reserve = balanceOf(address(this));
        if (reserve < amount) revert FaucetEmpty(reserve, amount);

        uint256 next = block.timestamp + FAUCET_COOLDOWN;
        nextFaucetAt[recipient] = next;
        _transfer(address(this), recipient, amount);
        emit FaucetClaimed(recipient, amount, next);
    }
}
