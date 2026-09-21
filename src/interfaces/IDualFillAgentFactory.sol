// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Charter } from "../AgentTreasury.sol";
import { LaunchParams } from "../TokenLaunchFactory.sol";

/// The fill a treasury creates, as one argument, in `DualFillFactory.createFill` order.
struct FillTerms {
    bytes32 dualFillKey;
    uint256 target;
    uint64 deadline;
    uint64 publicUntil;
    bool openAlone;
    uint256 feeBudget;
}

interface IDualFillAgentFactory {
    event AgentDualFillCreated(
        address indexed creator,
        address indexed treasury,
        address indexed operator,
        address fill,
        bytes32 dualFillKey,
        uint256 runway
    );

    error ZeroAddress();
    error NotAContract();
    /// The fill names no quote.
    error QuoteMismatch();
    error TreasuryExists();
    error MintUnavailable();
    error CharterAboveCap();
    error NoRunway();
    error NativeUnsupported();
    error WrongPayment();

    /// Of the side's opening quote, `p.vQuoteInit + t.target`; the daily cap also bounds `dailySell` against the opening
    /// token side, `vTokenInit * vQuoteInit / (vQuoteInit + target)` (D52).
    function MAX_PER_CALL_RESERVE_BPS() external view returns (uint256); // 62
    function MAX_DAILY_RESERVE_BPS() external view returns (uint256); // 300

    function DUAL_FILL_FACTORY() external view returns (address);
    function LAUNCH_FACTORY() external view returns (address);
    /// The fill factory's default quote. A treasury's runway is in its own fill's quote.
    function RUNWAY_ASSET() external view returns (address);
    /// The bond's asset on every fill.
    function FEE_TOKEN() external view returns (address);
    function NATIVE_WRAP() external view returns (bool);
    function ROUTER() external view returns (address);
    function PERMIT2() external view returns (address);

    function createAndFill(
        Charter calldata c,
        LaunchParams calldata p,
        FillTerms calldata t,
        uint256 runway
    ) external payable returns (address treasury, address fill);

    function treasuryOf(address creator, bytes32 dualFillKey) external view returns (address);
    function isFromFactory(address treasury) external view returns (bool);
    function treasuryCount() external view returns (uint256);
    function treasuries(uint256 offset, uint256 limit) external view returns (address[] memory);
    /// The asset `treasury` trades in, or zero for an address this factory did not deploy.
    function quoteOf(address treasury) external view returns (address);
}
