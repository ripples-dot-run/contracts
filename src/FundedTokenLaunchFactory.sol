// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import {
    TokenLaunchFactory,
    LaunchParams,
    DevBuyParams,
    IVestingBinder
} from "./TokenLaunchFactory.sol";
import { Collection721, CollectionParams } from "./Collection721.sol";
import { LPLocker } from "./LPLocker.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";
import { ILaunchHook, SeedPlan } from "./hook/interfaces/ILaunchHook.sol";
import { PoolDeployer } from "./libraries/PoolDeployer.sol";
import { FundedPoolDeployer } from "./libraries/FundedPoolDeployer.sol";
import { CollectionDeployer } from "./libraries/CollectionDeployer.sol";
import { VestingDeployer } from "./libraries/VestingDeployer.sol";
import { ObjectVestingDeployer } from "./libraries/ObjectVestingDeployer.sol";

struct FundedAsset {
    bytes32 key;
    address token;
    address creator;
    bytes32 codeHash;
    uint256 inventory;
    uint256 maxLaunchFee;
    uint64 validUntil;
}

struct FundedLink {
    uint256 allocation;
    uint96 mintToCurveBps;
    uint96 maxProtocolFeeBps;
    uint64 vestDuration;
    uint64 vestCliff;
    bool objectClaim;
}

/// A market consumes an existing token inventory; this factory never creates or mints tokens.
/// The immutable coordinator must verify bridge peers, sealed mint authority and the global
/// inventory allocation before committing a plan. A code hash alone proves none of these.
contract FundedTokenLaunchFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    TokenLaunchFactory public immutable POLICY;
    address public immutable COORDINATOR;
    address public immutable launchHook;
    address public immutable poolManager;
    IERC20 public immutable FEE_TOKEN;

    mapping(bytes32 key => bytes32 commitment) public plans;
    mapping(bytes32 key => bool) public consumed;
    mapping(bytes32 key => address locker) public marketOf;
    mapping(address locker => bool) public isFromFactory;
    mapping(address locker => address token) public lockerToken;

    event PlanCommitted(bytes32 indexed key, bytes32 commitment);
    event FundedLaunchCreated(
        bytes32 indexed key,
        address indexed token,
        bytes32 indexed poolId,
        address creator,
        address locker,
        uint256 inventory,
        LaunchParams params
    );
    event LinkedLaunchCreated(
        bytes32 indexed key, address indexed collection, address vesting, uint256 allocation
    );

    error NotCoordinator();
    error InvalidBinding();
    error PlanAlreadyCommitted();
    error PlanMismatch();
    error PlanConsumed();
    error PlanExpired();
    error InvalidToken();
    error WrongPayment();
    error InvalidSupply();
    error InvalidReserves();
    error InvalidGraduation();
    error InvalidLockWindow();
    error InvalidIdentity();
    error CreatorTaxTooHigh();
    error QuoteNotApproved();
    error QuoteDecimalsMismatch();
    error QuoteEconomicsMismatch();
    error QuoteMismatch();
    error SeedSupplyTooThin();
    error SeedPriceOutOfBand();
    error InvalidAllocation();
    error InvalidVesting();
    error PriceOutOfRange();
    error FeeTooHigh();
    error NotStandalone();

    constructor(address policy, address coordinator) {
        if (policy.code.length == 0 || coordinator.code.length == 0) revert InvalidBinding();
        POLICY = TokenLaunchFactory(policy);
        COORDINATOR = coordinator;
        address hook = POLICY.launchHook();
        address manager = address(POLICY.POOL_MANAGER());
        if (hook.code.length == 0 || manager.code.length == 0) revert InvalidBinding();
        launchHook = hook;
        poolManager = manager;
        FEE_TOKEN = POLICY.FEE_TOKEN();
    }

    function treasury() public view returns (address) {
        return POLICY.treasury();
    }

    function owner() external view returns (address) {
        return POLICY.owner();
    }

    function assetOrigin() external view returns (string memory) {
        return POLICY.assetOrigin();
    }

    function commitPlan(bytes32 key, bytes32 commitment) external {
        if (msg.sender != COORDINATOR) revert NotCoordinator();
        if (key == bytes32(0) || commitment == bytes32(0)) revert PlanMismatch();
        if (plans[key] != bytes32(0)) revert PlanAlreadyCommitted();
        plans[key] = commitment;
        emit PlanCommitted(key, commitment);
    }

    function planHash(FundedAsset calldata asset, LaunchParams calldata p, DevBuyParams calldata d)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode("ripples-funded-token-v1", block.chainid, address(this), asset, p, d)
        );
    }

    function linkedPlanHash(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link,
        DevBuyParams calldata d
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                "ripples-funded-linked-v1", block.chainid, address(this), asset, p, np, link, d
            )
        );
    }

    function createLaunch(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        DevBuyParams calldata d
    ) external nonReentrant returns (address locker) {
        _authorize(asset, planHash(asset, p, d));
        validateLaunch(asset, p);
        _fund(asset);
        PoolDeployer.Opened memory opened = _open(asset, p, d, false);
        if (ILaunchHook(launchHook).configOf(PoolId.wrap(opened.poolId)).contributor != address(0))
        {
            revert NotStandalone();
        }
        _record(asset, p, opened);
        _buy(asset.creator, opened.locker, d);
        return opened.locker;
    }

    function createLinkedLaunch(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link,
        DevBuyParams calldata d
    ) external nonReentrant returns (address locker, address collection, address vesting) {
        _authorize(asset, linkedPlanHash(asset, p, np, link, d));
        validateLinkedLaunch(asset, p, np, link);
        _fund(asset);
        PoolDeployer.Opened memory opened = _open(asset, p, d, true);
        locker = opened.locker;
        _record(asset, p, opened);
        vesting = link.objectClaim
            ? ObjectVestingDeployer.deploy(asset.token, locker, link.vestDuration, link.vestCliff)
            : VestingDeployer.deploy(asset.token, locker, link.vestDuration, link.vestCliff);
        collection = CollectionDeployer.deploy(
            np,
            asset.creator,
            POLICY.nftProtocolFeeBps(),
            p.quote,
            treasury(),
            POLICY.platformSigner()
        );
        Collection721(collection)
            .linkToCurve(locker, vesting, link.mintToCurveBps, link.objectClaim);
        IVestingBinder(vesting).setCollection(collection);
        LPLocker(locker).setAllocation(vesting, collection, link.allocation, false);
        _transferExact(IERC20(asset.token), locker, link.allocation);
        emit LinkedLaunchCreated(asset.key, collection, vesting, link.allocation);
        _buy(asset.creator, locker, d);
    }

    function _authorize(FundedAsset calldata asset, bytes32 commitment) private {
        if (msg.sender != COORDINATOR) revert NotCoordinator();
        if (plans[asset.key] != commitment) revert PlanMismatch();
        if (consumed[asset.key]) revert PlanConsumed();
        if (block.timestamp > asset.validUntil) revert PlanExpired();
        consumed[asset.key] = true;
    }

    function validateLaunch(FundedAsset calldata asset, LaunchParams calldata p) public view {
        _validateToken(asset);
        _validate(asset, p, false);
        if (asset.inventory != p.curveSupply + p.lpTokenSupply) revert InvalidSupply();
    }

    function validateLinkedLaunch(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) public view {
        _validateToken(asset);
        _validate(asset, p, true);
        _validateLink(asset, p, np, link);
    }

    function _validateToken(FundedAsset calldata asset) private view {
        if (asset.creator == address(0) || asset.creator == address(this)) revert InvalidBinding();
        if (
            asset.token.code.length == 0 || asset.token.codehash != asset.codeHash
                || asset.token == address(FEE_TOKEN)
        ) revert InvalidToken();
        try IERC20Metadata(asset.token).decimals() returns (uint8 decimals) {
            if (decimals != 18) revert InvalidToken();
        } catch {
            revert InvalidToken();
        }
    }

    function _fund(FundedAsset calldata asset) private {
        uint256 fee = POLICY.launchFee();
        if (fee > asset.maxLaunchFee) revert FeeTooHigh();
        if (fee != 0) {
            _pullExact(FEE_TOKEN, fee);
            _transferExact(FEE_TOKEN, treasury(), fee);
        }
        _pullExact(IERC20(asset.token), asset.inventory);
    }

    function _open(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        DevBuyParams calldata d,
        bool linked
    ) private returns (PoolDeployer.Opened memory opened) {
        IERC20 token = IERC20(asset.token);
        uint256 supplyBefore = token.totalSupply();
        uint256 factoryBefore = token.balanceOf(address(this));
        uint256 seedable = p.curveSupply + p.lpTokenSupply;
        opened = FundedPoolDeployer.open(
            PoolDeployer.OpenParams({
                hook: launchHook,
                token: asset.token,
                quote: p.quote,
                creator: asset.creator,
                treasury: treasury(),
                seedable: seedable,
                vQuoteInit: p.vQuoteInit,
                vTokenInit: p.vTokenInit,
                graduationQuote: p.graduationQuote,
                tradeFeeBps: 100,
                creatorFeeBps: POLICY.LP_FEE_CREATOR_BPS(),
                creatorTaxBps: p.creatorTaxBps,
                snipeMaxBps: 9_900,
                snipeWindow: 3 seconds,
                unlockAt: type(uint64).max,
                linked: linked,
                snipeExempt: d.snipeExempt
            })
        );
        if (
            token.totalSupply() != supplyBefore
                || token.balanceOf(address(this)) != factoryBefore - seedable
        ) revert WrongPayment();
    }

    function _record(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        PoolDeployer.Opened memory opened
    ) private {
        marketOf[asset.key] = opened.locker;
        isFromFactory[opened.locker] = true;
        lockerToken[opened.locker] = asset.token;
        emit FundedLaunchCreated(
            asset.key, asset.token, opened.poolId, asset.creator, opened.locker, asset.inventory, p
        );
    }

    function _buy(address creator, address locker, DevBuyParams calldata d) private {
        if (d.initialBuy == 0) return;
        IERC20 quote = IERC20(LPLocker(locker).QUOTE());
        _pullExact(quote, d.initialBuy);
        _transferExact(quote, locker, d.initialBuy);
        LPLocker(locker).openingBuy(d.initialBuy, d.minTokensOut, creator);
    }

    function _validate(FundedAsset calldata asset, LaunchParams calldata p, bool linked)
        private
        view
    {
        if (p.quote == address(0) || p.quote == asset.token) revert QuoteMismatch();
        address registry = POLICY.quoteRegistry();
        if (registry == address(0) || !IQuoteRegistry(registry).approvedQuote(p.quote)) {
            revert QuoteNotApproved();
        }
        IQuoteRegistry.QuoteEconomics memory row = IQuoteRegistry(registry).quoteEconomics(p.quote);
        try IERC20Metadata(p.quote).decimals() returns (uint8 decimals) {
            if (decimals != row.decimals) revert QuoteDecimalsMismatch();
        } catch {
            revert QuoteDecimalsMismatch();
        }
        if (
            p.vQuoteInit != (linked ? row.phantomQuote : row.standalonePhantomQuote)
                || p.graduationQuote != row.graduationThreshold
        ) revert QuoteEconomicsMismatch();
        if (p.lpUnlockAt != 0) revert InvalidLockWindow();
        if (p.curveSupply == 0 || p.lpTokenSupply == 0) revert InvalidSupply();
        if (p.vTokenInit <= p.curveSupply || p.vQuoteInit == 0) revert InvalidReserves();
        if (p.graduationQuote == 0) revert InvalidGraduation();
        if (p.creatorTaxBps > 1_000) revert CreatorTaxTooHigh();
        if (
            bytes(p.name).length == 0 || bytes(p.name).length > 32 || bytes(p.symbol).length == 0
                || bytes(p.symbol).length > 10
                || keccak256(bytes(IERC20Metadata(asset.token).name())) != keccak256(bytes(p.name))
                || keccak256(bytes(IERC20Metadata(asset.token).symbol()))
                    != keccak256(bytes(p.symbol)) || bytes(p.logo).length == 0
                || bytes(p.logo).length > 512 || bytes(p.description).length > 2_048
                || bytes(p.twitter).length > 256 || bytes(p.telegram).length > 256
                || bytes(p.discord).length > 256 || bytes(p.website).length > 256
                || bytes(p.farcaster).length > 256
        ) revert InvalidIdentity();

        uint256 total = p.curveSupply + p.lpTokenSupply;
        uint256 vQuoteRef = p.vQuoteInit + p.graduationQuote;
        uint256 seedAtClose = Math.mulDiv(
            p.graduationQuote, Math.mulDiv(p.vTokenInit, p.vQuoteInit, vQuoteRef), vQuoteRef
        );
        uint256 seedable = total;
        if (linked) {
            if (Math.mulDiv(p.graduationQuote, p.vTokenInit, p.vQuoteInit) > total) {
                revert SeedSupplyTooThin();
            }
        } else {
            if (seedAtClose > total) revert SeedSupplyTooThin();
            seedable = total - seedAtClose;
        }
        uint256 ratioBps = Math.mulDiv(seedAtClose, 10_000, p.lpTokenSupply);
        if (ratioBps < 8_000 || ratioBps > 12_500) revert SeedPriceOutOfBand();
        SeedPlan memory plan = ILaunchHook(launchHook)
            .planFor(asset.token, p.quote, p.vQuoteInit, p.vTokenInit, p.graduationQuote);
        if (plan.tokenAmount > seedable) revert SeedSupplyTooThin();
    }

    function _validateLink(
        FundedAsset calldata asset,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) private view {
        if (
            link.allocation == 0
                || asset.inventory != p.curveSupply + p.lpTokenSupply + link.allocation
                || link.mintToCurveBps == 0 || link.mintToCurveBps > 10_000
        ) revert InvalidAllocation();
        if (link.vestCliff > 365 days || link.vestDuration > 1_460 days) revert InvalidVesting();
        if (np.royaltyBps > 1_000 || POLICY.nftProtocolFeeBps() > link.maxProtocolFeeBps) {
            revert FeeTooHigh();
        }
        if (np.quote != address(0) && np.quote != p.quote) revert QuoteMismatch();
        IQuoteRegistry.QuoteEconomics memory row =
            IQuoteRegistry(POLICY.quoteRegistry()).quoteEconomics(p.quote);
        if (
            np.priceQuote < row.minPriceQuote
                || Math.mulDiv(np.priceQuote, link.mintToCurveBps, 10_000) == 0
        ) {
            revert PriceOutOfRange();
        }
    }

    function _pullExact(IERC20 token, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(COORDINATOR);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();
        token.safeTransferFrom(COORDINATOR, address(this), amount);
        uint256 fromAfter = token.balanceOf(COORDINATOR);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (
            fromAfter > fromBefore || fromBefore - fromAfter != amount
                || balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount
                || token.totalSupply() != supplyBefore
        ) revert WrongPayment();
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private {
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();
        token.safeTransfer(to, amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 toAfter = token.balanceOf(to);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || toAfter < toBefore || toAfter - toBefore != amount
                || token.totalSupply() != supplyBefore
        ) revert WrongPayment();
    }
}
