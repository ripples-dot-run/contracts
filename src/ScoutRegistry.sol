// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Collection721 } from "./Collection721.sol";

/// The two reads a binding is checked against, declared here rather than imported so this file
/// and `WorkSplit` do not import each other.
interface IWorkSplit {
    // solhint-disable-next-line func-name-mixedcase
    function ARTIST() external view returns (address);
    function collection() external view returns (address);
}

/// The record of which splits are real. A registry that trusted the split to vouch for itself
/// would accept a forged pair, since a contract can answer any address it likes to
/// `SPLIT_FACTORY()`; the factory's own list is the only answer that is not self-attesting.
interface IWorkSplitFactory {
    function isFromFactory(address split) external view returns (bool);
}

/// @title ScoutRegistry
/// @notice Which scout brought which buyer, for every launch that pays a commission.
///
/// A buyer binds their own scout with their own signature, once per launch, before the mints
/// they want that scout paid for. The scout cannot bind anyone, and nobody can bind on a
/// buyer's behalf, so a link that was never clicked earns nothing and a first click cannot
/// collect on a stranger's later purchases.
///
/// **The binding is a snapshot, not a flag.** It records what the buyer had already minted at
/// the moment they bound, and `WorkSplit` pays only on the pieces that came after it. Without
/// that number a buyer who minted the whole collection and then bound a scout would hand over a
/// commission on work the scout had nothing to do with.
///
/// **This contract holds no money and has no way to hold any.** No payable function, no token
/// approval, no owner and no upgrade: one struct per buyer per launch, and two reads.
contract ScoutRegistry {
    /// What a buyer bound, and when in their own mint history they bound it. `mintsAtBinding` is
    /// zero for a buyer who binds before the split has opened its launch, which is the ordinary
    /// case: a scout's link is shared before the drop as often as after it.
    struct Binding {
        address scout;
        uint256 mintsAtBinding;
    }

    /// The factory whose splits may be bound to. Immutable, and deployed alongside this contract
    /// by that factory, so the pair cannot be mismatched after the fact.
    address public immutable SPLIT_FACTORY;

    mapping(address split => mapping(address buyer => Binding)) private _bindings;

    /// `mintsAtBinding` is on the log as well as in storage so a page can show a scout which
    /// pieces they are owed for without reading state at two block heights.
    event ScoutBound(
        address indexed split, address indexed buyer, address indexed scout, uint256 mintsAtBinding
    );

    error ZeroAddress();
    /// A split this registry's factory did not deploy. Binding to one would publish a commission
    /// nobody is bound to pay.
    error UnknownSplit();
    /// One scout per buyer per launch, and the first one wins. Rebinding would let a buyer move
    /// a commission off the scout who actually brought them after the mint had happened.
    error AlreadyBound();
    /// The address named is one a binding must never carry. Naming the artist would publish a
    /// commission that pays the artist their own money. The split and this registry can neither
    /// call `claim` nor be paid by anybody who does, so a commission credited to either sits on
    /// that launch's ledger for the rest of its life, out of the scout's reach and held back from
    /// the artist with it.
    ///
    /// The caller's own address is refused. A buyer may still name a second wallet they control;
    /// nothing on chain separates that from a scout, and the artist keeps the published share
    /// either way.
    error InvalidScout();

    /// @dev No code check on `splitFactory`. The factory deploys this registry from inside its
    ///      own constructor, where it has no runtime code yet, and a registry deployed any other
    ///      way answers `UnknownSplit` to every bind rather than doing harm.
    constructor(address splitFactory) {
        if (splitFactory == address(0)) revert ZeroAddress();
        SPLIT_FACTORY = splitFactory;
    }

    /// @notice Name the scout who brought you to this launch. Their commission is paid on the
    ///         pieces you mint from here on, at the rate the launch published.
    /// @dev The caller is the buyer, always. `Collection721` records a mint against the address
    ///      that called `mint`, so a buyer minting through a smart-contract wallet or a relayer
    ///      has to bind from that same address or the mints will not be theirs to attribute.
    function bind(address split, address scout) external {
        if (scout == address(0)) revert ZeroAddress();
        if (!IWorkSplitFactory(SPLIT_FACTORY).isFromFactory(split)) revert UnknownSplit();
        if (
            scout == msg.sender || scout == split || scout == address(this)
                || scout == IWorkSplit(split).ARTIST()
        ) {
            revert InvalidScout();
        }

        Binding storage binding = _bindings[split][msg.sender];
        if (binding.scout != address(0)) revert AlreadyBound();

        uint256 minted;
        address collection = IWorkSplit(split).collection();
        if (collection != address(0)) minted = Collection721(collection).mintedBy(msg.sender);

        binding.scout = scout;
        binding.mintsAtBinding = minted;
        emit ScoutBound(split, msg.sender, scout, minted);
    }

    /// @notice Who this buyer bound on this launch, or zero if they arrived on their own.
    function scoutOf(address split, address buyer) external view returns (address) {
        return _bindings[split][buyer].scout;
    }

    /// @notice The binding in full: the scout, and how many pieces the buyer had already minted
    ///         when they bound them. `WorkSplit.settleMints` pays on the difference.
    function bindingOf(address split, address buyer)
        external
        view
        returns (address scout, uint256 mintsAtBinding)
    {
        Binding storage binding = _bindings[split][buyer];
        return (binding.scout, binding.mintsAtBinding);
    }
}
