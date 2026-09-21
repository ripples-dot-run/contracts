// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console } from "forge-std/Script.sol";
import { CollectionParams, Mode } from "../src/Collection721.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";
import {
    DevBuyParams, LaunchParams, LinkedParams, TokenLaunchFactory
} from "../src/TokenLaunchFactory.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ILockerLike {
    function poolId() external view returns (bytes32);
}

// The factory's two overloads, one per interface, so `abi.encodeCall` has a unique member to
// check against. Both are declared over the factory's own struct types, so a field added to any
// tuple changes the selector and the encoding here together and fails to compile until it is set.
interface ILinkedLaunchPlain {
    function createLinkedLaunch(LaunchParams calldata tp, CollectionParams calldata np, LinkedParams calldata lp)
        external
        returns (address, address, address, address);
}

interface ILinkedLaunchWithBuy {
    function createLinkedLaunch(
        LaunchParams calldata tp,
        CollectionParams calldata np,
        LinkedParams calldata lp,
        DevBuyParams calldata d
    ) external returns (address, address, address, address);
}

/// One real linked launch on the live Arc rail, with the creator's own money.
///
/// A deploy that verifies is a deploy whose bytecode matches; it says nothing about whether a
/// market opens, prices and takes a buy. This does the thing a creator does, on the chain
/// creators will use, and fails loudly if any of it does not answer.
///
///   ARC_TOKEN_FACTORY  the factory to launch through
///   ARC_QUOTE          the asset to settle in
///   REHEARSAL_BUY      the opening buy, in the quote's own units (0 to skip)
contract RehearseArc is Script {
    // Token supplies for the standard linked shape. The reserves and the floor come off the
    // registry row at run time.
    uint256 private constant CURVE_SUPPLY = 800_000_000e18;
    uint256 private constant LP_TOKEN_SUPPLY = 265_000_000e18;
    uint256 private constant V_TOKEN_INIT = 1_073_000_000e18;

    TokenLaunchFactory private factory;
    IERC20Like private quote;
    IQuoteRegistry.QuoteEconomics private row;

    function run() external {
        factory = TokenLaunchFactory(vm.envAddress("ARC_TOKEN_FACTORY"));
        quote = IERC20Like(vm.envAddress("ARC_QUOTE"));
        row = IQuoteRegistry(factory.quoteRegistry()).quoteEconomics(address(quote));
        console.log("linked reserve", row.phantomQuote);
        console.log("target        ", row.graduationThreshold);
        console.log("mint floor    ", row.minPriceQuote);

        uint256 buy = vm.envOr("REHEARSAL_BUY", uint256(0));
        // Six-decimal USDC. A figure with eighteen decimals on it would encode a trillion-USDC
        // buy that reverts only after the operator has signed it.
        require(buy <= row.graduationThreshold, "REHEARSAL_BUY is above the graduation target");

        // The calldata, printed rather than broadcast.
        //
        // USDC settles through two Arc precompiles: one moves the balance and one answers whether
        // an address is blocked. Neither is an opcode the local EVM has, so a launch cannot run
        // here at all, and standing stubs in their place would have the script record a
        // transaction built against balances that never moved. Hand the bytes to `cast send`
        // instead and let the chain execute the whole thing once, for real.
        //
        bytes memory data = buy == 0
            ? abi.encodeCall(ILinkedLaunchPlain.createLinkedLaunch, (_token(), _collection(), _coupling()))
            : abi.encodeCall(
                ILinkedLaunchWithBuy.createLinkedLaunch,
                (_token(), _collection(), _coupling(), DevBuyParams(buy, 0, new address[](0)))
            );

        // The row is read now and the bytes are sent later, and the factory re-reads the row at
        // create. Run the first line against the chain immediately before the second: it answers
        // the four addresses the launch would return, or the revert that the send would burn gas on.
        console.log("preflight");
        console.log(string.concat("cast call --from <deployer> ", vm.toString(address(factory)), " ", vm.toString(data), " --rpc-url $ARC_RPC_URL"));
        console.log("send");
        console.log(string.concat("cast send ", vm.toString(address(factory)), " ", vm.toString(data), " --account <keystore> --rpc-url $ARC_RPC_URL"));
    }

    function _token() private view returns (LaunchParams memory) {
        return LaunchParams({
            name: "Arc Rehearsal",
            symbol: "ARCREH",
            curveSupply: CURVE_SUPPLY,
            lpTokenSupply: LP_TOKEN_SUPPLY,
            vQuoteInit: row.phantomQuote,
            vTokenInit: V_TOKEN_INIT,
            graduationQuote: row.graduationThreshold,
            lpUnlockAt: 0,
            creatorTaxBps: 0,
            quote: address(quote),
            logo: "https://ripples.run/icon.png",
            description: "Opening rehearsal for the Arc rail.",
            twitter: "",
            telegram: "",
            discord: "",
            website: "https://ripples.run",
            farcaster: ""
        });
    }

    function _collection() private view returns (CollectionParams memory) {
        return CollectionParams({
            name: "Arc Rehearsal Pieces",
            symbol: "ARCREHP",
            priceQuote: row.minPriceQuote,
            maxSupply: 100,
            perWalletCap: 10,
            startTime: 0,
            endTime: 0,
            mode: Mode.LIVE,
            baseURI: "https://ripples.run/rehearsal/",
            placeholderURI: "https://ripples.run/rehearsal/placeholder.json",
            royaltyBps: 500,
            quote: address(quote)
        });
    }

    function _coupling() private pure returns (LinkedParams memory) {
        return LinkedParams({
            nftAllocationBps: 2000,
            mintToCurveBps: 500,
            vestDuration: 365 days,
            vestCliff: 30 days,
            objectClaim: true,
            wavesOpen: true
        });
    }
}
