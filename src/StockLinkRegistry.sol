// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// The token rail's registry. A launch's subject is its **locker**: a pool is a 32-byte id and
/// the hook is a singleton shared by every launch, so neither can name one. `isFromFactory`
/// marks a locker this factory deployed and `allLaunches` records the creator beside it, which
/// is the pair this contract walks to find out who may link a launch.
interface ITokenLaunchRegistry {
    function isFromFactory(address locker) external view returns (bool);
    function launchCount() external view returns (uint256);
    function allLaunches(uint256 index)
        external
        view
        returns (address token, address locker, address hook, address creator);
}

/// The NFT rail's registry.
interface ICollectionRegistry {
    function isFromFactory(address collection) external view returns (bool);
}

/// The three reads a `Collection721` answers about its own provenance. `curveSink` is non-zero
/// exactly for the collection leg of a linked launch, and holds that launch's locker.
interface ILaunchpadCollection {
    function FACTORY() external view returns (address);
    function CREATOR() external view returns (address);
    function curveSink() external view returns (address);
}

/// @title StockLinkRegistry
/// @notice Records which stock token a launch is *about*. Association only: it stores an address
///         and changes no money flow, no supply, no price and no permission anywhere else in the
///         launchpad. Nothing here verifies the issuer, the instrument, or that the recorded
///         address is a stock token at all. The chain cannot, and this contract does not pretend
///         to. It is the Robinhood Chain twin of the Solana `StockLink` account.
///
/// One link per subject, written once, by the subject's own creator, and never changed or
/// removed. The subject is either a launch's locker or a standalone NFT collection; the creator
/// is read from whichever factory deployed it. The collection leg of a linked launch is not a
/// subject of its own (its launch is, exactly as on Solana), and a caller who names it is sent
/// to the locker by `LinkThroughLaunch`.
///
/// The registry has no owner, no pause, no upgrade path and no list of permitted callers. It
/// reads nothing about the caller beyond whether they are the recorded creator, and stores
/// nothing about them beyond that same address.
contract StockLinkRegistry {
    /// The association, as it is published. `stockToken` doubles as the "written" flag: it is
    /// non-zero exactly for a linked subject, because `link` rejects a codeless stock token.
    struct Link {
        address stockToken;
        address creator;
        uint64 createdAt;
    }

    /// `TokenLaunchFactory` deploys token launches, and the collection leg of a linked launch.
    address public immutable TOKEN_FACTORY;
    /// `LaunchpadFactory` deploys standalone NFT collections.
    address public immutable NFT_FACTORY;

    /// The frozen read surface: `linkOf(subject)` returns `(stockToken, creator, createdAt)`.
    mapping(address subject => Link) public linkOf;

    event StockLinked(
        address indexed subject,
        address indexed stockToken,
        address indexed creator,
        uint64 createdAt
    );

    error AlreadyLinked();
    error NotCreator();
    error NotAContract();
    error ZeroAddress();
    /// The subject was not deployed by either factory, so no creator is recorded for it.
    error UnknownSubject();
    /// The subject is the collection leg of a linked launch; link the launch instead.
    error LinkThroughLaunch(address locker);
    /// `linkAt` was given an index that does not hold this subject.
    error LaunchIndexMismatch();

    constructor(address tokenFactory, address nftFactory) {
        if (tokenFactory == address(0) || nftFactory == address(0)) revert ZeroAddress();
        if (tokenFactory.code.length == 0 || nftFactory.code.length == 0) revert NotAContract();
        TOKEN_FACTORY = tokenFactory;
        NFT_FACTORY = nftFactory;
    }

    /// @notice Record, once and forever, the stock token `subject` is about.
    /// @dev For a launch this walks `TokenLaunchFactory.allLaunches` newest-first, one external
    ///      call per entry, so its cost grows with the launch list. A front end already holds the
    ///      index (`allLaunches`/`launches()` is where it read the launch from) and should call
    ///      `linkAt(subject, stockToken, index)` instead. Reserve `link` for callers that have no
    ///      index to hand, and for a collection subject, where there is no walk at all.
    /// @param subject A launch's locker from `TokenLaunchFactory`, or a standalone collection
    ///        from `LaunchpadFactory`. The collection leg of a linked launch is not a subject.
    /// @param stockToken The token address to publish. Must be a contract; nothing else about it
    ///        is checked, on purpose: the issuer's catalog is an off-chain claim.
    function link(address subject, address stockToken) external {
        _guard(subject, stockToken);
        _record(subject, stockToken, _creatorOf(subject));
    }

    /// @notice `link` for a launch whose position in `TokenLaunchFactory.allLaunches` the caller
    ///         already knows. Identical in effect; it skips the walk, so a link stays affordable
    ///         however long the launch list grows.
    /// @param launchIndex Index into `allLaunches` holding this locker.
    function linkAt(address subject, address stockToken, uint256 launchIndex) external {
        _guard(subject, stockToken);
        _record(subject, stockToken, _creatorAtIndex(subject, launchIndex));
    }

    /// @notice Whether `subject` already carries a link.
    function isLinked(address subject) external view returns (bool) {
        return linkOf[subject].stockToken != address(0);
    }

    /// @notice The address `link(subject, ...)` will accept as the caller. Reverts for a subject
    ///         neither factory deployed, so a form can tell "not linkable" from "not yours".
    function creatorOf(address subject) external view returns (address) {
        return _creatorOf(subject);
    }

    /// Checks that hold whatever the subject turns out to be, so a codeless stock token or a
    /// second link costs nothing more than the two reads it takes to find out.
    function _guard(address subject, address stockToken) private view {
        if (stockToken.code.length == 0) revert NotAContract();
        if (linkOf[subject].stockToken != address(0)) revert AlreadyLinked();
    }

    function _record(address subject, address stockToken, address creator) private {
        if (msg.sender != creator) revert NotCreator();
        uint64 createdAt = uint64(block.timestamp);
        linkOf[subject] = Link({ stockToken: stockToken, creator: creator, createdAt: createdAt });
        emit StockLinked(subject, stockToken, creator, createdAt);
    }

    /// A locker first, because that is the common subject and the token factory answers it in one
    /// read; anything else has to look like a collection.
    function _creatorOf(address subject) private view returns (address) {
        if (ITokenLaunchRegistry(TOKEN_FACTORY).isFromFactory(subject)) {
            return _launchCreator(subject);
        }
        return _collectionCreator(subject);
    }

    /// `allLaunches` is append-only and holds the creator beside the locker, so the record is
    /// found by walking it. Newest first: a creator normally links right after they launch.
    function _launchCreator(address locker) private view returns (address) {
        uint256 count = ITokenLaunchRegistry(TOKEN_FACTORY).launchCount();
        for (uint256 i = count; i > 0; --i) {
            (, address recorded,, address creator) =
                ITokenLaunchRegistry(TOKEN_FACTORY).allLaunches(i - 1);
            if (recorded == locker) return creator;
        }
        // `isFromFactory` said this locker is ours, so the entry exists; unreachable in practice.
        revert UnknownSubject();
    }

    function _creatorAtIndex(address locker, uint256 index) private view returns (address) {
        if (!ITokenLaunchRegistry(TOKEN_FACTORY).isFromFactory(locker)) revert UnknownSubject();
        (, address recorded,, address creator) =
            ITokenLaunchRegistry(TOKEN_FACTORY).allLaunches(index);
        if (recorded != locker) revert LaunchIndexMismatch();
        return creator;
    }

    /// A collection carries its own creator, so provenance is the whole job: it has to be one
    /// this launchpad deployed, and it has to be a standalone drop rather than the collection leg
    /// of a linked launch. A subject that answers neither shape is simply unknown here.
    function _collectionCreator(address subject) private view returns (address) {
        if (subject.code.length == 0) revert NotAContract();

        address collectionFactory = _readAddress(subject, ILaunchpadCollection.FACTORY.selector);
        // `curveSink` is the frozen name; what a linked collection answers with is the launch's
        // locker, which is what it routes mint revenue to.
        address locker = _readAddress(subject, ILaunchpadCollection.curveSink.selector);

        // A linked launch's collection is deployed in the token factory's context, so that is the
        // factory it reads back, and it is absent from the NFT factory's registry. Point the
        // caller at the launch rather than letting the pair carry two different links.
        if (locker != address(0) && ITokenLaunchRegistry(TOKEN_FACTORY).isFromFactory(locker)) {
            revert LinkThroughLaunch(locker);
        }
        if (collectionFactory != NFT_FACTORY) revert UnknownSubject();
        if (!ICollectionRegistry(NFT_FACTORY).isFromFactory(subject)) revert UnknownSubject();

        address creator = _readAddress(subject, ILaunchpadCollection.CREATOR.selector);
        if (creator == address(0)) revert UnknownSubject();
        return creator;
    }

    /// One `address`-returning probe into a subject that claims to be a collection. A `try` here
    /// would only catch a revert: a subject with a catch-all fallback answers successfully with
    /// the wrong shape, and the caller's own decoding would then fail with an empty reason. Every
    /// shape a `Collection721` would never produce (a revert, a short answer, a word with
    /// anything above the low 160 bits) is `UnknownSubject`, which a form can read.
    function _readAddress(address subject, bytes4 selector) private view returns (address) {
        (bool ok, bytes memory answer) = subject.staticcall(abi.encodeWithSelector(selector));
        if (!ok || answer.length < 32) revert UnknownSubject();
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(answer, 0x20))
        }
        if (word > type(uint160).max) revert UnknownSubject();
        return address(uint160(word));
    }
}
