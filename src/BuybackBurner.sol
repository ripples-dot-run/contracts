// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// The only call the burner needs from a venue: spend `amountIn` of the quote it has been
/// approved for and return the token it bought. `UniswapV4Venue` is the only implementation:
/// every market on this rail is a Uniswap v4 pool from its first block, and the PoolManager
/// answers no such call.
interface IBuyVenue {
    function buy(uint256 amountIn, uint256 minOut) external returns (uint256 out);
}

/// The read a venue is asked for, used only to refuse an obvious wiring mistake. It is probed,
/// never required: a venue that does not answer is still allowed, and the spend guard still
/// bounds it.
interface IVenueQuote {
    function QUOTE() external view returns (address);
}

/// @notice Turns accumulated protocol fees into the platform token and sends them to the dead
///         address, one bounded step per keeper call.
///
///         **The burner is wired to one settlement asset and stays there.** v1 buys $RIPP with
///         WETH and nothing else (DQ13): stock-denominated fees go to the treasury and never
///         reach this contract, because the burn venue is WETH-quoted and a stock token has no
///         path to it. A launch settling in a stock token therefore contributes to the treasury
///         rather than to the buyback, and the epoch report buckets it `routedToTreasury: true`.
///         `QUOTE` is immutable, so this is a property of the deployment and not a setting.
///
///         The time-weighting lives in the keeper, not here: it drips small calls over the day,
///         and each call does a single capped, slippage-checked buy-and-burn. Every burn is a
///         plain transfer to `0x..dEaD`, so the supply the program has retired is a figure anyone
///         can total from chain state rather than one they have to take on trust.
contract BuybackBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    /// The settlement token fees arrive in: WETH on this chain today, a different unit on
    /// another market later. Taken at deploy and never assumed, so one contract fits any market.
    IERC20 public immutable QUOTE;
    /// The platform token this buys and burns.
    IERC20 public immutable TOKEN;

    address public keeper;
    IBuyVenue public venue;
    /// Ceiling on quote spent per call. The keeper is trusted only to pace the buys, not to
    /// size a transaction: each call can move at most `maxPerCall`, and its output remains
    /// bounded by the supplied slippage floor.
    uint256 public maxPerCall;
    bool public paused;

    uint256 public totalBurned;

    event KeeperSet(address indexed keeper);
    event VenueSet(address indexed venue);
    event MaxPerCallSet(uint256 maxPerCall);
    event PausedSet(bool paused);
    event BoughtAndBurned(uint256 amountIn, uint256 burned);
    event PendingTokensBurned(uint256 burned);

    error NotKeeper();
    error IsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error ExceedsMaxPerCall();
    error InsufficientQuote();
    error ProtectedToken();
    error SlippageExceeded();
    error NotAContract();
    error InvalidTokenPair();
    error UnexpectedSpend();
    error TransferMismatch();

    constructor(IERC20 quote, IERC20 token, address owner_) Ownable(owner_) {
        if (address(quote) == address(0) || address(token) == address(0)) revert ZeroAddress();
        if (address(quote) == address(token)) revert InvalidTokenPair();
        if (address(quote).code.length == 0 || address(token).code.length == 0) {
            revert NotAContract();
        }
        QUOTE = quote;
        TOKEN = token;
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Point the burner at a venue. A venue that settles in a different asset than this
    ///         burner is refused here rather than at spend time: with per-launch quotes there
    ///         are now stock-quoted curves that satisfy `IBuyVenue` exactly, and pointing the
    ///         WETH burner at one is a plausible mistake rather than an impossible one. It would
    ///         be caught either way (the spend guard reverts `UnexpectedSpend` when the venue
    ///         pulls an asset this contract did not approve), but a misconfiguration that
    ///         announces itself when it is made beats one that surfaces on the keeper's next
    ///         call. A venue that does not answer `QUOTE()` is still allowed.
    function setVenue(IBuyVenue venue_) external onlyOwner {
        if (address(venue_) == address(0)) revert ZeroAddress();
        if (address(venue_).code.length == 0) revert NotAContract();
        try IVenueQuote(address(venue_)).QUOTE() returns (address venueQuote) {
            if (venueQuote != address(QUOTE)) revert InvalidTokenPair();
        } catch { }
        venue = venue_;
        emit VenueSet(address(venue_));
    }

    /// Zero is a valid setting: it stops new buys without touching the paused flag or the
    /// balance, since every call must spend at least one unit and at most this.
    function setMaxPerCall(uint256 maxPerCall_) external onlyOwner {
        maxPerCall = maxPerCall_;
        emit MaxPerCallSet(maxPerCall_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Spend `amountIn` of the quote on the platform token and burn what comes back.
    ///         Keeper-only and bounded on every axis: paused stops it, `maxPerCall` caps the
    ///         spend and the balance caps it again. What is burned is the token the buy actually
    ///         delivered, read as a balance delta rather than the venue's return value, so a
    ///         venue that overstates its output cannot inflate the burn or the running total
    ///         past what moved.
    function buyAndBurn(uint256 amountIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 burned)
    {
        if (paused) revert IsPaused();
        if (msg.sender != keeper) revert NotKeeper();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > maxPerCall) revert ExceedsMaxPerCall();
        if (amountIn > QUOTE.balanceOf(address(this))) revert InsufficientQuote();

        IBuyVenue v = venue;
        if (address(v).code.length == 0) revert NotAContract();
        uint256 quoteBefore = QUOTE.balanceOf(address(this));
        uint256 tokenBefore = TOKEN.balanceOf(address(this));

        QUOTE.forceApprove(address(v), amountIn);
        v.buy(amountIn, minTokensOut);
        QUOTE.forceApprove(address(v), 0);

        uint256 quoteAfter = QUOTE.balanceOf(address(this));
        if (quoteAfter > quoteBefore || quoteBefore - quoteAfter != amountIn) {
            revert UnexpectedSpend();
        }

        uint256 tokenAfter = TOKEN.balanceOf(address(this));
        if (tokenAfter < tokenBefore) revert TransferMismatch();
        burned = tokenAfter - tokenBefore;

        // The venue runs its own slippage check, but it is the untrusted party here, so the
        // delivered amount is checked again against the same bound before anything is burned.
        if (burned < minTokensOut) revert SlippageExceeded();
        if (burned == 0) revert ZeroAmount();

        _burnExact(burned);
        totalBurned += burned;
        emit BoughtAndBurned(amountIn, burned);
    }

    /// @notice Burn platform tokens sent here outside a venue purchase. Anyone may flush them;
    ///         they cannot be rescued by the owner and have no other valid destination.
    function burnPendingTokens() external nonReentrant returns (uint256 burned) {
        burned = TOKEN.balanceOf(address(this));
        if (burned == 0) revert ZeroAmount();
        _burnExact(burned);
        totalBurned += burned;
        emit PendingTokensBurned(burned);
    }

    function pendingQuote() external view returns (uint256) {
        return QUOTE.balanceOf(address(this));
    }

    /// @notice Recover a token sent here by mistake. The quote and the platform token are off
    ///         limits: sweeping the quote would let the owner take the buyback funds, and
    ///         sweeping the token would pull back supply that is on its way to the burn. Those
    ///         two are the whole point of the contract; everything else is fair to return.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (address(token) == address(QUOTE) || address(token) == address(TOKEN)) {
            revert ProtectedToken();
        }
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    function _burnExact(uint256 amount) private {
        uint256 balanceBefore = TOKEN.balanceOf(address(this));
        uint256 burnBefore = TOKEN.balanceOf(BURN);
        TOKEN.safeTransfer(BURN, amount);
        uint256 balanceAfter = TOKEN.balanceOf(address(this));
        uint256 burnAfter = TOKEN.balanceOf(BURN);
        if (
            balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount
                || burnAfter < burnBefore || burnAfter - burnBefore != amount
        ) revert TransferMismatch();
    }
}
