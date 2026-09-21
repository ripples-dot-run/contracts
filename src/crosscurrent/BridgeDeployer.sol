// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BridgePath } from "./SealedOFTConfig.sol";

interface IBridgeSeal {
    function sealConfiguration(BridgePath[2] calldata paths) external;
}

/// A constant CREATE2 initcode makes the nonce-one child independent of its constructor args.
contract BridgeDeployer {
    address public immutable FACTORY = msg.sender;
    bool public deployed;

    error DeploymentFailed();

    function deploy(bytes memory initcode, BridgePath[2] calldata paths)
        external
        returns (address bridge)
    {
        if (msg.sender != FACTORY || deployed) revert DeploymentFailed();
        deployed = true;
        assembly ("memory-safe") {
            bridge := create(0, add(initcode, 32), mload(initcode))
        }
        if (bridge == address(0)) revert DeploymentFailed();
        IBridgeSeal(bridge).sealConfiguration(paths);
    }
}
