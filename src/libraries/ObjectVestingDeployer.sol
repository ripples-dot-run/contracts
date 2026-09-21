// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ObjectVesting } from "../ObjectVesting.sol";

/// @notice Deploys a linked launch's vesting where the claim belongs to the piece rather than
///         to the wallet that minted it. A separate library from `VestingDeployer` so neither
///         carries the other's creation code, which is what keeps both under EIP-170 and leaves
///         the factory's own runtime unchanged whichever kind a launch picks.
///
///         Delegatecalled, so the vesting deploys from the factory and reads it as its factory
///         reference for binding collections.
library ObjectVestingDeployer {
    function deploy(address token, address curve, uint64 vestDuration, uint64 vestCliff)
        external
        returns (address vesting)
    {
        return address(new ObjectVesting(token, curve, vestDuration, vestCliff));
    }
}
