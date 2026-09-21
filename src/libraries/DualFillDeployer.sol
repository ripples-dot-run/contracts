// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { DualFill } from "../DualFill.sol";
import { IDualFill } from "../interfaces/IDualFill.sol";

/// @notice Deploys one side of a Dual Fill. The fill's creation code lives here rather than in
///         `DualFillFactory`, which would otherwise carry it and sit past the EIP-170 limit.
///         Called by `delegatecall`, so the fill deploys from the factory and records it as
///         `FACTORY`.
library DualFillDeployer {
    function deploy(IDualFill.Init memory init) external returns (address) {
        return address(new DualFill(init));
    }
}
