// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FundedFill, FundedFillInit } from "../FundedFill.sol";

library FundedFillDeployer {
    function deploy(FundedFillInit memory init) external returns (address) {
        return address(new FundedFill(init));
    }
}
