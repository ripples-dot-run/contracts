// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { LPLocker } from "../LPLocker.sol";

/// @notice Deploys a launch's locker. Sibling of `TokenDeployer` and `PoolDeployer`; kept
///         separate so no library carries another's creation code and none exceeds the EIP-170
///         limit. Called by `delegatecall`, so the locker deploys from the factory and reads it
///         as its factory reference.
///
///         The locker is deployed **before** the launch is registered on the hook, because the
///         hook fixes the one address a Ripples pool will ever accept liquidity from and that
///         address has to exist to be named.
library LockerDeployer {
    struct LockerParams {
        address hook;
        address token;
        address quote;
        address treasury;
        address creator;
        uint96 creatorFeeBps;
        uint64 unlockAt;
    }

    function deployLocker(IPoolManager poolManager, LockerParams memory p)
        external
        returns (address locker)
    {
        return address(
            new LPLocker(
                poolManager,
                p.hook,
                address(this),
                p.token,
                p.quote,
                p.treasury,
                p.creator,
                p.creatorFeeBps,
                p.unlockAt
            )
        );
    }
}
