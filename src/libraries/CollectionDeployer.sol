// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Collection721, CollectionParams } from "../Collection721.sol";

/// @notice Deploys a drop's collection. Kept as an external library, like its
///         siblings, so the factory carries none of the collection's creation code and stays
///         under the EIP-170 limit. Called by `delegatecall`, so the collection deploys from
///         the factory and reads it as its factory reference; the factory does the one-shot
///         `linkToCurve` wiring itself, since it is that reference.
///
///         The signature is unchanged by the per-drop quote (`quote` stays a separate argument
///         and the factory passes the resolved value), but `CollectionParams` gained a field,
///         so the whole of `Collection721`'s creation code inside this library changed and the
///         library must be **redeployed** and both `deployments.json` records and `verify.sh`
///         updated with the new address (RH-DEPLOY). Nothing detects a stale link at runtime:
///         an old library would keep deploying collections that decode the old eleven-field
///         tuple, and the factory would emit the twelve-field event over them.
///
///         This library carries all of `Collection721`, so it, and not the factory, is where
///         EIP-170 bites: `test_collectionDeployerRuntimeCodeIsUnderEip170Limit` is the gate.
library CollectionDeployer {
    function deploy(
        CollectionParams memory np,
        address creator,
        uint96 protocolFeeBps,
        address quote,
        address treasury,
        address platformSigner
    ) external returns (address collection) {
        return address(
            new Collection721(np, creator, protocolFeeBps, quote, treasury, platformSigner)
        );
    }
}
