// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    OFTCore,
    Origin,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import {
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";

struct BridgePath {
    uint32 eid;
    bytes32 peer;
    address sendLibrary;
    address receiveLibrary;
    address executor;
    address[2] dvns;
    uint64 sendConfirmations;
    uint64 receiveConfirmations;
    uint32 maxMessageSize;
    uint128 receiveGas;
    uint128 composeReceiveGas;
    uint128 receiveValue;
}

/// Configuration is committed before deployment and applied once, before any bridge transfer.
abstract contract SealedOFTConfig is OFTCore {
    using OptionsBuilder for bytes;

    bytes32 public immutable CONFIG_HASH;
    bytes32 public immutable ASSET_ID;
    uint256 public immutable GLOBAL_SUPPLY;
    bool public configurationSealed;

    error InvalidConfiguration();
    error ConfigurationLocked();
    error ConfigurationNotSealed();

    event ConfigurationSealed(bytes32 indexed configHash);

    constructor(bytes32 configHash, bytes32 assetId, uint256 globalSupply) {
        if (
            configHash == bytes32(0) || assetId == bytes32(0) || globalSupply == 0
                || globalSupply % 1e12 != 0 || globalSupply > uint256(type(uint64).max) * 1e9
        ) revert InvalidConfiguration();
        CONFIG_HASH = configHash;
        ASSET_ID = assetId;
        GLOBAL_SUPPLY = globalSupply;
    }

    function sealConfiguration(BridgePath[2] calldata paths) external onlyOwner {
        if (configurationSealed) revert ConfigurationLocked();
        if (keccak256(abi.encode(block.chainid, address(endpoint), paths)) != CONFIG_HASH) {
            revert InvalidConfiguration();
        }
        (uint32 solEid, uint32 remoteEvm, address[2] memory requiredDvns) = _environment();
        if (paths[0].eid != solEid || paths[1].eid != remoteEvm) {
            revert InvalidConfiguration();
        }
        for (uint256 i; i < paths.length; ++i) {
            _configure(paths[i], requiredDvns);
        }

        // Renouncing the OApp owner alone leaves an endpoint delegate able to change its DVNs.
        endpoint.setDelegate(address(0));
        configurationSealed = true;
        _transferOwnership(address(0));
        emit ConfigurationSealed(CONFIG_HASH);
    }

    function _environment()
        private
        view
        returns (uint32 solEid, uint32 remoteEvm, address[2] memory dvns)
    {
        uint32 localEid = endpoint.eid();
        address expectedEndpoint = block.chainid == 46630
            ? 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32
            : block.chainid == 5042002
                ? 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff
                : 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
        if (address(endpoint) != expectedEndpoint) revert InvalidConfiguration();
        if (block.chainid == 4663 && localEid == 30416) {
            return (
                30168,
                30417,
                [
                    0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8,
                    0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12
                ]
            );
        }
        if (block.chainid == 5042 && localEid == 30417) {
            return (
                30168,
                30416,
                [
                    0x9E0E95Ede70F680f74480b510FF9f45C70e3da80,
                    0xa2447e5B58D357c49Bf74B50B14421e6A100e525
                ]
            );
        }
        if (block.chainid == 46630 && localEid == 40451) {
            return (40168, 40434, [0xa78A78a13074eD93aD447a26Ec57121f29E8feC2, address(0)]);
        }
        if (block.chainid == 5042002 && localEid == 40434) {
            return (40168, 40451, [0x88B27057A9e00c5F05DDa29241027afF63f9e6e0, address(0)]);
        }
        revert InvalidConfiguration();
    }

    function _configure(BridgePath calldata path, address[2] memory requiredDvns) private {
        uint8 dvnCount = requiredDvns[1] == address(0) ? 1 : 2;
        if (
            path.peer == bytes32(0) || path.sendLibrary.code.length == 0
                || path.receiveLibrary.code.length == 0 || path.executor.code.length == 0
                || path.dvns[0].code.length == 0 || path.dvns[0] != requiredDvns[0]
                || path.dvns[1] != requiredDvns[1] || path.sendConfirmations == 0
                || path.receiveConfirmations == 0 || path.maxMessageSize < 40
                || path.receiveGas == 0 || path.composeReceiveGas < path.receiveGas
        ) revert InvalidConfiguration();
        if (dvnCount == 2) {
            if (path.dvns[1].code.length == 0 || path.dvns[0] >= path.dvns[1]) {
                revert InvalidConfiguration();
            }
        }

        _setPeer(path.eid, path.peer);
        endpoint.setSendLibrary(address(this), path.eid, path.sendLibrary);
        endpoint.setReceiveLibrary(address(this), path.eid, path.receiveLibrary, 0);

        address[] memory dvns = new address[](dvnCount);
        dvns[0] = path.dvns[0];
        if (dvnCount == 2) dvns[1] = path.dvns[1];
        UlnConfig memory uln = UlnConfig({
            confirmations: path.sendConfirmations,
            requiredDVNCount: dvnCount,
            optionalDVNCount: type(uint8).max,
            optionalDVNThreshold: 0,
            requiredDVNs: dvns,
            optionalDVNs: new address[](0)
        });
        SetConfigParam[] memory configs = new SetConfigParam[](2);
        configs[0] = SetConfigParam(
            path.eid, 1, abi.encode(ExecutorConfig(path.maxMessageSize, path.executor))
        );
        configs[1] = SetConfigParam(path.eid, 2, abi.encode(uln));
        endpoint.setConfig(address(this), path.sendLibrary, configs);
        uln.confirmations = path.receiveConfirmations;
        configs = new SetConfigParam[](1);
        configs[0] = SetConfigParam(path.eid, 2, abi.encode(uln));
        endpoint.setConfig(address(this), path.receiveLibrary, configs);

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam(
            path.eid,
            SEND,
            OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(path.receiveGas, path.receiveValue)
        );
        options[1] = EnforcedOptionParam(
            path.eid,
            SEND_AND_CALL,
            OptionsBuilder.newOptions()
                .addExecutorLzReceiveOption(path.composeReceiveGas, path.receiveValue)
        );
        _setEnforcedOptions(options);
    }

    function _checkOwner() internal view virtual override {
        super._checkOwner();
        if (msg.sig != this.sealConfiguration.selector) revert ConfigurationLocked();
    }

    function _send(SendParam calldata params, MessagingFee calldata fee, address refundAddress)
        internal
        virtual
        override
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        if (!configurationSealed) revert ConfigurationNotSealed();
        return super._send(params, fee, refundAddress);
    }

    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) internal virtual override {
        if (!configurationSealed) revert ConfigurationNotSealed();
        super._lzReceive(origin, guid, message, executor, extraData);
    }
}
