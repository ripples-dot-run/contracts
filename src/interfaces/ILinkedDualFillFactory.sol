// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CollectionParams } from "../Collection721.sol";
import { LaunchParams, LinkedParams } from "../TokenLaunchFactory.sol";

interface ILinkedDualFillFactory {
    event FillCreated(
        address indexed fill,
        address indexed creator,
        bytes32 indexed dualFillKey,
        uint256 target,
        uint64 deadline,
        uint64 publicUntil,
        bool openAlone,
        uint256 feeBudget,
        bytes32 paramsHash,
        LaunchParams tp,
        CollectionParams np,
        LinkedParams lp
    );

    error ZeroAddress();
    error NotAContract();
    error NativeUnsupported();
    error WrongPayment();
    error FillExists();
    error InvalidDualFillKey();
    error InvalidDeadline();
    error OpenAloneRefused();
    error InvalidCoupling();
    error SupplyMismatch();
    error QuoteMismatch();
    error EconomicsMismatch();
    /// The quote's own `decimals()` is not what its registry row records.
    error QuoteDecimalsMismatch();
    error InvalidParams();
    error InvalidCollection();
    error InvalidTarget();
    error FeeBudgetTooLow();

    function MAX_FILL_BPS() external view returns (uint256); // 4_000
    function MIN_DURATION() external view returns (uint64); // 10 minutes
    function MAX_DURATION() external view returns (uint64); // 24 hours
    function MIN_PUBLIC_WINDOW() external view returns (uint64); // 10 minutes
    function OPEN_GRACE() external view returns (uint64); // 15 minutes
    function TOTAL_SUPPLY() external view returns (uint256); // 1_065_000_000e18
    function LP_SUPPLY() external view returns (uint256); // 265_000_000e18
    function V_TOKEN_INIT() external view returns (uint256); // 1_073_000_000e18
    function MAX_CREATOR_TAX_BPS() external view returns (uint96); // 1_000
    function MAX_NAME_BYTES() external view returns (uint256); // 32
    function MAX_SYMBOL_BYTES() external view returns (uint256); // 10
    function MAX_NFT_ALLOCATION_BPS() external view returns (uint96); // 500
    function MAX_ROYALTY_BPS() external view returns (uint96); // 1_000
    function MAX_URI_BYTES() external view returns (uint256); // 200
    function MAX_PIECES() external view returns (uint256); // 1_000

    function LAUNCH_FACTORY() external view returns (address);
    function QUOTE() external view returns (address);
    function FEE_TOKEN() external view returns (address);
    function KEEPER() external view returns (address);
    function NATIVE_WRAP() external view returns (bool);

    /// TOTAL_SUPPLY * (10_000 - bps) / 10_000 - LP_SUPPLY
    function curveSupplyFor(uint96 nftAllocationBps) external pure returns (uint256);

    function createFill(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        bytes32 dualFillKey,
        uint256 target,
        uint64 deadline,
        uint64 publicUntil,
        bool openAlone,
        uint256 feeBudget
    ) external payable returns (address fill);

    function fillOf(address creator, bytes32 dualFillKey) external view returns (address);
    function isFill(address fill) external view returns (bool);
    function fillCount() external view returns (uint256);
    function fills(uint256 offset, uint256 limit) external view returns (address[] memory);
    /// The asset `fill` escrows, or zero for an address this factory did not deploy.
    function quoteOf(address fill) external view returns (address);
}
