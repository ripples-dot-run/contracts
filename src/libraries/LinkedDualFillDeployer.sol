// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LinkedDualFill } from "../LinkedDualFill.sol";
import { ILinkedDualFill } from "../interfaces/ILinkedDualFill.sol";

/// Holds `LinkedDualFill`'s creation code so `LinkedDualFillFactory` stays inside EIP-170. An
/// external library runs by `DELEGATECALL`, so the fill is created by the factory and its
/// `FACTORY` is the factory's address.
library LinkedDualFillDeployer {
    function deploy(ILinkedDualFill.Init memory init) external returns (address) {
        return address(new LinkedDualFill(init));
    }
}
