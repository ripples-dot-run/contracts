// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Charter } from "../AgentTreasury.sol";
import { DualFillAgentTreasury } from "../DualFillAgentTreasury.sol";

/// Holds `DualFillAgentTreasury`'s creation code so `DualFillAgentFactory` stays inside EIP-170.
/// An external library runs by `DELEGATECALL`, so the treasury is created by the factory and its
/// `AGENT_FACTORY` is the factory's address.
library DualFillAgentTreasuryDeployer {
    function deploy(
        address creator,
        address fillFactory,
        address router,
        address permit2,
        address quote,
        Charter calldata c,
        bytes32 dualFillKey
    ) external returns (address) {
        return address(
            new DualFillAgentTreasury(creator, fillFactory, router, permit2, quote, c, dualFillKey)
        );
    }
}
