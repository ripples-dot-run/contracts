// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { Pool } from "v4-core/src/libraries/Pool.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { LiquidityAmounts } from "./LiquidityAmounts.sol";
import { LPLocker } from "../LPLocker.sol";
import { ILaunchHook, RegisterParams, SeedPlan } from "../hook/interfaces/ILaunchHook.sol";
import { LockerDeployer } from "./LockerDeployer.sol";

/// The one thing the hook knows that `ILaunchHook` does not say out loud: which PoolManager it
/// was mined against. A launch's locker is bound to it permanently, so it is read from the hook
/// rather than passed in, and a factory wired to the wrong manager cannot produce a launch that
/// disagrees with its own pool.
interface IHookPoolManager {
    // solhint-disable-next-line func-name-mixedcase
    function POOL_MANAGER() external view returns (IPoolManager);
}

/// @notice Opens a launch's market: the locker, the hook registration, the pool, and the curve
///         position, in the one order they can happen in.
///
///         Split out of `TokenLaunchFactory` for the reason every deployer library was: the
///         factory's runtime stood at 22,743 bytes of the 24,576 EIP-170 allows, and opening a
///         Uniswap v4 pool inside the launch transaction is not a change that fits in 1,833
///         bytes. Called by `delegatecall`, so every call below is made **by the factory**:
///         the hook sees the factory as the launchpad registering the launch, and the token the
///         factory holds is what funds the position.
///
///         Nothing here decides a price. The hook computes the position from the launch's own
///         curve parameters at `register` and then refuses any other opening price and any other
///         position, so this library's job is to carry the plan across, unchanged, and to refuse
///         a launch whose plan does not fit the supply it minted.
library PoolDeployer {
    using SafeERC20 for IERC20;

    /// How far `fitLiquidity` walks down from the periphery helper's answer before it gives up.
    /// The helper is off by at most one unit; three is the margin, not the expectation.
    uint256 private constant FIT_STEPS = 3;

    /// The plan needs more of the launch token than the launch has to give. Raised here rather
    /// than at the seed, so a misconfigured launch fails before its pool exists.
    error SeedSupplyTooThin();
    /// The hook returned a key that is not this launch's, which would mean the pool the factory
    /// is about to record is not the pool the hook registered.
    error PoolKeyMismatch();
    /// The periphery's liquidity helper and v4's own deposit math still disagree after the walk
    /// below. Unreachable for a one-unit rounding difference, which is the only one there is.
    error LiquidityDoesNotFit();

    struct OpenParams {
        address hook;
        address token;
        address quote;
        address creator;
        address treasury;
        /// The launch supply this contract holds and the locker is to take custody of: the whole
        /// mint less a linked launch's reserved slice, which is withheld before the seed because
        /// the position takes what it needs out of what is left.
        uint256 seedable;
        uint256 vQuoteInit;
        uint256 vTokenInit;
        uint256 graduationQuote;
        uint96 tradeFeeBps;
        uint96 creatorFeeBps;
        uint96 creatorTaxBps;
        uint96 snipeMaxBps;
        uint64 snipeWindow;
        uint64 unlockAt;
        /// A linked launch routes its collection's mint revenue into the raise through the
        /// locker, which is the only contract that both custodies the quote and is admitted to
        /// the hook's contribution accounting. A standalone launch never contributes at all.
        bool linked;
        address[] snipeExempt;
    }

    struct Opened {
        address locker;
        bytes32 poolId;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint256 tokenSeeded;
    }

    function open(OpenParams memory o) external returns (Opened memory out) {
        IPoolManager poolManager = IHookPoolManager(o.hook).POOL_MANAGER();
        out.locker = LockerDeployer.deployLocker(
            poolManager,
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

        (PoolKey memory key, SeedPlan memory plan) =
            ILaunchHook(o.hook).register(_registerParams(o, out.locker));
        // The factory records this pool id and emits it, and a third party derives markets from
        // it with no index. Deriving it twice and comparing is the cheapest way to know the
        // record is the pool.
        if (
            Currency.unwrap(key.currency0) != (o.token < o.quote ? o.token : o.quote)
                || Currency.unwrap(key.currency1) != (o.token < o.quote ? o.quote : o.token)
        ) revert PoolKeyMismatch();
        if (plan.tokenAmount > o.seedable) revert SeedSupplyTooThin();

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == o.token;
        IERC20(o.token).safeTransfer(out.locker, o.seedable);
        LPLocker(out.locker)
            .seedExact(
                key,
                plan.sqrtPriceX96,
                plan.tickLower,
                plan.tickUpper,
                plan.liquidity,
                tokenIsCurrency0 ? plan.tokenAmount : 0,
                tokenIsCurrency0 ? 0 : plan.tokenAmount
            );

        out.poolId = PoolId.unwrap(key.toId());
        out.liquidity = plan.liquidity;
        out.tickLower = plan.tickLower;
        out.tickUpper = plan.tickUpper;
        out.sqrtPriceX96 = plan.sqrtPriceX96;
        out.tokenSeeded = plan.tokenAmount;
    }

    /// The launch, as the hook records it. Every field is fixed here and nothing, including the
    /// hook's owner, can change it afterwards.
    ///
    /// `snipeExempt` leads with the locker because the opening tax keys on the address that calls
    /// the PoolManager, which for the launch's own first buy is the locker and never the creator
    /// the buy is for. The hook exempts the creator too, which costs nothing and matches what
    /// the curve rail's own exemption recorded.
    function _registerParams(OpenParams memory o, address locker)
        private
        pure
        returns (RegisterParams memory p)
    {
        address[] memory exempt = new address[](o.snipeExempt.length + 1);
        exempt[0] = locker;
        for (uint256 i = 0; i < o.snipeExempt.length; i++) {
            exempt[i + 1] = o.snipeExempt[i];
        }
        p = RegisterParams({
            token: o.token,
            quote: o.quote,
            locker: locker,
            creator: o.creator,
            contributor: o.linked ? locker : address(0),
            vQuoteInit: o.vQuoteInit,
            vTokenInit: o.vTokenInit,
            graduationQuote: o.graduationQuote,
            tradeFeeBps: o.tradeFeeBps,
            creatorFeeBps: o.creatorFeeBps,
            creatorTaxBps: o.creatorTaxBps,
            snipeMaxBps: o.snipeMaxBps,
            snipeWindow: o.snipeWindow,
            snipeExempt: exempt
        });
    }

    /// The largest liquidity `amount0` and `amount1` can back over `[a, b]`, trimmed until v4's
    /// own deposit arithmetic agrees it fits.
    ///
    /// `LiquidityAmounts.forAmounts` inverts `getAmountXDelta` with the opposite rounding, so it
    /// can answer one unit above what the amounts actually cover. Everywhere else in this system
    /// that is a revert; at graduation it would be a permanent one, because the settlement runs
    /// once and the market is halted until it lands. So the answer is checked against the same
    /// rounding the PoolManager applies and walked down if it has to be, and the cap on the walk
    /// is what makes an unexpected disagreement loud instead of silent.
    ///
    /// It lives here rather than in `LPLocker` because the locker's runtime is what
    /// `LockerDeployer` carries as creation code, and that library is the one against the
    /// EIP-170 limit in this system.
    function fitLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 amount0,
        uint256 amount1,
        int24 tickSpacing
    ) external pure returns (uint128 fitted) {
        fitted = LiquidityAmounts.forAmounts(
            sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1
        );
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing);
        if (fitted > cap) fitted = cap;
        for (uint256 i = 0; i < FIT_STEPS; i++) {
            if (fitted == 0) return 0;
            (uint256 need0, uint256 need1) =
                _amountsFor(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, fitted);
            if (need0 <= amount0 && need1 <= amount1) return fitted;
            fitted -= 1;
        }
        revert LiquidityDoesNotFit();
    }

    /// What a deposit of `liquidity` over `[a, b]` costs at `sqrtPriceX96`, rounded the way v4
    /// rounds a deposit: up, against the depositor.
    function _amountsFor(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 < sqrtUpperX96) {
            uint160 from = sqrtPriceX96 > sqrtLowerX96 ? sqrtPriceX96 : sqrtLowerX96;
            amount0 = SqrtPriceMath.getAmount0Delta(from, sqrtUpperX96, liquidity, true);
        }
        if (sqrtPriceX96 > sqrtLowerX96) {
            uint160 to = sqrtPriceX96 < sqrtUpperX96 ? sqrtPriceX96 : sqrtUpperX96;
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, to, liquidity, true);
        }
    }
}
