// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { TestWETHBase } from "./TestWETHBase.sol";

/// Testnet settlement token with owner-controlled issuance and a finite-rate faucet. An
/// 18-decimal WETH stand-in with EIP-2612 `permit`; the operator overload supports sponsored
/// claims for embedded wallets. Only used off mainnet, where canonical WETH is referenced
/// instead.
contract TestnetWETH is TestWETHBase, Ownable2Step {
    uint256 public constant FAUCET_AMOUNT = 1e18;
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    address public faucetOperator;
    mapping(address => uint256) public nextFaucetAt;

    event FaucetOperatorSet(address indexed previousOperator, address indexed newOperator);
    event FaucetClaimed(address indexed recipient, uint256 amount, uint256 nextClaimAt);

    error InvalidFaucetOperator();
    error FaucetOperatorOnly();
    error FaucetReserveTooSmall(uint256 supplied, uint256 minimum);
    error FaucetCoolingDown(uint256 availableAt);
    error FaucetEmpty(uint256 available, uint256 required);
    error ZeroRecipient();

    modifier onlyFaucetOperator() {
        if (msg.sender != faucetOperator) revert FaucetOperatorOnly();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address initialOwner, address initialFaucetOperator, uint256 initialFaucetReserve)
        Ownable(initialOwner)
    {
        if (initialFaucetOperator == address(0)) revert InvalidFaucetOperator();
        if (initialFaucetReserve < FAUCET_AMOUNT) {
            revert FaucetReserveTooSmall(initialFaucetReserve, FAUCET_AMOUNT);
        }

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

    function setPaused(bool paused_) external onlyOwner {
        _setPaused(paused_);
    }

    function setFrozen(address account, bool frozen) external onlyOwner {
        _setFrozen(account, frozen);
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

    /// Sponsored token path for an API that separately provides the native gas bootstrap.
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
