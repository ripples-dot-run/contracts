// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AgentToken, TokenSocials } from "../AgentToken.sol";

/// @notice Deploys a launch's ERC-20. Split out of the deployer library that once carried both
///         the token's and the bonding curve's creation code, because that library, not
///         `LaunchpadFactory`, is where EIP-170 bit: it stood at 23,049 B of 24,576, with 1,527 B
///         of headroom for a change that needed more than that. Moving `new AgentToken` here
///         buys back the whole of the token's creation code.
///
///         Called by `delegatecall` from the factory, so `address(this)` is the factory: it holds
///         the minted supply and hands it to the launch's locker, which puts it in the pool.
///
///         `contracts/test/TokenLaunchFactory.t.sol` asserts every deployer library's runtime
///         code stays under 24,576 B, so this split cannot quietly be undone by a later change.
library TokenDeployer {
    /// @param holder Receives the whole minted supply (the factory, in every real deployment).
    /// @param logo URI of the token's image, which every launch must carry: it is what a
    ///        terminal shows beside the ticker, and it cannot be added later.
    /// @param socials The five links, X first, each of which may be left empty.
    function deployToken(
        string memory name,
        string memory symbol,
        address holder,
        uint256 totalSupply,
        string memory logo,
        string memory description,
        TokenSocials memory socials
    ) external returns (address token) {
        return address(
            new AgentToken(name, symbol, holder, totalSupply, logo, description, socials)
        );
    }
}
