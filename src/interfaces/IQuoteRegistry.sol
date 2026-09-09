// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The owner-managed list of assets a launch may settle in, and the economics each one is
/// launched against. Read at **create only** (never on a trading path, never by a curve, a
/// locker or a collection after deployment), so revoking a quote can never reach a market that
/// is already live. `docs/plans/stock-pairing/02-decisions.md` DQ1, as amended by the skeptic
/// panel.
///
/// Every figure is in the quote's **own decimals** (DQ5): there is no on-chain normalisation
/// anywhere in this system, and `decimals` is the anchor that makes a bare integer mean
/// something. `approveQuote` is expected to reject a row whose `decimals` differs from the
/// asset's own `IERC20Metadata.decimals()`, which is what stops a 6-decimal quote being
/// launched against wei-shaped reserves.
///
/// The registry is an **asset list**, not a permission list. It says nothing about who may
/// trade, hold, or see a market, and it must never grow a field that does: no eligibility, no
/// jurisdiction, no holder check, on either rail.
interface IQuoteRegistry {
    /// The economics one approved quote is launched against.
    ///
    /// - `phantomQuote`: the exact `vQuoteInit` a **linked** launch in this quote must declare.
    /// - `graduationThreshold`: the exact `graduationQuote` a launch in this quote must declare,
    ///   under either profile. A launch in this asset graduates at one raise whatever shape it
    ///   opened in.
    /// - `decimals`: the asset's own decimals, recorded at approval so it cannot drift.
    /// - `minPriceQuote`: the **floor** a collection's `priceQuote` must reach in this quote. It
    ///   binds wherever a collection is deployed: the linked half of a token launch, and every
    ///   drop the NFT rail creates on its own. A standalone token launch deploys none, so it is
    ///   the one thing here that never reaches it.
    /// - `standalonePhantomQuote`: the exact `vQuoteInit` a **standalone** launch in this quote
    ///   must declare. At or below `phantomQuote`, because that is the direction the standalone
    ///   profile exists in: it opens further below the target and so at a larger multiple.
    ///
    /// The reserves are exact equalities and the price is a floor. That split is the DQ1
    /// amendment: a mint price is a creator's choice within a band, while the reserves fix
    /// the shape of the curve and a mismatch there is a mispriced market, not a preference.
    ///
    /// **One opening reserve per launch profile, because one reserve cannot serve both.** A
    /// launch that can be funded by an NFT collection's routed mint revenue has to hold enough
    /// token to pair a raise that never moved the price. Taken with the factory's seed price
    /// band, which pins the LP reserve to the pool seed and leaves it no slack, that puts a hard
    /// ceiling near five times on how far a linked launch may open below its target. A
    /// standalone launch takes no contributions and carries no such ceiling; it is held instead
    /// to what selling its curve out and pairing the raise at the price that produces costs
    /// together, which no multiple breaks. The two therefore open at different prices against
    /// the same target, and the row states both rather than leaving a caller to pick.
    /// `docs/plans/2026-09-07-launch-shape.md` derives the ceiling.
    ///
    /// `phantomQuote` keeps the meaning it was written with and the standalone reserve is
    /// appended, so every row already on chain and every `QuoteApproved` already in a log still
    /// reads correctly. Reversing the two would silently restate history.
    struct QuoteEconomics {
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint8 decimals;
        uint256 minPriceQuote;
        uint256 standalonePhantomQuote;
    }

    /// Whether new launches may settle in `quote`. `address(0)` is not approved here: the
    /// factories read it as "use `defaultQuote()`" before they ever ask.
    function approvedQuote(address quote) external view returns (bool);

    /// The row `quote` was approved with.
    ///
    /// This is deliberately an explicit function and **not** a public mapping: Solidity's
    /// generated getter for a struct-valued mapping flattens the members into four separate
    /// return values, which does not implement this signature and decodes to an array rather
    /// than an object in every off-chain reader. An implementation that ships the public
    /// mapping instead breaks this interface and `apps/web/lib/evm/abi.ts` in the same move.
    function quoteEconomics(address quote) external view returns (QuoteEconomics memory);

    /// How many quotes have ever been approved. Enumeration is append-only, so an index is
    /// stable and a revoked quote keeps its place with `approvedQuote` false.
    function quoteCount() external view returns (uint256);

    /// One page of the approval list, in approval order. `/proof` renders the whole list from
    /// this, so the page must be readable without an archive node or an indexer.
    function quotes(uint256 offset, uint256 limit) external view returns (address[] memory page);

    /// The asset a launch settles in when it names `address(0)`: WETH on both Robinhood Chain
    /// networks today. Keeps every caller that predates the registry correct without a change.
    function defaultQuote() external view returns (address);

    /// The asset the launch **fee** is charged in, which is WETH and stays WETH whatever a
    /// launch settles in (DQ3). A creator launching against a stock token approves two assets.
    function feeToken() external view returns (address);

    /// The second generation of this event, and the first that carries an opening reserve per
    /// launch profile. The first generation is still live on testnet under topic
    /// `0xdb853f07…52f822`, so a scanner that reads the allowlist's history needs both;
    /// `contracts/test/Interfaces.t.sol` pins them side by side and that freeze is append only.
    event QuoteApproved(
        address indexed quote,
        uint256 phantomQuote,
        uint256 graduationThreshold,
        uint8 decimals,
        uint256 minPriceQuote,
        uint256 standalonePhantomQuote
    );

    event QuoteRevoked(address indexed quote);

    /// The named quote is not on the list. Raised at create, never at trade.
    error QuoteNotApproved();
    /// `vQuoteInit` or `graduationQuote` does not equal the approved row, or a row was offered
    /// for approval whose reserves cannot be one asset's economics. Reserved for the reserves;
    /// a price below `minPriceQuote` is `PriceOutOfRange`, not this.
    error QuoteEconomicsMismatch();
    /// The row's `decimals` does not match the asset's own `decimals()`.
    error QuoteDecimalsMismatch();
}
