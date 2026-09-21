// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {
    OFTCore,
    Origin,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { AgentToken, TokenSocials } from "../AgentToken.sol";
import { SealedOFTConfig } from "./SealedOFTConfig.sol";

struct CanonicalTokenParams {
    string name;
    string symbol;
    address holder;
    uint256 supply;
    string logo;
    string description;
    TokenSocials socials;
}

/// The only lockbox in the mesh. The underlying AgentToken has no mint or administrative role.
contract CrosscurrentAdapter is OFTAdapter, SealedOFTConfig {
    error InvalidSupply();

    constructor(
        CanonicalTokenParams memory params,
        address endpoint_,
        bytes32 configHash,
        bytes32 assetId
    )
        OFTAdapter(_createToken(params), endpoint_, address(this))
        SealedOFTConfig(configHash, assetId, params.supply)
        Ownable(msg.sender)
    { }

    function _checkOwner() internal view override(Ownable, SealedOFTConfig) {
        SealedOFTConfig._checkOwner();
    }

    function _send(SendParam calldata params, MessagingFee calldata fee, address refundAddress)
        internal
        override(OFTCore, SealedOFTConfig)
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        return SealedOFTConfig._send(params, fee, refundAddress);
    }

    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) internal override(OFTCore, SealedOFTConfig) {
        SealedOFTConfig._lzReceive(origin, guid, message, executor, extraData);
    }

    function _createToken(CanonicalTokenParams memory params) private returns (address) {
        if (params.supply % 1e12 != 0 || params.supply > uint256(type(uint64).max) * 1e9) {
            revert InvalidSupply();
        }
        return address(
            new AgentToken(
                params.name,
                params.symbol,
                params.holder,
                params.supply,
                params.logo,
                params.description,
                params.socials
            )
        );
    }
}
