// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { CollectionParams } from "./Collection721.sol";
import { ScoutRegistry } from "./ScoutRegistry.sol";
import { WorkSplit } from "./WorkSplit.sol";
import {
    DevBuyParams,
    LaunchParams,
    LinkedParams,
    TokenLaunchFactory
} from "./TokenLaunchFactory.sol";

/// @title WorkSplitFactory
/// @notice Deploys the splits that pay a launch's commission, and is the record of which ones
///         are real.
///
/// A published commission is only worth reading if the contract enforcing it is the one whose
/// code was reviewed, so the address a launch names as its creator has to be checkable against
/// something. That is this factory's first job: `isFromFactory(split)` answers it in one read,
/// and the launch factory every split launches through is fixed here rather than passed in by
/// whoever deploys one.
///
/// Its second job is the map back. A page that has a token address, or a collection address, has
/// to be able to find the commission without an indexer, so a split writes both here on the way
/// out of its launch and `splitOfToken` and `splitOfCollection` answer in one read.
///
/// **The registry is deployed here, in this constructor.** A split's registry is immutable and
/// this factory has no setters, so the factory has to know the registry before it deploys a
/// split, and the registry has to know the factory to refuse a split that did not come from it.
/// Deploying the registry from here is what breaks that circle without an address prediction and
/// without a setter that would outlive it.
///
/// No owner, no fee, no pause and no list of permitted callers. Anyone may deploy a split;
/// opening a launch through one still costs the launch fee everybody pays.
contract WorkSplitFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// The launch factory every split from here launches through.
    address public immutable TOKEN_FACTORY;
    /// What a launch is funded in, which is the launch factory's fee token. Read once here so
    /// `createAndLaunch` moves the runway in the asset the split will actually spend rather than
    /// in one a caller named.
    IERC20 public immutable RUNWAY_ASSET;
    /// The one registry every split from here reads a buyer's scout binding from.
    address public immutable SCOUT_REGISTRY;

    address[] public allSplits;
    mapping(address split => bool) public isFromFactory;
    /// Written once per split by `recordLaunch`, from the split itself, at the end of its own
    /// launch. The launch factory deploys both addresses inside that call, so neither can
    /// collide with a record an earlier launch left.
    mapping(address collection => address split) public splitOfCollection;
    mapping(address token => address split) public splitOfToken;
    /// A split that has already recorded its launch. `WorkSplit.launch` is one-shot on its own
    /// side; this is the half of that promise this contract can check for itself.
    mapping(address split => bool) public hasRecorded;

    event WorkSplitCreated(
        address indexed artist,
        address indexed split,
        address indexed tradeScout,
        uint96 commissionBps
    );
    event LaunchRecorded(address indexed split, address indexed token, address indexed collection);

    error ZeroAddress();
    error NotAContract();
    /// A caller that this factory did not deploy, trying to write the map back to itself.
    error NotASplit();
    error AlreadyRecorded();
    /// A launch with nothing to pay its own fee with.
    error NoRunway();
    /// The runway asset moved less than it reported.
    error WrongPayment();

    constructor(address tokenFactory) {
        if (tokenFactory == address(0)) revert ZeroAddress();
        if (tokenFactory.code.length == 0) revert NotAContract();
        IERC20 runway = TokenLaunchFactory(tokenFactory).FEE_TOKEN();
        // A launch factory answering zero here would deploy splits that read right and can never
        // be funded: every `createAndLaunch` reverts inside `IERC20(0).balanceOf`, and a split
        // funded by hand has no asset to pay its own launch fee in. Caught in the constructor
        // because the answer is copied into an immutable and there is no setter to correct it.
        if (address(runway) == address(0)) revert ZeroAddress();

        TOKEN_FACTORY = tokenFactory;
        RUNWAY_ASSET = runway;
        SCOUT_REGISTRY = address(new ScoutRegistry(address(this)));
    }

    /// @notice Deploy a split that pays `artist` everything `commissionBps` does not take.
    /// @param tradeScout The standing scout for trade fees, or zero for a launch whose whole fee
    ///        stream is the artist's. Set here and never again.
    function create(address artist, uint96 commissionBps, address tradeScout)
        external
        nonReentrant
        returns (address)
    {
        return _create(artist, commissionBps, tradeScout);
    }

    /// @notice Deploy the split, fund it, and open its launch, in one transaction.
    /// @dev This is the shape the site uses. Deploying, funding and launching as three separate
    ///      transactions leaves a window where the split holds an artist's money and has no
    ///      launch, and the only way out of it is the artist coming back to the same address
    ///      with the same wallet. Here the three either all happen or none of them do.
    /// @param runway What to put in the split, in `RUNWAY_ASSET`. It has to cover the launch fee
    ///        and any opening buy, both of which the launch spends inside this call. Anything
    ///        beyond them stays in the split and is released to the artist on the first settle.
    function createAndLaunch(
        address artist,
        uint96 commissionBps,
        address tradeScout,
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d,
        uint256 runway
    )
        external
        nonReentrant
        returns (address split, address token, address locker, address collection, address vesting)
    {
        split = _create(artist, commissionBps, tradeScout);
        _fund(split, runway);
        (token, locker, collection, vesting) = WorkSplit(payable(split)).launch(tp, np, lp, d);
    }

    /// @notice Record which launch a split opened, so a page holding either address can find the
    ///         commission in one read.
    /// @dev Only a split this factory deployed may call it, and only once, so nothing but a real
    ///      split can claim a token or a collection. It is a callback rather than something this
    ///      factory writes around `createAndLaunch` because an artist may deploy a split in one
    ///      transaction and open its launch in another, when this contract is no longer in the
    ///      call stack.
    function recordLaunch(address token, address collection) external {
        if (!isFromFactory[msg.sender]) revert NotASplit();
        if (hasRecorded[msg.sender]) revert AlreadyRecorded();
        hasRecorded[msg.sender] = true;
        splitOfToken[token] = msg.sender;
        splitOfCollection[collection] = msg.sender;
        emit LaunchRecorded(msg.sender, token, collection);
    }

    function splitCount() external view returns (uint256) {
        return allSplits.length;
    }

    function splits(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = allSplits.length;
        if (offset >= total) return new address[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = allSplits[i];
        }
    }

    function _create(address artist, uint96 commissionBps, address tradeScout)
        private
        returns (address)
    {
        WorkSplit split =
            new WorkSplit(artist, TOKEN_FACTORY, SCOUT_REGISTRY, commissionBps, tradeScout);
        allSplits.push(address(split));
        isFromFactory[address(split)] = true;
        emit WorkSplitCreated(artist, address(split), tradeScout, commissionBps);
        return address(split);
    }

    /// Measured on both sides rather than trusted, so an asset that reports a move it did not
    /// make cannot leave a split short of the fee it is about to be asked for.
    function _fund(address split, uint256 runway) private {
        if (runway == 0) revert NoRunway();
        uint256 fromBefore = RUNWAY_ASSET.balanceOf(msg.sender);
        uint256 toBefore = RUNWAY_ASSET.balanceOf(split);
        RUNWAY_ASSET.safeTransferFrom(msg.sender, split, runway);
        if (
            fromBefore - RUNWAY_ASSET.balanceOf(msg.sender) != runway
                || RUNWAY_ASSET.balanceOf(split) - toBefore != runway
        ) revert WrongPayment();
    }
}
