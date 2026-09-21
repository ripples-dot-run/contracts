// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { LaunchParams } from "../TokenLaunchFactory.sol";
import { FillTerms } from "./IDualFillAgentFactory.sol";

interface IDualFillAgentTreasury {
    event FillStarted(address indexed fill, bytes32 indexed dualFillKey, uint256 feeBudget);
    event Bound(address indexed token, address indexed locker);
    event FillCancelled(address indexed fill);
    event RunwayReturned(address indexed to, uint256 amount);
    /// The fee token going back to the funder, on a treasury whose quote is another asset.
    event BondReturned(address indexed to, uint256 amount);
    event Bought(uint256 spent, uint256 received);
    event Sold(uint256 sold, uint256 received);
    event Paid(address indexed to, uint256 amount);
    event FeesClaimed(uint256 quoteAmount, uint256 tokenAmount);
    event Noted(bytes32 indexed digest, string uri);
    event OperatorRetired();

    error ZeroAddress();
    error NotAContract();
    error NotCreator();
    error NotOperator();
    error NotAgentFactory();
    error AlreadyStarted();
    error NotOpened();
    error NotRefundable();
    error NothingToReturn();
    error FillMismatch();
    error NoVenue();
    error ZeroAmount();
    error AmountTooLarge();
    error TooManyPayees();
    error DuplicatePayee();
    error InvalidSpendLimits();
    error CreatorInCharter();
    error OverDailySpend(uint256 requested, uint256 limit);
    error OverCallSpend(uint256 requested, uint256 limit);
    error OverDailySell(uint256 requested, uint256 limit);
    error SellsIncomeOnly(uint256 requested, uint256 sellable);
    error NotPayee(address to);
    error SnipeWindowOpen();
    error Retired();
    error AlreadyRetired();
    error QuoteMismatch();
    error UnexpectedBalance();

    function MAX_PAYEES() external view returns (uint256); // 8
    function CREATOR() external view returns (address);
    function AGENT_FACTORY() external view returns (address);
    function OPERATOR() external view returns (address);
    /// The market's asset: runway, meters, buys, sells and payments.
    function QUOTE() external view returns (address);
    /// The bond's asset. `QUOTE` on a WETH fill; on any other, an asset the charter cannot spend.
    function FEE_TOKEN() external view returns (address);
    function LAUNCH_FACTORY() external view returns (address);
    function FILL_FACTORY() external view returns (address);
    function ROUTER() external view returns (address);
    function PERMIT2() external view returns (address);
    function DUAL_FILL_KEY() external view returns (bytes32);
    function DAILY_SPEND() external view returns (uint128);
    function PER_CALL_SPEND() external view returns (uint128);
    function DAILY_SELL() external view returns (uint128);

    function fill() external view returns (address);
    function token() external view returns (address);
    function locker() external view returns (address);
    function boughtTokens() external view returns (uint256);
    function isPayee(address payee) external view returns (bool);
    function retired() external view returns (bool);

    function startFill(LaunchParams calldata p, FillTerms calldata t)
        external
        returns (address fill_);
    function bind() external returns (address token_);
    function buy(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 spent, uint256 received);
    function sell(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 sold, uint256 received);
    function pay(address to, uint256 amount) external;
    function note(bytes32 digest, string calldata uri) external;
    function claimFees() external returns (uint256 quoteAmount, uint256 tokenAmount);
    function cancelFill() external;
    function retireOperator() external;
    function returnRunway() external returns (uint256 amount);
    /// Opened only, and only where FEE_TOKEN is not QUOTE: the fee token's whole balance to
    /// CREATOR. NothingToReturn on a WETH fill, where that balance is runway.
    function returnBond() external returns (uint256 amount);

    /// Same tuple as AgentTreasury.charter(); dailyMint is always 0.
    function charter()
        external
        view
        returns (
            address operator,
            uint128 dailySpend,
            uint128 perCallSpend,
            uint128 dailySell,
            uint32 dailyMint,
            address[] memory payees
        );
    /// Same types as AgentTreasury.remainingToday(). `sell` is what is left of today's sell meter (AgentTreasury names it
    /// `sellable`); mintable is always 0.
    function remainingToday() external view returns (uint256 spend, uint256 sell, uint256 mintable);
    /// balanceOf(token) − boughtTokens, 0 before bind.
    function sellableTokens() external view returns (uint256);
    function payees() external view returns (address[] memory);
}
