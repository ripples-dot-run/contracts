// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Collection721, CollectionParams } from "./Collection721.sol";
import { LPLocker } from "./LPLocker.sol";
import { ScoutRegistry } from "./ScoutRegistry.sol";
import {
    DevBuyParams,
    LaunchParams,
    LinkedParams,
    TokenLaunchFactory
} from "./TokenLaunchFactory.sol";
import { IPullEscrow } from "./interfaces/IPullEscrow.sol";

/// The one call this contract makes back into the factory that deployed it, declared here rather
/// than imported so the two files do not import each other.
interface ILaunchRecorder {
    function recordLaunch(address token, address collection) external;
}

/// @title WorkSplit
/// @notice The creator of record for one launch, and the contract that divides what that launch
///         earns between the artist and the scouts who brought the buyers.
///
/// A Ripples linked launch pays its creator in three places: the hook's escrow holds its share
/// of every trade fee, the collection holds the part of each mint not routed into the raise, and
/// the locker divides any pool fee it collects. All three key on the address that called
/// `TokenLaunchFactory.createLinkedLaunch`, so this contract makes that call and is that address.
///
/// **The split is published before anyone mints and cannot be changed afterwards.** The artist,
/// the rate and the standing trade scout are immutable, and there is no owner, no pause and no
/// sweep: nothing leaves here except through `claim` and `claimFor`, which pay the named account.
///
/// **A mint commission is paid per mint, to the scout that buyer named, and only on the pieces
/// they minted after naming them.** Nobody's first click collects on everybody's later mints.
///
/// **A trade commission is a standing arrangement or nothing at all.** `TRADE_SCOUT` is the one
/// address the artist named at launch, and zero means the artist keeps the whole fee stream. It
/// comes out of the balance rather than out of what a sync claimed, because `LaunchHook.claimFor`
/// is permissionless and a stranger may move this launch's escrow in here unannounced.
///
/// Both currencies, since the hook charges on the unspecified side of a swap. An asset that is
/// neither stays here, as does ownership of the collection, which no call here transfers.
contract WorkSplit is ReentrancyGuard, IPullEscrow {
    using SafeERC20 for IERC20;

    uint96 public constant BPS_DENOMINATOR = 10_000;
    /// The band the artist picks their rate from. A commission that can be set to nothing is not
    /// a job anyone will take, and the ceiling keeps the artist the larger side of their own
    /// launch.
    uint96 public constant MIN_COMMISSION_BPS = 1_000;
    uint96 public constant MAX_COMMISSION_BPS = 3_000;

    /// Receives every share the commission does not take, in both currencies, plus anything that
    /// arrives here without a commission attached to it.
    address public immutable ARTIST;
    /// The `WorkSplitFactory` that deployed this split. A second caller for `launch`, so the
    /// factory can deploy, fund and open a launch in one transaction rather than leave a split
    /// holding an artist's money with no launch.
    address public immutable SPLIT_FACTORY;
    TokenLaunchFactory public immutable FACTORY;
    /// The launch factory's fee token, which is also what a Robinhood Chain launch settles in,
    /// which is why one approval in `launch` covers both the fee and the opening buy.
    IERC20 public immutable QUOTE;
    /// Where a buyer's scout binding is read from. One registry per factory, deployed by it.
    ScoutRegistry public immutable SCOUT_REGISTRY;
    /// The published rate, in basis points of what this launch earns.
    uint96 public immutable COMMISSION_BPS;
    /// The standing scout for trade fees, or zero for a launch whose whole fee stream is the
    /// artist's. Not attributed to anybody's link, so it is one address the artist chose at
    /// launch or it is nobody.
    address public immutable TRADE_SCOUT;

    address public token;
    address public locker;
    address public collection;
    address public vesting;

    /// What one piece is worth to a scout, in the quote's own units, fixed at launch. See
    /// `_commissionFloor` for why it is a floor.
    uint256 public commissionPerMint;

    /// Quote and tokens this contract holds that the market did not earn, which are the artist's
    /// and nobody else's. Measured on the way out of `launch`, the last moment the runway the
    /// launch did not spend and the tokens its opening buy came back with can be told apart from
    /// a fee. `recoverUnattributed` is the one later arrival that can, and it adds to the quote
    /// side.
    uint256 public unspentRunway;
    uint256 public openingBuyTokens;

    /// Mint revenue this contract has already divided, held against `creatorWithdrawn` on the
    /// collection, which is the one number that says how much of it has arrived here whoever
    /// pushed it. The two together tell the mint side's money from the trade side's without
    /// asking who called.
    uint256 public dividedMintRevenue;

    /// Pieces this contract has already settled a commission decision for, per buyer and in
    /// total. The total keeps a scout's money from being released to the artist before the buyer
    /// it belongs to has been settled.
    mapping(address buyer => uint256) public settledMintsOf;
    uint256 public settledMints;

    /// The ledger. Keyed by asset because a launch earns in two, and by account because an
    /// arbitrary number of scouts are owed alongside the artist and none of them may be able to
    /// block another.
    mapping(address token => mapping(address account => uint256 amount)) public owed;
    mapping(address token => uint256 amount) public totalOwed;

    event Launched(
        address indexed token, address indexed locker, address collection, address vesting
    );
    /// What the hook and the locker paid this contract on one sync, before the division. The
    /// division itself is on the `Credited` log, per account.
    event TradeFeesSynced(uint256 quoteAmount, uint256 tokenAmount);
    /// One buyer's mints settled. `commission` is zero for a buyer who arrived on their own, and
    /// for the pieces they minted before binding anyone.
    event MintsSettled(
        address indexed buyer, address indexed scout, uint256 mints, uint256 commission
    );

    error ZeroAddress();
    error NotAContract();
    error NotArtist();
    error AlreadyLaunched();
    error NotLaunched();
    error CommissionOutOfBand();
    /// The artist named themselves as the standing trade scout, which would publish a commission
    /// that changes nothing and misstate on the page what the artist keeps, or they named this
    /// contract, whose ledger can record a commission it has no way to ever pay out.
    error InvalidScout();
    /// A per-piece commission that rounds to nothing: at a low enough mint price, or with the
    /// whole mint routed into the curve, the launch would publish a rate that never pays a scout
    /// a unit. Refused while the launch transaction can still be abandoned.
    error CommissionTooSmall();
    /// The market that opened settles in something other than `QUOTE`. Every amount here is in
    /// that one asset, and a launch in another would earn a stream this contract cannot divide.
    error QuoteMismatch();
    /// An asset moved by an amount other than the one reported, or a child escrow failed for a
    /// reason that was not "nothing owed".
    error UnexpectedBalance();
    /// The artist's own address refused the ether royalty and gave no reason for it, which an
    /// artist holding their launch in a Safe is the ordinary way to reach. Named apart from
    /// `UnexpectedBalance` so the diagnosis starts at the account rather than at the asset.
    error EtherPayoutFailed();

    constructor(
        address artist,
        address factory,
        address scoutRegistry,
        uint96 commissionBps,
        address tradeScout
    ) {
        if (artist == address(0) || factory == address(0) || scoutRegistry == address(0)) {
            revert ZeroAddress();
        }
        if (factory.code.length == 0 || scoutRegistry.code.length == 0) revert NotAContract();
        if (commissionBps < MIN_COMMISSION_BPS || commissionBps > MAX_COMMISSION_BPS) {
            revert CommissionOutOfBand();
        }
        if (tradeScout == artist || tradeScout == address(this)) revert InvalidScout();

        ARTIST = artist;
        SPLIT_FACTORY = msg.sender;
        FACTORY = TokenLaunchFactory(factory);
        QUOTE = TokenLaunchFactory(factory).FEE_TOKEN();
        SCOUT_REGISTRY = ScoutRegistry(scoutRegistry);
        COMMISSION_BPS = commissionBps;
        TRADE_SCOUT = tradeScout;
    }

    /// @notice Open the artist's launch. This contract pays the fee out of its own balance and
    ///         is recorded as the launch's creator, so the creator's share of every trade fee
    ///         and of every mint credits here from the first one.
    /// @dev Once, by the artist or by the factory that deployed this split. A second launch
    ///      would give one published commission two markets, and the mint accounting names one
    ///      collection.
    function launch(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d
    ) external nonReentrant returns (address, address, address, address) {
        if (msg.sender != ARTIST && msg.sender != SPLIT_FACTORY) revert NotArtist();
        if (token != address(0)) revert AlreadyLaunched();

        // The approval covers exactly what the fee and the opening buy can take and is cleared
        // straight after, so nothing is left standing for a later fee change to reach.
        uint256 allowance = FACTORY.launchFee() + d.initialBuy;
        QUOTE.forceApprove(address(FACTORY), allowance);
        (address t, address l, address c, address v) = FACTORY.createLinkedLaunch(tp, np, lp, d);
        QUOTE.forceApprove(address(FACTORY), 0);

        // Asked of the market that opened rather than of the argument that asked for it: an
        // empty `tp.quote` means the launch factory's current default, and that is a registry
        // setting rather than a promise.
        if (LPLocker(l).QUOTE() != address(QUOTE)) revert QuoteMismatch();

        token = t;
        locker = l;
        collection = c;
        vesting = v;

        // Safe to read now and never again. `TokenLaunchFactory` wires the collection to the
        // curve inside the call that just returned, and `linkToCurve` is one-shot, so every term
        // of the per-piece commission is final at this point.
        uint256 perMint = _commissionFloor(c);
        if (perMint == 0) revert CommissionTooSmall();
        commissionPerMint = perMint;

        unspentRunway = QUOTE.balanceOf(address(this));
        openingBuyTokens = IERC20(t).balanceOf(address(this));

        // The record that lets a page holding a token or a collection address find this split,
        // and the commission, in one read.
        ILaunchRecorder(SPLIT_FACTORY).recordLaunch(t, c);
        emit Launched(t, l, c, v);
        return (t, l, c, v);
    }

    /// @notice Pull in the trade fees this launch has earned. Permissionless, because the money
    ///         has two destinations and this call chooses neither: the rate is immutable and so
    ///         is the scout it pays.
    /// @dev Both escrows and both currencies. The hook holds the creator's share of every trade
    ///      for the life of the launch. The locker normally holds nothing, since a Ripples pool
    ///      charges no fee of its own, and is asked anyway because a pool that ever earned one
    ///      would otherwise have no way to divide it. Neither is required to answer.
    ///
    ///      What this call claims is what it reports, and nothing more. The division belongs to
    ///      `_release` and reads the balance rather than these two amounts.
    function syncTradeFees()
        external
        nonReentrant
        returns (uint256 quoteAmount, uint256 tokenAmount)
    {
        address l = locker;
        if (l == address(0)) revert NotLaunched();
        address t = token;
        address hook = LPLocker(l).HOOK();

        quoteAmount = _claim(hook, address(QUOTE)) + _claim(l, address(QUOTE));
        tokenAmount = _claim(hook, t) + _claim(l, t);

        _release();
        emit TradeFeesSynced(quoteAmount, tokenAmount);
    }

    /// @notice Settle one buyer's mints: pay their scout the published commission on the pieces
    ///         they minted after binding them, and release the rest to the artist.
    /// @dev Permissionless, and that is what makes the reserve below safe to hold: anybody can
    ///      settle anybody, so a buyer who never comes back cannot hold the artist's money. The
    ///      harvest runs first, and `Collection721` clamps a creator withdrawal to its own live
    ///      balance, so a call that came up short closes only the pieces it could pay for.
    function settleMints(address buyer) external nonReentrant returns (uint256 commission) {
        address c = collection;
        if (c == address(0)) revert NotLaunched();
        _claim(c, address(QUOTE));

        uint256 minted = Collection721(c).mintedBy(buyer);
        uint256 settled = settledMintsOf[buyer];
        if (minted <= settled) revert NothingOwed();

        (address scout, uint256 mintsAtBinding) = SCOUT_REGISTRY.bindingOf(address(this), buyer);

        // Every piece, unless a commission below cannot be funded.
        uint256 settledTo = minted;

        if (scout != address(0)) {
            // Paid from the later of the two marks: what has already been settled, and what the
            // buyer had minted when they bound this scout. A buyer who minted the drop and then
            // named a scout owes them nothing for the pieces that came first.
            uint256 from = settled > mintsAtBinding ? settled : mintsAtBinding;
            if (minted > from) {
                uint256 due = (minted - from) * commissionPerMint;
                uint256 available = free(address(QUOTE));
                // Whole pieces only, and the counter advances by exactly the pieces that were
                // paid for. Closing the rest would release their money to the artist on the next
                // call and leave the scout short for the life of the launch, since `settleMints`
                // answers `NothingOwed` once a piece is settled. Left open, they stay settleable
                // and their commission stays reserved until the balance is there to pay it.
                commission =
                    due <= available ? due : (available / commissionPerMint) * commissionPerMint;
                settledTo = from + commission / commissionPerMint;
                _credit(address(QUOTE), scout, commission);
                // Booked against what the collection has paid, so the release below knows this
                // much of the pot was a mint's and not a trade's.
                _takeMintRevenue(commission);
            }
        }

        uint256 newMints = settledTo - settled;
        if (newMints != 0) {
            settledMintsOf[buyer] = settledTo;
            settledMints += newMints;
        }

        _release();
        emit MintsSettled(buyer, scout, newMints, commission);
    }

    /// @notice Credit the artist everything this contract holds that is not owed to somebody
    ///         and not reserved against mints nobody has settled yet. Permissionless.
    /// @dev The residue is real money and it has no other door: the tokens an opening buy left,
    ///      the runway put in beyond the launch fee, and whatever `recoverUnattributed` pushed
    ///      back off the collection. `_release` divides it and reaches all of it by measuring the
    ///      balance rather than by counting receipts.
    function settleArtist()
        external
        nonReentrant
        returns (uint256 quoteAmount, uint256 tokenAmount)
    {
        return _release();
    }

    /// @notice Move quote that reached the collection outside a mint on to this contract, where
    ///         it becomes part of the artist's residue.
    /// @dev The collection pays its immutable creator, which is this contract, so this call adds
    ///      no permission and cannot redirect anything. It ends by releasing what it recovered,
    ///      so the money does not sit here waiting for a mint that may never come.
    function recoverUnattributed() external nonReentrant returns (uint256 amount) {
        address c = collection;
        if (c == address(0)) revert NotLaunched();
        uint256 before = QUOTE.balanceOf(address(this));
        amount = Collection721(c).recoverUnattributed();
        if (QUOTE.balanceOf(address(this)) - before != amount) revert UnexpectedBalance();
        // Booked as the artist's before it is divided. `Collection721.recoverUnattributed` is a
        // plain transfer to its creator that moves no mint counter, so without this line the
        // release below would find quote it cannot tell from a trade fee and hand a standing
        // scout the published share of a payment no trade produced.
        unspentRunway += amount;
        _release();
    }

    /// @notice Take the runway back out of a split whose launch never happened. The artist, and
    ///         only while there is no launch.
    /// @dev The two-transaction shape is a published one: an artist may deploy a split, fund it,
    ///      and open the launch later. A launch fee that went up in between, or a drop the artist
    ///      decided against, leaves the contract holding money with nothing to spend it on.
    ///      Before the launch exists nobody but the artist can be owed a unit of it, since every
    ///      path into `_credit` either reverts `NotLaunched` or returns at the first line of
    ///      `_release`. It closes the moment the launch opens.
    function withdrawRunway() external nonReentrant returns (uint256 amount) {
        if (msg.sender != ARTIST) revert NotArtist();
        if (token != address(0)) revert AlreadyLaunched();
        amount = QUOTE.balanceOf(address(this));
        if (amount == 0) revert NothingOwed();
        _transferExact(QUOTE, ARTIST, amount);
        emit Claimed(address(QUOTE), ARTIST, amount);
    }

    /// Native ether reaches this contract one way: a marketplace settling the collection's
    /// ERC-2981 royalty on a resale priced in the chain's own asset. `Collection721` names this
    /// address as the receiver in its constructor and has no setter, so refusing the transfer
    /// would not redirect the royalty, it would make the collector's listing unfillable.
    receive() external payable { }

    /// @notice Pay the artist the ether this contract has been sent. Permissionless, because the
    ///         recipient is fixed.
    /// @dev Outside the ledger and outside the commission, both on purpose: the hook settles its
    ///      fee in an ERC-20, so nothing that arrives here in ether was this market's trade
    ///      income. `address(0)` names the asset on the log.
    function claimEther() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingOwed();
        (bool ok, bytes memory reason) = ARTIST.call{ value: amount }("");
        // Passed back the way the artist's own account raised it, since this is the one failure
        // here whose cause lives somewhere else. A silent refusal gets the named error instead.
        if (!ok) {
            if (reason.length == 0) revert EtherPayoutFailed();
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        emit Claimed(address(0), ARTIST, amount);
    }

    /// @inheritdoc IPullEscrow
    function claim(address asset) external nonReentrant returns (uint256 amount) {
        return _payOut(asset, msg.sender);
    }

    /// @inheritdoc IPullEscrow
    /// @dev Permissionless and still safe, because it pays `account` and nothing else, so a page
    ///      can settle and pay a whole launch's scouts in one transaction.
    function claimFor(address asset, address account) external nonReentrant returns (uint256) {
        return _payOut(asset, account);
    }

    /// @notice The balance in `asset` that is not already promised to somebody, which is the
    ///         only whole-balance read `IPullEscrow` lets an implementer act on.
    function free(address asset) public view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 promised = totalOwed[asset];
        return balance > promised ? balance - promised : 0;
    }

    /// @notice Quote held back from the artist against mints that have not been settled yet.
    /// @dev The collection pays its creator in one lump for every mint it has taken, so a settle
    ///      harvests the pot for buyers who have not been settled too. Without this the first
    ///      buyer settled would hand the artist every other buyer's commission. Anyone can settle
    ///      anyone at any time, so it is a delay rather than a lock.
    function mintReserve() public view returns (uint256) {
        address c = collection;
        if (c == address(0)) return 0;
        uint256 minted = Collection721(c).totalSupply();
        uint256 settled = settledMints;
        if (minted <= settled) return 0;
        return (minted - settled) * commissionPerMint;
    }

    /// @notice The published split, for a page that wants it in one call.
    function terms()
        external
        view
        returns (
            address artist,
            uint96 commissionBps,
            address tradeScout,
            uint256 perMint,
            address scoutRegistry
        )
    {
        return (ARTIST, COMMISSION_BPS, TRADE_SCOUT, commissionPerMint, address(SCOUT_REGISTRY));
    }

    /// @notice The collection's metadata calls, whose owner is this contract rather than the
    ///         artist who created it.
    /// @dev Ripples attaches a collection's artwork after it exists and points it there with
    ///      `setBaseURI`, so without these the one shape whose pictures can never be attached
    ///      would be the shape that pays a commission. They move no money and reach nothing but
    ///      this launch's own collection. `setTokenURI` is not forwarded: `Collection721` reveals
    ///      only a piece the owner is holding, and this contract holds none.
    function setCollectionBaseURI(string calldata uri) external {
        _onlyArtist();
        Collection721(collection).setBaseURI(uri);
    }

    function setCollectionPlaceholderURI(string calldata uri) external {
        _onlyArtist();
        Collection721(collection).setPlaceholderURI(uri);
    }

    /// @dev Outside `freezeMetadata`, as on the collection itself.
    function setCollectionContractURI(string calldata uri) external {
        _onlyArtist();
        Collection721(collection).setContractURI(uri);
    }

    function freezeCollectionMetadata() external {
        _onlyArtist();
        Collection721(collection).freezeMetadata();
    }

    function _onlyArtist() private view {
        if (msg.sender != ARTIST) revert NotArtist();
        if (collection == address(0)) revert NotLaunched();
    }

    /// What one piece is worth to a scout, computed from the three terms the collection fixes at
    /// launch: the price, the protocol's share of it, and the share a linked launch routes into
    /// the raise.
    ///
    /// Every rounding here is downwards and every rounding on the collection's side is against
    /// the protocol and the curve rather than against the creator, so this is a **floor on what
    /// one mint credits this contract, never a ceiling on it**. Late in a raise the routed share
    /// is capped by what the curve still needs, and after graduation nothing routes at all, so
    /// those mints earn more than this assumes. The surplus is the artist's, and a scout is
    /// never paid a unit the collection did not pay first.
    function _commissionFloor(address c) private view returns (uint256) {
        uint256 price = Collection721(c).PRICE_QUOTE();
        uint256 net = Math.mulDiv(
            price, BPS_DENOMINATOR - Collection721(c).PROTOCOL_FEE_BPS(), BPS_DENOMINATOR
        );
        net = Math.mulDiv(net, BPS_DENOMINATOR - Collection721(c).mintToCurveBps(), BPS_DENOMINATOR);
        return _commission(net);
    }

    function _commission(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, COMMISSION_BPS, BPS_DENOMINATOR);
    }

    /// Everything not owed to somebody and not reserved against an unsettled mint is divided
    /// here, off the balance rather than off a pot of this contract's own harvests.
    /// `LaunchHook.claimFor` and `LPLocker.claimFor` both pay the account they name and neither
    /// asks permission, so a stranger can empty this launch's fee escrow in this direction at any
    /// moment, and a division counting only its own syncs would hand all of that to the artist.
    ///
    /// What the market did not earn comes out before the rate is applied: the launch's own
    /// leavings, and mint revenue, which the mint commission is already paid out of. Everything
    /// else is trade income and the standing scout takes the published share. That is a wider net
    /// than the fee stream alone, deliberately, since a secondary royalty paid in the quote looks
    /// exactly like a trade fee somebody pushed in.
    function _release() private returns (uint256 quoteAmount, uint256 tokenAmount) {
        address t = token;
        if (t == address(0)) return (0, 0);

        uint256 quoteFree = free(address(QUOTE));
        uint256 reserve = mintReserve();
        if (quoteFree > reserve) {
            quoteAmount = quoteFree - reserve;
            uint256 runway = unspentRunway;
            uint256 artistOnly = runway < quoteAmount ? runway : quoteAmount;
            unspentRunway = runway - artistOnly;
            artistOnly += _takeMintRevenue(quoteAmount - artistOnly);
            _divide(address(QUOTE), quoteAmount, artistOnly);
        }
        // The launch token is deployed by the launch factory and can never be the quote, so the
        // reserve above survives this branch. Nothing is reserved here: mint commissions are
        // quote-denominated, and what the market did not earn on this side is the opening buy.
        if (t != address(QUOTE)) {
            tokenAmount = free(t);
            if (tokenAmount != 0) {
                uint256 bought = openingBuyTokens;
                uint256 artistOnly = bought < tokenAmount ? bought : tokenAmount;
                openingBuyTokens = bought - artistOnly;
                _divide(t, tokenAmount, artistOnly);
            }
        }
    }

    /// One amount, two accounts, and the only place the trade commission is ever applied.
    /// `artistOnly` is the part of it the published rate was never set against.
    function _divide(address asset, uint256 amount, uint256 artistOnly) private {
        uint256 commission = TRADE_SCOUT == address(0) ? 0 : _commission(amount - artistOnly);
        _credit(asset, TRADE_SCOUT, commission);
        _credit(asset, ARTIST, amount - commission);
    }

    /// How much of `amount` the collection has paid this contract for mints and nobody has
    /// accounted for yet. `creatorWithdrawn` counts a stranger's `creatorWithdraw` exactly as it
    /// counts this contract's own harvest, so the door a caller chooses cannot change the
    /// division.
    function _takeMintRevenue(uint256 amount) private returns (uint256 taken) {
        uint256 unaccounted = Collection721(collection).creatorWithdrawn() - dividedMintRevenue;
        taken = amount < unaccounted ? amount : unaccounted;
        dividedMintRevenue += taken;
    }

    function _credit(address asset, address account, uint256 amount) private {
        if (amount == 0) return;
        owed[asset][account] += amount;
        totalOwed[asset] += amount;
        emit Credited(asset, account, amount);
    }

    function _payOut(address asset, address account) private returns (uint256 amount) {
        amount = owed[asset][account];
        if (amount == 0) revert NothingOwed();
        owed[asset][account] = 0;
        totalOwed[asset] -= amount;
        _transferExact(IERC20(asset), account, amount);
        emit Claimed(asset, account, amount);
    }

    /// Copied from `AgentTreasury`, including which revert it is willing to swallow. An escrow
    /// holding nothing in this asset says so by reverting, and a caller syncing a launch should
    /// not have to know which of the two escrows that is. Only that one answer is quiet: anything
    /// else, including a child call that ran out of gas, is a claim that did not happen.
    function _claim(address escrow, address asset) private returns (uint256 amount) {
        uint256 before = IERC20(asset).balanceOf(address(this));
        try IPullEscrow(escrow).claim(asset) returns (uint256 claimed) {
            amount = claimed;
        } catch (bytes memory reason) {
            if (bytes4(reason) != IPullEscrow.NothingOwed.selector) revert UnexpectedBalance();
            return 0;
        }
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert UnexpectedBalance();
    }

    function _transferExact(IERC20 asset, address to, uint256 amount) private {
        uint256 senderBefore = asset.balanceOf(address(this));
        uint256 receiverBefore = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        uint256 senderAfter = asset.balanceOf(address(this));
        uint256 receiverAfter = asset.balanceOf(to);
        if (senderAfter > senderBefore || senderBefore - senderAfter != amount) {
            revert UnexpectedBalance();
        }
        if (receiverAfter < receiverBefore || receiverAfter - receiverBefore != amount) {
            revert UnexpectedBalance();
        }
    }
}
