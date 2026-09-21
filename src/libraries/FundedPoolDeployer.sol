// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary, PoolId } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { ILaunchHook, RegisterParams, SeedPlan } from "../hook/interfaces/ILaunchHook.sol";
import { LPLocker } from "../LPLocker.sol";
import { LockerDeployer } from "./LockerDeployer.sol";
import { PoolDeployer, IHookPoolManager } from "./PoolDeployer.sol";

/// Existing-token custody must be measured at the transfer, including when a predicted locker
/// received a donation before deployment. Existing minting factories keep their original library.
library FundedPoolDeployer {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    error WrongPayment();
    error PoolKeyMismatch();
    error SeedSupplyTooThin();

    function open(PoolDeployer.OpenParams memory o)
        external
        returns (PoolDeployer.Opened memory out)
    {
        IPoolManager manager = IHookPoolManager(o.hook).POOL_MANAGER();
        out.locker = LockerDeployer.deployLocker(
            manager,
            LockerDeployer.LockerParams({
                hook: o.hook,
                token: o.token,
                quote: o.quote,
                treasury: o.treasury,
                creator: o.creator,
                creatorFeeBps: o.creatorFeeBps,
                unlockAt: o.unlockAt
            })
        );
        address[] memory exempt = new address[](o.snipeExempt.length + 1);
        exempt[0] = out.locker;
        for (uint256 i; i < o.snipeExempt.length; i++) {
            exempt[i + 1] = o.snipeExempt[i];
        }
        (PoolKey memory key, SeedPlan memory plan) = ILaunchHook(o.hook)
            .register(
                RegisterParams({
                    token: o.token,
                    quote: o.quote,
                    locker: out.locker,
                    creator: o.creator,
                    contributor: o.linked ? out.locker : address(0),
                    vQuoteInit: o.vQuoteInit,
                    vTokenInit: o.vTokenInit,
                    graduationQuote: o.graduationQuote,
                    tradeFeeBps: o.tradeFeeBps,
                    creatorFeeBps: o.creatorFeeBps,
                    creatorTaxBps: o.creatorTaxBps,
                    snipeMaxBps: o.snipeMaxBps,
                    snipeWindow: o.snipeWindow,
                    snipeExempt: exempt
                })
            );
        if (
            Currency.unwrap(key.currency0) != (o.token < o.quote ? o.token : o.quote)
                || Currency.unwrap(key.currency1) != (o.token < o.quote ? o.quote : o.token)
        ) revert PoolKeyMismatch();
        if (plan.tokenAmount > o.seedable) revert SeedSupplyTooThin();
        IERC20 token = IERC20(o.token);
        uint256 before = token.balanceOf(address(this));
        uint256 lockerBefore = token.balanceOf(out.locker);
        token.safeTransfer(out.locker, o.seedable);
        if (
            token.balanceOf(address(this)) != before - o.seedable
                || token.balanceOf(out.locker) != lockerBefore + o.seedable
        ) revert WrongPayment();
        bool first = Currency.unwrap(key.currency0) == o.token;
        LPLocker(out.locker)
            .seedExact(
                key,
                plan.sqrtPriceX96,
                plan.tickLower,
                plan.tickUpper,
                plan.liquidity,
                first ? plan.tokenAmount : 0,
                first ? 0 : plan.tokenAmount
            );
        out.poolId = PoolId.unwrap(key.toId());
        out.liquidity = plan.liquidity;
        out.tickLower = plan.tickLower;
        out.tickUpper = plan.tickUpper;
        out.sqrtPriceX96 = plan.sqrtPriceX96;
        out.tokenSeeded = plan.tokenAmount;
    }
}
