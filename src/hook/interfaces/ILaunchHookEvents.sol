// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PoolId } from "v4-core/src/types/PoolId.sol";

/// Every event `LaunchHook` emits, with its canonical signature and `topic0`. Split out from
/// `ILaunchHook` because three other packages key on these and nothing else: the indexer's EVM
/// source, the keeper, and the adapter's reserve reconciliation. An event here is a wire format,
/// so this file is **append only**: a new field is a new event, never an edit to one below.
///
/// A launch's own market data is the PoolManager's, not ours. `Initialize`
/// (`0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438`) and `Swap`
/// (`0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f`) on
/// `0x8366a39CC670B4001A1121B8F6A443A643e40951` are where price and volume come from, on 4663 and
/// on its testnet alike. The events below are what the PoolManager cannot tell you: which pool is a
/// Ripples launch, what the hook took out of a swap and in which currency, and where the launch is
/// in its life. An indexer that reads `Swap` alone will overstate what a trader received by exactly
/// the fee this hook charged, which is why `TradeFeeCharged` and `SnipeTaxCharged` carry the amount
/// and the currency rather than a rate.
interface ILaunchHookEvents {
    /// A pool id became a Ripples launch. Emitted by `register`, before the pool exists: the id is
    /// derived from the key, so it is knowable and claimable one call ahead of `Initialize`.
    ///
    /// Topic0 for this and every other event here is pinned in
    /// `contracts/test/hook/LaunchHookEvents.t.sol`, which holds the signature string and the
    /// 32-byte hash side by side and asserts the hash the compiler emits equals the hash of the
    /// string. An indexer copies the numbers from that file; nothing is written by hand twice.
    event LaunchRegistered(
        PoolId indexed poolId,
        address indexed token,
        address indexed quote,
        address locker,
        address creator,
        uint256 graduationQuote,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// The launch's own liquidity is in the pool and trading is open. Emitted from
    /// `beforeAddLiquidity`, so it lands in the launch transaction immediately before the
    /// PoolManager's own `ModifyLiquidity`.
    event LaunchSeeded(PoolId indexed poolId, uint128 liquidity, int24 tickLower, int24 tickUpper);

    /// The hook took `amount` of `currency` out of a swap as the launch's trade fee and credited
    /// it to `recipient`'s escrow balance. `currency` is the swap's **unspecified** side, so an
    /// exact-input buy pays its fee in the launch token and a sell pays it in the quote. Nothing
    /// moved: the amount is an ERC-6909 claim held by the hook until `recipient` claims it.
    event TradeFeeCharged(
        PoolId indexed poolId, address indexed currency, address indexed recipient, uint256 amount
    );

    /// The launch's own creator tax, taken out of the same side of the same swap the trade fee is
    /// taken out of and credited to the creator in full. It is a separate topic from
    /// `TradeFeeCharged` because it is a separate charge: the trade fee is split with the
    /// treasury and this is not, and a trader pays both. An indexer that reconstructs a fill from
    /// the PoolManager's `Swap` needs this one as well, or it overstates what the trader received
    /// by exactly the tax on any launch that sets one.
    event CreatorTaxCharged(
        PoolId indexed poolId, address indexed currency, address indexed recipient, uint256 amount
    );

    /// The opening tax on a buy inside the snipe window, at `bps` of the swap's unspecified side.
    /// A tax that lands in the launch token is credited to the burn sink and leaves circulation;
    /// one that lands in the quote is credited to the treasury. `recipient` says which happened.
    event SnipeTaxCharged(
        PoolId indexed poolId,
        address indexed currency,
        address indexed recipient,
        uint256 amount,
        uint256 bps
    );

    /// The raise cleared the launch's target. No pool is created, the pool id does not change and
    /// the fee split does not move: the locker is admitted, once, to retire the curve position and
    /// open the permanent one. Swaps are refused from here until that settlement lands, so
    /// `realQuote` is final.
    event Graduated(PoolId indexed poolId, uint256 realQuote, uint256 graduationQuote);

    /// The curve position left the pool and this is the quote it carried, measured off the
    /// position at the moment of the removal rather than off the reading `graduate` took. It is
    /// the figure `realQuote` answers with for the rest of the launch's life, and the amount the
    /// locker has in hand to open the permanent position with.
    event GraduationRaiseSettled(PoolId indexed poolId, uint256 raisedQuote);

    /// The permanent position is in place and the launch's liquidity is closed for good: no
    /// address, including the locker, may add or remove liquidity in this pool again before the
    /// locker's own unlock time, which is `type(uint64).max` for a permanent lock.
    event GraduationSettled(PoolId indexed poolId, uint128 liquidity);

    /// Quote a linked collection routed into the raise without taking any launch token. It counts
    /// toward the target and never moves the pool price, exactly as it did on the curve rail.
    event ContributionRecorded(
        PoolId indexed poolId, address indexed from, uint256 amount, uint256 contributedQuote
    );

    /// A launch's creator income was pointed at a different address, by the address that was
    /// receiving it. Everything owed to `previous` at that moment stays claimable by `previous`;
    /// only what the launch earns after this event goes to `recipient`.
    event CreatorFeeRecipientSet(
        PoolId indexed poolId, address indexed previous, address indexed recipient
    );

    /// A launchpad was allowed to register launches, or stopped from doing so. The hook is mined
    /// once and outlives every factory that uses it, so this is how a factory redeploy reaches it.
    event LaunchpadSet(address indexed launchpad, bool allowed);
}
