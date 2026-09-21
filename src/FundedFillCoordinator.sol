// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TokenLaunchFactory, LaunchParams, DevBuyParams } from "./TokenLaunchFactory.sol";
import { FundedTokenLaunchFactory, FundedAsset, FundedLink } from "./FundedTokenLaunchFactory.sol";
import { HolderDistributorFactory } from "./HolderDistributorFactory.sol";
import { CollectionParams, Mode } from "./Collection721.sol";
import { FundedFill, FundedFillInit, IFundedFillCoordinator } from "./FundedFill.sol";
import { FundedFillDeployer } from "./libraries/FundedFillDeployer.sol";

interface ISealedBridgeAsset {
    function token() external view returns (address);
    function ASSET_ID() external view returns (bytes32);
    function GLOBAL_SUPPLY() external view returns (uint256);
    function CONFIG_HASH() external view returns (bytes32);
    function configurationSealed() external view returns (bool);
    function sharedDecimals() external view returns (uint8);
    function decimalConversionRate() external view returns (uint256);
}

struct FundedAssetRegistration {
    bytes32 assetId;
    bytes32 globalPlanHash;
    bytes32 localTermsHash;
    bytes32 bridgeConfigHash;
    address bridge;
    address token;
    address creator;
    uint256 globalSupply;
    uint256 inventory;
    uint256 allocation;
}

struct FundedFillConfig {
    bytes32 key;
    uint256 target;
    uint256 minTokensOut;
    uint256 feeBudget;
    uint64 publicUntil;
    uint64 deadline;
    bool routeToHolders;
}

/// The registrar must authenticate the complete cross-chain plan and its remote provenance.
/// Local sealed-bridge reads cannot prove remote peers, inventory sums or canonical backing.
/// Registration grants no custody rights: every refund is fixed to the original creator.
contract FundedFillCoordinator is IFundedFillCoordinator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Opening {
        FundedAsset asset;
        DevBuyParams buy;
        uint256 fee;
        uint256 tokenBefore;
        uint256 quoteBefore;
        uint256 feeBefore;
    }

    address public immutable REGISTRAR;
    address public immutable KEEPER;
    TokenLaunchFactory public immutable POLICY;
    FundedTokenLaunchFactory public immutable MARKET_FACTORY;
    address public immutable QUOTE;
    address public immutable FEE_TOKEN;
    bool public immutable NATIVE_WRAP;
    address public immutable HOLDER_FACTORY;

    mapping(bytes32 assetId => FundedAssetRegistration) private _assets;
    mapping(bytes32 assetId => bytes32) public tokenCodeHash;
    mapping(bytes32 assetId => address) public activeFill;
    mapping(bytes32 assetId => bool) public opened;
    mapping(bytes32 key => address) public fillOf;
    mapping(address fill => bool) public isFill;
    mapping(bytes32 assetId => mapping(bytes32 termsHash => bool)) public authorizedTerms;

    event AssetRegistered(bytes32 indexed assetId, address indexed token, bytes32 globalPlanHash);
    event AttemptAuthorized(bytes32 indexed assetId, bytes32 indexed localTermsHash);
    event FillCreated(
        bytes32 indexed key, bytes32 indexed assetId, address indexed fill, address creator
    );

    error NotRegistrar();
    error InvalidBinding();
    error AssetAlreadyRegistered();
    error AssetUnavailable();
    error WrongCreator();
    error InvalidTerms();
    error FillExists();
    error NotFill();
    error WrongPayment();
    error TermsNotAuthorized();

    // marketFactory can be the predicted address of the next deployment. Every create/open
    // verifies its immutable coordinator and policy; no setter completes this binding later.
    constructor(
        address registrar,
        address keeper,
        address policy,
        address marketFactory,
        bool nativeWrap,
        address holderFactory
    ) {
        if (
            registrar.code.length == 0 || keeper == address(0) || policy.code.length == 0
                || marketFactory == address(0)
        ) revert InvalidBinding();
        REGISTRAR = registrar;
        KEEPER = keeper;
        POLICY = TokenLaunchFactory(policy);
        MARKET_FACTORY = FundedTokenLaunchFactory(marketFactory);
        QUOTE = POLICY.QUOTE();
        FEE_TOKEN = address(POLICY.FEE_TOKEN());
        if (nativeWrap && QUOTE != FEE_TOKEN) revert InvalidBinding();
        NATIVE_WRAP = nativeWrap;
        if (holderFactory != address(0)) {
            if (holderFactory.code.length == 0) revert InvalidBinding();
            HolderDistributorFactory holders = HolderDistributorFactory(holderFactory);
            if (
                address(holders.HOOK()) != POLICY.launchHook() || holders.PUBLISHER() == address(0)
                    || holders.FINALITY_DELAY() == 0
            ) revert InvalidBinding();
        }
        HOLDER_FACTORY = holderFactory;
    }

    function asset(bytes32 assetId) external view returns (FundedAssetRegistration memory) {
        return _assets[assetId];
    }

    function registerAsset(FundedAssetRegistration calldata registration) external {
        if (msg.sender != REGISTRAR) revert NotRegistrar();
        if (_assets[registration.assetId].token != address(0)) revert AssetAlreadyRegistered();
        if (
            registration.assetId == bytes32(0) || registration.globalPlanHash == bytes32(0)
                || registration.localTermsHash == bytes32(0) || registration.creator == address(0)
                || registration.token.code.length == 0 || registration.token == QUOTE
                || registration.token == FEE_TOKEN || registration.inventory == 0
                || registration.inventory > registration.globalSupply
                || registration.allocation >= registration.inventory
                || registration.allocation > Math.mulDiv(registration.globalSupply, 500, 10_000)
        ) revert InvalidTerms();
        _verifyBridge(registration);
        _assets[registration.assetId] = registration;
        tokenCodeHash[registration.assetId] = registration.token.codehash;
        authorizedTerms[registration.assetId][registration.localTermsHash] = true;
        emit AssetRegistered(registration.assetId, registration.token, registration.globalPlanHash);
        emit AttemptAuthorized(registration.assetId, registration.localTermsHash);
    }

    /// A retry needs a newly authenticated complete attempt. Old terms and fills stay immutable.
    function authorizeAttempt(bytes32 assetId, bytes32 localTermsHash) external {
        if (msg.sender != REGISTRAR) revert NotRegistrar();
        if (_assets[assetId].token == address(0) || opened[assetId]) revert AssetUnavailable();
        if (localTermsHash == bytes32(0) || authorizedTerms[assetId][localTermsHash]) {
            revert InvalidTerms();
        }
        authorizedTerms[assetId][localTermsHash] = true;
        emit AttemptAuthorized(assetId, localTermsHash);
    }

    function termsHash(
        bytes32 assetId,
        FundedFillConfig calldata config,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("crosscurrent.funded-fill.terms.v2"),
                block.chainid,
                address(this),
                assetId,
                config,
                p,
                np,
                link
            )
        );
    }

    function createFill(
        bytes32 assetId,
        FundedFillConfig calldata config,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) external nonReentrant returns (address fill) {
        _checkFactory();
        FundedAssetRegistration memory registered = _assets[assetId];
        if (registered.creator != msg.sender) revert WrongCreator();
        if (opened[assetId]) revert AssetUnavailable();
        address previous = activeFill[assetId];
        if (previous != address(0)) {
            FundedFill prior = FundedFill(payable(previous));
            if (!prior.refundable() || !prior.inventoryReturned()) revert AssetUnavailable();
        }
        if (!authorizedTerms[assetId][termsHash(assetId, config, p, np, link)]) {
            revert TermsNotAuthorized();
        }
        _verifyBridge(registered);
        if (registered.token.codehash != tokenCodeHash[assetId]) revert InvalidBinding();
        _checkTerms(registered, config, p, np, link);
        FundedFillInit memory init = FundedFillInit({
            key: config.key,
            assetId: assetId,
            paramsHash: keccak256(abi.encode(p, np, link)),
            creator: msg.sender,
            token: registered.token,
            quote: p.quote,
            feeToken: FEE_TOKEN,
            keeper: KEEPER,
            nativeWrap: NATIVE_WRAP && p.quote == QUOTE,
            hook: MARKET_FACTORY.launchHook(),
            holderFactory: HOLDER_FACTORY,
            routeToHolders: config.routeToHolders,
            inventory: registered.inventory,
            target: config.target,
            minTokensOut: config.minTokensOut,
            feeBudget: config.feeBudget,
            publicUntil: config.publicUntil,
            deadline: config.deadline
        });
        fill = FundedFillDeployer.deploy(init);
        isFill[fill] = true;
        fillOf[config.key] = fill;
        activeFill[assetId] = fill;
        (FundedAsset memory marketAsset, DevBuyParams memory buy) =
            _marketArgs(FundedFill(payable(fill)));
        if (registered.allocation == 0) MARKET_FACTORY.validateLaunch(marketAsset, p);
        else MARKET_FACTORY.validateLinkedLaunch(marketAsset, p, np, link);
        bytes32 commitment = registered.allocation == 0
            ? MARKET_FACTORY.planHash(marketAsset, p, buy)
            : MARKET_FACTORY.linkedPlanHash(marketAsset, p, np, link, buy);
        MARKET_FACTORY.commitPlan(config.key, commitment);
        _moveExact(registered.token, msg.sender, fill, registered.inventory);
        _moveExact(FEE_TOKEN, msg.sender, fill, config.feeBudget);
        emit FillCreated(config.key, assetId, fill, msg.sender);
    }

    function launchFee() public view returns (uint256) {
        return POLICY.launchFee();
    }

    function openMarket(
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) external nonReentrant returns (address locker, address collection, address vesting) {
        if (!isFill[msg.sender]) revert NotFill();
        _checkFactory();
        FundedFill fill = FundedFill(payable(msg.sender));
        bytes32 assetId = fill.ASSET_ID();
        if (activeFill[assetId] != msg.sender || opened[assetId]) revert AssetUnavailable();
        if (fill.PARAMS_HASH() != keccak256(abi.encode(p, np, link))) revert InvalidTerms();
        FundedAssetRegistration memory registered = _assets[assetId];
        _verifyBridge(registered);
        if (registered.token.codehash != tokenCodeHash[assetId]) revert InvalidBinding();
        address quote = fill.QUOTE();
        Opening memory opening;
        (opening.asset, opening.buy) = _marketArgs(fill);
        opening.fee = launchFee();
        if (opening.fee > fill.FEE_BUDGET()) revert InvalidTerms();
        opening.tokenBefore = IERC20(registered.token).balanceOf(address(this));
        opening.quoteBefore = IERC20(quote).balanceOf(address(this));
        opening.feeBefore = IERC20(FEE_TOKEN).balanceOf(address(this));
        _moveExact(registered.token, msg.sender, address(this), registered.inventory);
        _moveExact(
            quote,
            msg.sender,
            address(this),
            opening.buy.initialBuy + (quote == FEE_TOKEN ? opening.fee : 0)
        );
        if (quote != FEE_TOKEN) _moveExact(FEE_TOKEN, msg.sender, address(this), opening.fee);
        _approve(registered.token, registered.inventory);
        _approve(quote, opening.buy.initialBuy + (quote == FEE_TOKEN ? opening.fee : 0));
        if (quote != FEE_TOKEN) _approve(FEE_TOKEN, opening.fee);
        if (registered.allocation == 0) {
            locker = MARKET_FACTORY.createLaunch(opening.asset, p, opening.buy);
        } else {
            (locker, collection, vesting) =
                MARKET_FACTORY.createLinkedLaunch(opening.asset, p, np, link, opening.buy);
        }
        _approve(registered.token, 0);
        _approve(quote, 0);
        if (quote != FEE_TOKEN) _approve(FEE_TOKEN, 0);
        if (
            IERC20(registered.token).balanceOf(address(this)) != opening.tokenBefore
                || IERC20(quote).balanceOf(address(this)) != opening.quoteBefore
                || IERC20(FEE_TOKEN).balanceOf(address(this)) != opening.feeBefore
        ) revert WrongPayment();
        opened[assetId] = true;
    }

    function _marketArgs(FundedFill fill)
        private
        view
        returns (FundedAsset memory marketAsset, DevBuyParams memory buy)
    {
        marketAsset = FundedAsset({
            key: fill.KEY(),
            token: fill.TOKEN(),
            creator: address(fill),
            codeHash: tokenCodeHash[fill.ASSET_ID()],
            inventory: fill.INVENTORY(),
            maxLaunchFee: fill.FEE_BUDGET(),
            validUntil: fill.DEADLINE() + 15 minutes
        });
        buy = DevBuyParams({
            initialBuy: fill.TARGET(),
            minTokensOut: fill.MIN_TOKENS_OUT(),
            snipeExempt: new address[](0)
        });
    }

    function _checkFactory() private view {
        if (
            address(MARKET_FACTORY).code.length == 0
                || MARKET_FACTORY.COORDINATOR() != address(this)
                || address(MARKET_FACTORY.POLICY()) != address(POLICY)
                || MARKET_FACTORY.launchHook() != POLICY.launchHook()
        ) revert InvalidBinding();
    }

    function _checkTerms(
        FundedAssetRegistration memory registered,
        FundedFillConfig calldata config,
        LaunchParams calldata p,
        CollectionParams calldata np,
        FundedLink calldata link
    ) private view {
        if (config.key == bytes32(0) || fillOf[config.key] != address(0)) revert FillExists();
        if (
            config.deadline < block.timestamp + 10 minutes
                || config.deadline > block.timestamp + 1 days
                || config.publicUntil < block.timestamp + 10 minutes
                || config.publicUntil > config.deadline || config.target < 4
                || config.target > Math.mulDiv(p.graduationQuote, 4_000, 10_000)
                || config.minTokensOut == 0 || config.feeBudget < launchFee()
                || (config.routeToHolders && HOLDER_FACTORY == address(0))
                || p.curveSupply + p.lpTokenSupply + link.allocation != registered.inventory
                || link.allocation != registered.allocation
        ) revert InvalidTerms();
        if (
            registered.allocation != 0
                && (np.mode != Mode.PREGEN
                    || bytes(np.baseURI).length == 0
                    || bytes(np.baseURI).length > 200
                    || np.maxSupply == 0
                    || np.maxSupply > 1_000
                    || np.perWalletCap > 65_535
                    || np.startTime != 0
                    || np.endTime != 0)
        ) revert InvalidTerms();
    }

    function _verifyBridge(FundedAssetRegistration memory registered) private view {
        if (registered.bridge.code.length == 0) revert InvalidBinding();
        ISealedBridgeAsset bridge = ISealedBridgeAsset(registered.bridge);
        if (
            !bridge.configurationSealed() || bridge.token() != registered.token
                || bridge.ASSET_ID() != registered.assetId
                || bridge.GLOBAL_SUPPLY() != registered.globalSupply
                || bridge.CONFIG_HASH() != registered.bridgeConfigHash
                || bridge.sharedDecimals() != 6 || bridge.decimalConversionRate() != 1e12
        ) revert InvalidBinding();
    }

    function _approve(address token, uint256 amount) private {
        IERC20(token).forceApprove(address(MARKET_FACTORY), amount);
    }

    function _moveExact(address tokenAddress, address from, address to, uint256 amount) private {
        if (amount == 0) return;
        IERC20 token = IERC20(tokenAddress);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();
        token.safeTransferFrom(from, to, amount);
        if (
            token.balanceOf(from) != fromBefore - amount || token.balanceOf(to) != toBefore + amount
                || token.totalSupply() != supplyBefore
        ) revert WrongPayment();
    }
}
