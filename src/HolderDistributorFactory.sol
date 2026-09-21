// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PoolId } from "v4-core/src/types/PoolId.sol";
import { ILaunchHook, LaunchConfig } from "./hook/interfaces/ILaunchHook.sol";
import { HolderDistributor } from "./HolderDistributor.sol";

/// The one call the piece side needs from a launch's locker: the collection it was created with.
/// A launch that grew later waves answers with the first one, and the first one is what the fee
/// stream pays. Sharing it across every wave is a decision with its own tradeoff, and it is not
/// made here: it would mean a later drop diluting a stream the genesis minters were already in.
interface ILinkedLocker {
    function linkedCollection() external view returns (address);
}

/// Permissionless deployment with one publisher and one authentic hook fixed for this factory.
/// Creating a distributor does not route fees: only the hook's current recipient can do that.
///
/// Two per launch at most, and a launch's creator picks which one their income goes to by routing
/// it there: one that pays whoever holds the coin, and one that pays whoever holds the pieces of
/// the collection that funded the market. The second reads the collection off the launch's own
/// locker, so nobody can deploy a distributor that pays the holders of some other collection.
contract HolderDistributorFactory {
    ILaunchHook public immutable HOOK;
    address public immutable PUBLISHER;
    uint64 public immutable FINALITY_DELAY;
    mapping(address token => address distributor) public distributorOf;
    /// The same launch's distributor for its collection's holders, where it has a collection.
    mapping(address token => address distributor) public pieceDistributorOf;

    event DistributorCreated(
        address indexed token, address indexed quote, address indexed distributor, PoolId poolId
    );
    /// The same event for the piece side, with the collection it pays named.
    event PieceDistributorCreated(
        address indexed token,
        address indexed collection,
        address indexed distributor,
        PoolId poolId
    );

    error InvalidConfiguration();
    error UnknownLaunch();
    /// A launch with no collection has no pieces to pay.
    error NotLinked();

    constructor(ILaunchHook hook, address publisher, uint64 finalityDelay) {
        if (address(hook).code.length == 0 || publisher == address(0) || finalityDelay == 0) {
            revert InvalidConfiguration();
        }
        HOOK = hook;
        PUBLISHER = publisher;
        FINALITY_DELAY = finalityDelay;
    }

    function createFor(address token) external returns (address distributor) {
        distributor = distributorOf[token];
        if (distributor != address(0)) return distributor;
        PoolId poolId = HOOK.poolIdOfToken(token);
        LaunchConfig memory config = HOOK.configOf(poolId);
        if (
            config.token != token || token == address(0) || config.creatorFeeRecipient == address(0)
        ) {
            revert UnknownLaunch();
        }
        distributor = address(
            new HolderDistributor(
                HOOK, token, address(0), config.quote, poolId, PUBLISHER, FINALITY_DELAY
            )
        );
        distributorOf[token] = distributor;
        emit DistributorCreated(token, config.quote, distributor, poolId);
    }

    /// @notice The same, for the holders of the collection that funded this market.
    ///
    ///         The collection is read off the launch's locker rather than taken as an argument.
    ///         A caller who could name it would be able to deploy a distributor that pays a
    ///         collection with no connection to the market, and the only thing standing between
    ///         that and a creator's whole fee stream would be the creator reading an address.
    function createForPieces(address token) external returns (address distributor) {
        distributor = pieceDistributorOf[token];
        if (distributor != address(0)) return distributor;
        PoolId poolId = HOOK.poolIdOfToken(token);
        LaunchConfig memory config = HOOK.configOf(poolId);
        if (
            config.token != token || token == address(0) || config.creatorFeeRecipient == address(0)
                || config.locker == address(0)
        ) revert UnknownLaunch();
        // A locker from before linked launches has no collection to name and no getter to say so.
        (bool answered, bytes memory answer) =
            config.locker.staticcall(abi.encodeCall(ILinkedLocker.linkedCollection, ()));
        if (!answered || answer.length < 32) revert NotLinked();
        address collection = abi.decode(answer, (address));
        if (collection == address(0) || collection.code.length == 0) revert NotLinked();
        distributor = address(
            new HolderDistributor(
                HOOK, token, collection, config.quote, poolId, PUBLISHER, FINALITY_DELAY
            )
        );
        pieceDistributorOf[token] = distributor;
        emit PieceDistributorCreated(token, collection, distributor, poolId);
    }
}
