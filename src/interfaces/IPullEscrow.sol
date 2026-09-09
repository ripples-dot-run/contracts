// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// One vocabulary for "this contract owes you money you have not taken yet".
///
/// A stock token's issuer can block an address. Under a push payout that turns one blocked
/// recipient into a revert for everybody sharing the transaction: a blocked treasury would
/// revert every buy and every sell on a launch, and a blocked creator would strand the
/// treasury's half of a locker's fee split alongside their own. Pons' lesson, and the reason
/// the money is recorded here and collected separately.
///
/// **Ledgers are per contract, not global.** `LaunchHook` and `LPLocker` each keep their own
/// `owed` / `totalOwed` mapping. There is no shared escrow contract, so a claim names the
/// contract that owes it. `docs/plans/stock-pairing/02-decisions.md` DQ4, as amended.
///
/// Three rules the amendment fixes, and every implementer is held to:
///
/// 1. **What is always credited**: the hook's trade fee and opening tax on every swap, the
///    locker's creator/treasury fee split, and the quote the permanent position could not pair at
///    graduation. **What is pushed**: a swap's own output, which the PoolManager settles to the
///    caller so a revert costs only them, and the locker's seed of the pool. A push that can
///    strand a third party is the thing this interface exists to remove; a push that can only
///    fail the caller's own transaction is not.
/// 2. **Every whole-balance read is `free(token)`**, defined as
///    `IERC20(token).balanceOf(address(this)) - totalOwed(token)`.
///    `LPLocker.settleGraduation` pairs `free(QUOTE)` into the permanent position and burns
///    `free(TOKEN)`, and `sweepToken` moves only `free`. A contract that sweeps its raw balance
///    hands away money it has already promised.
/// 3. **`Collection721` implements this as adapters over its existing share accounting** and
///    gets no second ledger and no push fallback: `attributedReceipts` / `creatorWithdrawn` /
///    `protocolWithdrawn` / `_claimable` already are a pull escrow, and a ledger beside a
///    balance-derived split double-counts and lets `recoverUnattributed` pay the creator the
///    treasury's share. There, `owed(QUOTE, CREATOR())` is `creatorClaimable()`,
///    `owed(QUOTE, treasury())` is `protocolClaimable()`, `totalOwed(QUOTE)` is their sum, and
///    `claim` / `claimFor` call the existing withdraws to their fixed recipients.
///
/// The vocabulary is `Credited` / `Claimed`, `owed`, `totalOwed`, `claim`, `claimFor`. There is
/// no `escrowOf` and no `Escrowed`; earlier drafts of the package list used both and this file
/// is what they are read against.
interface IPullEscrow {
    /// What `account` may still take out of this contract, in `token`'s own units.
    /// A public `mapping(address token => mapping(address account => uint256)) public owed`
    /// satisfies this signature; `Collection721` answers it from its share accounting instead.
    function owed(address token, address account) external view returns (uint256);

    /// The sum of every open `owed` balance in `token`. Subtract it from `balanceOf(this)` to
    /// get the free balance any sweep, seed or solvency check is allowed to touch.
    function totalOwed(address token) external view returns (uint256);

    /// Take the caller's own balance in `token`. Reverts `NothingOwed()` at zero.
    function claim(address token) external returns (uint256 amount);

    /// Take `account`'s balance in `token` and pay it to `account`. **Permissionless**: the
    /// treasury's fees are swept this way by the buyback runbook without the treasury holding a
    /// key that touches a launch, and a creator's claim can be relayed for them. It never pays
    /// anyone but `account`, so the openness costs nothing.
    function claimFor(address token, address account) external returns (uint256 amount);

    /// Money became claimable. Emitted at the moment it is recorded, not when it is taken, so
    /// an indexer can total what a market owes without replaying every trade.
    event Credited(address indexed token, address indexed account, uint256 amount);

    /// Money left. `amount` is what was paid, and after it `owed(token, account)` is zero.
    event Claimed(address indexed token, address indexed account, uint256 amount);

    /// Nothing to take. A blocked recipient is not this error: their balance stays owed and the
    /// call that would have paid them reverts inside the token, which is the hold.
    error NothingOwed();
}
