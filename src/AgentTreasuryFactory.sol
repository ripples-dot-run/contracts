// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AgentTreasury, Charter } from "./AgentTreasury.sol";
import { CollectionParams } from "./Collection721.sol";
import {
    DevBuyParams,
    LaunchParams,
    LinkedParams,
    TokenLaunchFactory
} from "./TokenLaunchFactory.sol";

/// @title AgentTreasuryFactory
/// @notice Deploys agent treasuries and is the record of which ones are real.
///
/// A treasury's charter is only worth reading if the contract enforcing it is the one whose code
/// was reviewed, so the address a launch names as its creator has to be checkable against
/// something. That is this factory's whole job: `isFromFactory(treasury)` answers it in one read,
/// and the launch factory, the venue and the allowance ledger every treasury is built with are
/// fixed here rather than passed in by whoever deploys one.
///
/// No owner, no fee, no pause and no list of permitted callers. Anyone may deploy a treasury;
/// creating a launch through it still costs the launch fee the token factory charges everyone.
contract AgentTreasuryFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// The launch factory every treasury from here launches through.
    address public immutable TOKEN_FACTORY;
    /// What a treasury holds and meters in, which is the launch factory's fee token. Read once
    /// here so `createAndLaunch` moves the runway in the asset the treasury will actually use
    /// rather than in one a caller named.
    IERC20 public immutable RUNWAY_ASSET;
    /// The venue every treasury from here trades through. Zero deploys treasuries that cannot
    /// trade, which is a chain with no router deployed rather than a setting anyone chooses.
    address public immutable ROUTER;
    address public immutable PERMIT2;

    address[] public allTreasuries;
    mapping(address treasury => bool) public isFromFactory;

    event AgentTreasuryCreated(
        address indexed creator, address indexed treasury, address indexed operator
    );

    error ZeroAddress();
    error NotAContract();
    /// A launch with nothing to pay its own fee with.
    error NoRunway();
    /// The runway asset moved less than it reported.
    error WrongPayment();

    constructor(address tokenFactory, address router, address permit2) {
        if (tokenFactory == address(0)) revert ZeroAddress();
        if (tokenFactory.code.length == 0) revert NotAContract();
        if (router != address(0) && (router.code.length == 0 || permit2.code.length == 0)) {
            revert NotAContract();
        }
        TOKEN_FACTORY = tokenFactory;
        RUNWAY_ASSET = TokenLaunchFactory(tokenFactory).FEE_TOKEN();
        ROUTER = router;
        PERMIT2 = permit2;
    }

    /// @notice Deploy a treasury with `c` as its charter, owned by nobody and answering to
    ///         `c.operator` for the five operator calls, four of which are metered. The caller is its creator: they fund it
    ///         and they open its launch, and that is the extent of it.
    function create(Charter calldata c) external nonReentrant returns (address) {
        return _create(c);
    }

    /// @notice Deploy the treasury, fund it, and open its launch, in one transaction.
    /// @dev This is the shape a creator should use. Deploying, funding and launching as three
    ///      separate transactions leaves a window where the treasury holds the runway and has no
    ///      launch, and the only way out of it is the creator coming back to the same address
    ///      with the same wallet. Here the three either all happen or none of them do.
    /// @param runway What to put in the treasury, in `RUNWAY_ASSET`. It has to cover the launch
    ///        fee and any opening buy, both of which the launch spends inside this call.
    function createAndLaunch(
        Charter calldata c,
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d,
        uint256 runway
    )
        external
        nonReentrant
        returns (
            address treasury,
            address token,
            address locker,
            address collection,
            address vesting
        )
    {
        treasury = _create(c);
        _fund(treasury, runway);
        (token, locker, collection, vesting) = AgentTreasury(treasury).launch(tp, np, lp, d);
    }

    function treasuryCount() external view returns (uint256) {
        return allTreasuries.length;
    }

    function treasuries(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = allTreasuries.length;
        if (offset >= total) return new address[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = allTreasuries[i];
        }
    }

    function _create(Charter calldata c) private returns (address) {
        AgentTreasury treasury = new AgentTreasury(msg.sender, TOKEN_FACTORY, ROUTER, PERMIT2, c);
        allTreasuries.push(address(treasury));
        isFromFactory[address(treasury)] = true;
        emit AgentTreasuryCreated(msg.sender, address(treasury), c.operator);
        return address(treasury);
    }

    /// Measured on both sides rather than trusted, so an asset that reports a move it did not
    /// make cannot leave a treasury short of the fee it is about to be asked for.
    function _fund(address treasury, uint256 runway) private {
        if (runway == 0) revert NoRunway();
        uint256 fromBefore = RUNWAY_ASSET.balanceOf(msg.sender);
        uint256 toBefore = RUNWAY_ASSET.balanceOf(treasury);
        RUNWAY_ASSET.safeTransferFrom(msg.sender, treasury, runway);
        if (
            fromBefore - RUNWAY_ASSET.balanceOf(msg.sender) != runway
                || RUNWAY_ASSET.balanceOf(treasury) - toBefore != runway
        ) revert WrongPayment();
    }
}
