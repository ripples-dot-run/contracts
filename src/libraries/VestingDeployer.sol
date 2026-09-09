// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AllocationVesting } from "../AllocationVesting.sol";

/// @notice Deploys a linked launch's allocation vesting. A separate library from
///         `CollectionDeployer` so neither carries the other's creation code, keeping both
///         under the EIP-170 limit. Called by `delegatecall`, so the vesting deploys from the
///         factory and reads it as its factory reference for the one-shot `setCollection`.
///
///         Quote-free, and unchanged by per-launch quotes: the vesting holds contributions as
///         raw units of whatever the launch settles in and only ever divides one by another, so
///         no quote address and no decimals reach this signature. See the note on
///         `AllocationVesting.slice`.
library VestingDeployer {
    function deploy(address token, address curve, uint64 vestDuration, uint64 vestCliff)
        external
        returns (address vesting)
    {
        return address(new AllocationVesting(token, curve, vestDuration, vestCliff));
    }
}
