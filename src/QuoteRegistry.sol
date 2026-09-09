// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IQuoteRegistry } from "./interfaces/IQuoteRegistry.sol";

/// @notice The owner-managed list of assets a launch may settle in, and the economics each one
///         is launched against. One registry serves both factories: `LaunchpadFactory` is under
///         EIP-170 pressure already and duplicating an allowlist into it would buy nothing.
///
///         **Read at create only.** No curve, locker or collection ever reads this again (each
///         captures its quote and that quote's decimals at construction), so revoking an asset
///         closes the door on new launches and cannot reach a market that is already trading.
///         That is the whole safety story: an owner key here can stop the next launch and can
///         never touch a live one.
///
///         This is an **asset list, not a permission list**. It says nothing about who may
///         trade, hold or see a market, on either rail, and no field may be added that does.
///         The issuer's own `paused()` and `isBlocked(address)` are the only controls over a
///         stock token, they belong to the issuer, and they are read off chain.
contract QuoteRegistry is IQuoteRegistry, Ownable2Step {
    /// The asset a launch settles in when it names `address(0)`. Never approved here: the
    /// factories resolve zero to this address before they ask, which is how every caller that
    /// predates the registry stays correct without a change.
    address public immutable defaultQuote;
    /// The asset the launch fee is charged in: WETH, and it stays WETH whatever a launch
    /// settles in (DQ3). A creator launching against a stock token approves two assets.
    address public immutable feeToken;

    mapping(address quote => bool) public approvedQuote;
    mapping(address quote => QuoteEconomics) private _economics;

    /// Append-only, so an index is stable and a revoked quote keeps its place with
    /// `approvedQuote` false. `/proof` renders the whole allowlist from `quoteCount` + `quotes`
    /// with no archive node and no indexer, so the list may never be compacted.
    address[] private _quoteList;
    mapping(address quote => bool) private _listed;

    error ZeroAddress();
    error NotAContract();

    constructor(address defaultQuote_, address feeToken_, address owner_) Ownable(owner_) {
        if (defaultQuote_ == address(0) || feeToken_ == address(0)) revert ZeroAddress();
        if (defaultQuote_.code.length == 0 || feeToken_.code.length == 0) revert NotAContract();
        defaultQuote = defaultQuote_;
        feeToken = feeToken_;
    }

    /// @notice Put an asset on the list, or restate the economics of one already on it.
    ///
    ///         `e.decimals` is checked against the asset's own `decimals()` rather than trusted,
    ///         because every figure in this system is in raw units and there is no normalisation
    ///         anywhere: a 6-decimal asset approved against wei-shaped reserves would launch a
    ///         market whose graduation threshold is a trillion times its intended size. An asset
    ///         that does not answer `decimals()` cannot be approved at all.
    ///
    ///         A row carries an opening reserve for each launch profile and both are required.
    ///         Leaving the standalone reserve out would approve an asset that only linked
    ///         launches could settle in, which reads as an ordinary approval and is not one.
    function approveQuote(address quote, QuoteEconomics calldata e) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        // `address(0)` is the factories' word for "use the default", so approving the default
        // explicitly is allowed and approving zero never is.
        if (quote.code.length == 0) revert NotAContract();
        // The reserves a launch must declare exactly. Zero on any of them would let a launch in
        // this quote declare any curve, which is the check this row exists to make.
        if (e.phantomQuote == 0 || e.graduationThreshold == 0 || e.standalonePhantomQuote == 0) {
            revert QuoteEconomicsMismatch();
        }
        // The standalone profile is the one that opens further below the target, so its reserve
        // is the smaller of the two. The realistic way to get this wrong is to paste the pair the
        // wrong way round, which reads as a legal row and launches every standalone market at the
        // linked shape and every linked market at a shape its own contribution check refuses.
        if (e.standalonePhantomQuote > e.phantomQuote) revert QuoteEconomicsMismatch();
        // A linked launch has to hold enough token to pair its raise whichever way it was funded,
        // and which way costs more depends on where it opens. Below `k = (sqrt(5) - 1) / 2` a
        // trade-funded close needs the most, and the factory's own check reserves for the
        // contribution-funded end, so a row under that ratio admits a market whose graduation
        // credits a double-digit share of its raise to the treasury instead of the position.
        //
        // Enforced here rather than at create because the row is what a launch declares: a shape
        // that cannot pair its own raise should not be approvable in the first place. The
        // boundary is checked as `t * (t + p) >= p * p`, which is `k >= (sqrt(5) - 1) / 2` with no
        // square root: with `t = graduationThreshold` and `p = phantomQuote`, `k = t / p`, and
        // `k >= (sqrt(5) - 1) / 2` rearranges to `k^2 + k >= 1` and then to exactly this. The
        // shipped linked row is k = 0.8 and clears it; the k = 0.5 row that stranded 22.9% of a
        // 4.2 WETH raise does not.
        if (
            uint256(e.graduationThreshold) * (e.graduationThreshold + e.phantomQuote)
                < uint256(e.phantomQuote) * e.phantomQuote
        ) revert QuoteEconomicsMismatch();
        if (e.decimals != _decimalsOf(quote)) revert QuoteDecimalsMismatch();

        _economics[quote] = e;
        approvedQuote[quote] = true;
        if (!_listed[quote]) {
            _listed[quote] = true;
            _quoteList.push(quote);
        }
        emit QuoteApproved(
            quote,
            e.phantomQuote,
            e.graduationThreshold,
            e.decimals,
            e.minPriceQuote,
            e.standalonePhantomQuote
        );
    }

    /// @notice Refused. `Ownable2Step` exists so a handover cannot strand this contract, and a
    ///         renounce is the one door that leaves open: every owner-only setting would be gone
    ///         for good while creating launches kept working, so the break would stay invisible
    ///         until the first treasury rotation.
    function renounceOwnership() public pure override {
        revert();
    }

    /// @notice Take an asset off the list. New launches in it are refused from this block on;
    ///         every market already trading in it is untouched, because nothing downstream reads
    ///         this contract after create. The row and its place in the enumeration stay
    ///         readable so `/proof` can still say what was approved and when.
    function revokeQuote(address quote) external onlyOwner {
        if (!approvedQuote[quote]) revert QuoteNotApproved();
        // The default quote cannot be revoked. Everywhere else revoking means "no new launches in
        // this asset", but the factories read an unapproved default as "this deployment has no row
        // for its default", which is the one configuration where a launch still declares its own
        // curve. Revoking it would therefore do the opposite of what it says: not close the asset
        // every launch settles in, but unbind it. Retiring a default is a redeploy.
        if (quote == defaultQuote) revert QuoteNotApproved();
        approvedQuote[quote] = false;
        emit QuoteRevoked(quote);
    }

    /// The row `quote` was approved with, in the quote's own decimals.
    ///
    /// Deliberately an explicit function and not a public mapping: Solidity's generated getter
    /// for a struct-valued mapping flattens the members into four separate return values, which
    /// does not implement `IQuoteRegistry` and decodes as an array rather than an object in
    /// every off-chain reader. `contracts/test/Interfaces.t.sol` proves the point with a stub.
    function quoteEconomics(address quote) external view returns (QuoteEconomics memory) {
        return _economics[quote];
    }

    function quoteCount() external view returns (uint256) {
        return _quoteList.length;
    }

    function quotes(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = _quoteList.length;
        if (offset >= total) return new address[](0);
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _quoteList[i];
        }
    }

    /// The asset's own decimals. A token that does not answer is not a quote this system can
    /// settle in, and saying so as `QuoteDecimalsMismatch` names the reason.
    function _decimalsOf(address quote) private view returns (uint8) {
        try IERC20Metadata(quote).decimals() returns (uint8 d) {
            return d;
        } catch {
            revert QuoteDecimalsMismatch();
        }
    }
}
