// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { QuoteFeeFactory } from "../src/QuoteFeeFactory.sol";
import { QuoteRegistry } from "../src/QuoteRegistry.sol";
import { IQuoteRegistry } from "../src/interfaces/IQuoteRegistry.sol";

/// Restate `quoteFeeRegistry`'s WETH row against what `DeployQuoteFeeFactory.wethEconomics`
/// computes today, and correct it if the two disagree.
///
/// `01c96219` changed that function's discount from `TRADE_FEE_BPS` alone to
/// `TRADE_FEE_BPS + MAX_CREATOR_TAX_BPS`, the worst case a launch on this factory can choose. The
/// row on 46630 was deployed before that commit landed and was never restated, so it still
/// carries the shallower single-fee discount: a launch that chose a non-zero `creatorTaxBps`
/// would be short-sized for its own graduation. This script reads the live factory's two
/// constants, computes what the row should say, and calls `approveQuote` again with the
/// corrected figures if the on-chain row does not already match.
///
/// The four constants below and the arithmetic they feed are restated from
/// `DeployQuoteFeeFactory.wethEconomics` rather than called on an instance of it, for the same
/// reason that function itself restates `Deploy.s.sol`'s rather than importing them: instantiating
/// `DeployQuoteFeeFactory` pulls in `QuoteFeeFactory`'s whole creation-code blob, which embeds
/// every collection/locker/pool/token/vesting deployer library unlinked. Foundry auto-links a
/// broadcast by deploying whatever is missing, so a script that only wants one pure computation
/// off that contract pays for six unrelated library deployments it will never call, confirmed
/// against 46630 while drafting this file at a cost of roughly 18.5M gas across six `CREATE`s
/// that answer to nothing afterward. Restating four constants is cheaper than that mistake.
///
/// `approveQuote` is `onlyOwner`. This reads the registry's own `owner()` back and refuses to
/// spend a broadcast on a call that was always going to revert if the signer is not it.
contract RefreshQuoteFeeRegistry is Script {
    uint256 internal constant RH_TESTNET = 46630;

    /// Mirrors `DeployQuoteFeeFactory`'s own constants of the same name exactly; see that file
    /// for why each is what it is.
    uint256 internal constant BASE_PHANTOM_CENTIUNITS = 525;
    uint256 internal constant BASE_THRESHOLD_CENTIUNITS = 420;
    uint256 internal constant BASE_STANDALONE_PHANTOM_CENTIUNITS = 168;
    uint256 internal constant CENTIUNIT = 100;
    uint256 internal constant MIN_PRICE_DIVISOR = 1_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error NotRegistryOwner(address caller, address owner);

    function run() external {
        require(block.chainid == RH_TESTNET, "robinhood testnet only");
        address broadcaster = tx.origin;

        string memory record = vm.readFile("./deployments.json");
        address factoryAddr = vm.parseJsonAddress(record, ".robinhoodTestnet.quoteFeeFactory");
        address registryAddr = vm.parseJsonAddress(record, ".robinhoodTestnet.quoteFeeRegistry");
        address weth = vm.parseJsonAddress(record, ".robinhoodTestnet.weth");

        QuoteFeeFactory factory = QuoteFeeFactory(factoryAddr);
        QuoteRegistry registry = QuoteRegistry(registryAddr);

        uint256 worstCaseBps =
            uint256(factory.TRADE_FEE_BPS()) + uint256(factory.MAX_CREATOR_TAX_BPS());
        IQuoteRegistry.QuoteEconomics memory current = registry.quoteEconomics(weth);
        IQuoteRegistry.QuoteEconomics memory fresh = wethEconomics(weth, worstCaseBps);

        console2.log("trade fee bps        ", factory.TRADE_FEE_BPS());
        console2.log("max creator tax bps  ", factory.MAX_CREATOR_TAX_BPS());
        console2.log("worst-case bps       ", worstCaseBps);
        console2.log("current phantomQuote           ", current.phantomQuote);
        console2.log("current graduationThreshold    ", current.graduationThreshold);
        console2.log("current standalonePhantomQuote ", current.standalonePhantomQuote);
        console2.log("fresh   phantomQuote           ", fresh.phantomQuote);
        console2.log("fresh   graduationThreshold    ", fresh.graduationThreshold);
        console2.log("fresh   standalonePhantomQuote ", fresh.standalonePhantomQuote);

        if (
            current.phantomQuote == fresh.phantomQuote
                && current.graduationThreshold == fresh.graduationThreshold
                && current.standalonePhantomQuote == fresh.standalonePhantomQuote
                && current.minPriceQuote == fresh.minPriceQuote
                && current.decimals == fresh.decimals
        ) {
            console2.log("row already matches wethEconomics; nothing to send");
            return;
        }

        address owner = registry.owner();
        if (broadcaster != owner) revert NotRegistryOwner(broadcaster, owner);

        vm.startBroadcast();
        registry.approveQuote(weth, fresh);
        vm.stopBroadcast();

        IQuoteRegistry.QuoteEconomics memory after_ = registry.quoteEconomics(weth);
        console2.log("after   phantomQuote           ", after_.phantomQuote);
        console2.log("after   graduationThreshold    ", after_.graduationThreshold);
        console2.log("after   standalonePhantomQuote ", after_.standalonePhantomQuote);
    }

    /// Byte-for-byte the same arithmetic as `DeployQuoteFeeFactory.wethEconomics`. See the
    /// contract-level doc for why it is restated here rather than called on that contract.
    function wethEconomics(address weth, uint256 worstCaseBps)
        public
        view
        returns (IQuoteRegistry.QuoteEconomics memory e)
    {
        uint8 decimals = IERC20Metadata(weth).decimals();
        uint256 unit = 10 ** decimals;
        uint256 keptBps = BPS_DENOMINATOR - worstCaseBps;
        e.phantomQuote = (BASE_PHANTOM_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.graduationThreshold =
            (BASE_THRESHOLD_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.standalonePhantomQuote =
            (BASE_STANDALONE_PHANTOM_CENTIUNITS * unit / CENTIUNIT) * keptBps / BPS_DENOMINATOR;
        e.decimals = decimals;
        e.minPriceQuote = unit / MIN_PRICE_DIVISOR;
    }
}
