// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {
    OFTCore,
    Origin,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import { SealedOFTConfig } from "./SealedOFTConfig.sol";

/// Starts empty. Only verified messages from the two sealed peers can credit tokens.
contract CrosscurrentOFT is OFT, SealedOFTConfig {
    error GlobalSupplyExceeded();
    constructor(
        string memory name_,
        string memory symbol_,
        address endpoint_,
        bytes32 configHash,
        bytes32 assetId,
        uint256 globalSupply
    )
        OFT(name_, symbol_, endpoint_, address(this))
        SealedOFTConfig(configHash, assetId, globalSupply)
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

    function _credit(address recipient, uint256 amount, uint32 srcEid)
        internal
        override(OFT, OFTCore)
        returns (uint256)
    {
        if (totalSupply() + amount > GLOBAL_SUPPLY) revert GlobalSupplyExceeded();
        return super._credit(recipient, amount, srcEid);
    }
}
