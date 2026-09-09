// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Permit2's allowance ledger, as much of it as a router spends through.
///
/// Permit2 sits at `0x000000000022D473030F116dDEE9F6B43aC78BA3` on both Robinhood networks, the
/// same address it holds everywhere else, and every wallet that has traded a Ripples market
/// through Uniswap's Universal Router has already approved its quote asset to it. Spending
/// through the ledger rather than through a plain ERC-20 allowance is what lets a trader approve
/// an asset once, to one contract, and grant each router after that an amount and an expiry
/// instead of a second unbounded approval.
///
/// Only `transferFrom` is declared, because that is the only call a router makes. Granting and
/// reading an allowance is the wallet's business and is done against Permit2 directly.
interface IAllowanceTransfer {
    /// @notice Move `amount` of `token` from `from` to `to` against the allowance `from` granted
    ///         the caller. Reverts when the allowance is short or has expired.
    function transferFrom(address from, address to, uint160 amount, address token) external;
}
