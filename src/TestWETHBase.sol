// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// Shared WETH-like behavior for local mocks and the Robinhood testnet settlement token: an
/// 18-decimal ERC-20 with EIP-2612 `permit`, plus issuer pause and per-account freeze so a
/// settlement token's control surface can be exercised. There is no EIP-3009 path: the platform
/// pulls the quote by approval, and every payment route proves settlement from a balance delta
/// rather than a call returning success.
abstract contract TestWETHBase is ERC20, ERC20Permit {
    bool public paused;
    mapping(address account => bool) public isFrozen;

    event PausedSet(bool paused);
    event FrozenSet(address indexed account, bool frozen);

    error ContractPaused();
    error AddressFrozen();

    constructor() ERC20("WETH", "WETH") ERC20Permit("WETH") { }

    function _setPaused(bool paused_) internal {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function _setFrozen(address account, bool frozen) internal {
        isFrozen[account] = frozen;
        emit FrozenSet(account, frozen);
    }

    /// Every mint, burn, and transfer runs through here, so the issuer controls gate the whole
    /// token from one place.
    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert ContractPaused();
        if (isFrozen[from] || isFrozen[to]) revert AddressFrozen();
        super._update(from, to, value);
    }
}
