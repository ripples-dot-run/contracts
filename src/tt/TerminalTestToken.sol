// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The throwaway ERC-20 for the terminal test. The whole supply is minted to the
///         deployer at construction; there is no owner, no mint path and no privileged role
///         afterwards.
///
///         The name says what it is. Anyone who finds this token on a terminal must be able to
///         tell in one line that it is an indexing probe and not a Ripples launch, so the name
///         carries "TERMINAL TEST" and the ticker is TTEST. Do not rename it to anything a buyer
///         could mistake for a real launch.
contract TerminalTestToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("RIPPLES TERMINAL TEST", "TTEST") {
        _mint(recipient, supply);
    }
}
