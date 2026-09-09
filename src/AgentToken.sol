// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// The five links a launch publishes with its token. The order is the one the launcher rail
/// terminals already index publishes them in, X first, so a reader that unpacks `socials()`
/// there unpacks ours the same way.
struct TokenSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

/// @notice The token a launch sells. Its entire supply is minted once, at construction, to the
///         nominated holder, with no mint, burn, or owner afterwards. The launch factory
///         transfers that fixed supply to the launch's locker while assembling the launch, and
///         the locker is what puts it in the pool. Nobody, including the factory, can inflate it
///         later.
///
///         It also carries its own identity: the image, the description and the links a market
///         terminal shows beside the ticker. Those are written once, in the constructor, and
///         there is no setter and no owner to change them afterwards. A token whose picture can
///         be swapped after it lists is one whose listing says nothing about what listed.
///
///         It carries standard EIP-2612 approvals and a separate one-shot sale authorization.
///         The latter binds the curve, amount, slippage floor, nonce, and deadline before moving
///         tokens to that curve, so a third party can relay an exit without gaining control over
///         its terms or proceeds.
contract AgentToken is ERC20, ERC20Permit {
    /// `minQuoteOut` is denominated in **the launch's own quote asset, in that asset's raw
    /// units**. The typehash's `curve` field is the only thing that says which asset that is (it
    /// carries the launch's `LPLocker`), and the typehash names neither the asset nor its
    /// decimals. A signer that assumes 18 decimals signs a floor 1e12 too large against a
    /// 6-decimal quote and 1e10 too large against an 8-decimal one, so the signer must read
    /// `LPLocker.QUOTE()` and its `decimals()` before formatting the figure, and a stock quote's
    /// `uiMultiplier` must never be applied to it (it is a signed amount, not a display one).
    ///
    /// The typehash itself must not change: it is deployed, it fixes the EIP-712 struct hash,
    /// and editing it would invalidate every signature already issued.
    bytes32 public constant SELL_AUTHORIZATION_TYPEHASH = keccak256(
        "SellAuthorization(address seller,address curve,uint256 tokensIn,uint256 minQuoteOut,uint256 nonce,uint256 deadline)"
    );

    mapping(address seller => uint256) public sellAuthorizationNonces;

    /// The launch's identity, readable by anything that can call a contract: no filing, no
    /// listing form, no allowlist. The getters below are byte-for-byte the ones
    /// `PonsV2LauncherToken` exposes (`contractsV2/src/v2/PonsV2LauncherToken.sol`, read
    /// 2026-09-07), because that is the rail the terminals on this chain already read:
    ///
    ///     logo()        -> (string)
    ///     description() -> (string)
    ///     socials()     -> (string twitter, string telegram, string discord, string website,
    ///                       string farcaster)
    ///
    /// Solidity has no immutable string, so these are plain storage with nothing that writes
    /// them after construction. What a launch freezes here it publishes for good.
    string public logo;
    string public description;

    /// Read through `socials()` rather than exposed directly, so the getter is the five-value
    /// tuple above. Five public strings would answer `twitter()` and friends instead, which is
    /// not what anything reads.
    TokenSocials private _socials;

    error ZeroSupply();
    error ZeroRecipient();
    error SellAuthorizationExpired();
    error InvalidSellAuthorization();

    /// @param logo_ URI of the token's image. Bounded and required by the caller that deploys
    ///        this, because an image is the whole point of carrying identity on chain.
    constructor(
        string memory name_,
        string memory symbol_,
        address holder,
        uint256 supply,
        string memory logo_,
        string memory description_,
        TokenSocials memory socials_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (holder == address(0)) revert ZeroRecipient();
        if (supply == 0) revert ZeroSupply();
        logo = logo_;
        description = description_;
        _socials = socials_;
        _mint(holder, supply);
    }

    /// @notice The launch's five social links, X first, in the order the launcher rail publishes
    ///         them. Any slot may be empty; a reader shows the ones that are set.
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        TokenSocials memory s = _socials;
        return (s.twitter, s.telegram, s.discord, s.website, s.farcaster);
    }

    /// @notice Consume a curve-specific sale authorization and move the signed amount from the
    ///         seller to the calling curve. The signature also binds the seller's slippage floor,
    ///         so a relayer can execute the sale but cannot weaken its terms. This nonce is
    ///         independent from EIP-2612 approvals, which remain available for ordinary use.
    function transferWithSellAuthorization(
        address seller,
        uint256 tokensIn,
        uint256 minQuoteOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (deadline != 0 && block.timestamp > deadline) {
            revert SellAuthorizationExpired();
        }

        uint256 nonce = sellAuthorizationNonces[seller];
        bytes32 structHash = keccak256(
            abi.encode(
                SELL_AUTHORIZATION_TYPEHASH,
                seller,
                msg.sender,
                tokensIn,
                minQuoteOut,
                nonce,
                deadline
            )
        );
        if (!SignatureChecker.isValidSignatureNow(
                seller, _hashTypedDataV4(structHash), abi.encodePacked(r, s, v)
            )) revert InvalidSellAuthorization();

        sellAuthorizationNonces[seller] = nonce + 1;
        _transfer(seller, msg.sender, tokensIn);
    }
}
