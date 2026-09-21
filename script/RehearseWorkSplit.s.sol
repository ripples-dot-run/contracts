// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { Collection721, CollectionParams, Mode } from "../src/Collection721.sol";
import { ScoutRegistry } from "../src/ScoutRegistry.sol";
import { DevBuyParams, LaunchParams, LinkedParams } from "../src/TokenLaunchFactory.sol";
import { WorkSplit } from "../src/WorkSplit.sol";
import { WorkSplitFactory } from "../src/WorkSplitFactory.sol";

/// One commission launch on a live test network, driven the way the site drives it: approve the
/// runway to the split factory, then create, fund and launch in one transaction.
///
/// The unit suite proves the split against a harnessed pool manager and a stand-in collection.
/// The two things most likely to differ on chain are the real launch factory and the real
/// collection, which is exactly what this touches.
///
/// It leaves a live market behind it and spends the sender's runway asset. Testnet only.
///
///   WORK_SPLIT_FACTORY  the factory deployed by DeployWorkSplit
///   WORK_RUNWAY         what to put in the split, default 0.1 of the runway asset
///   WORK_COMMISSION_BPS the published rate, default 2000
///   WORK_TRADE_SCOUT    the standing scout for trade fees, default nobody
contract RehearseWorkSplit is Script {
    uint256 internal constant RH_TESTNET = 46630;
    uint256 internal constant TOKEN_UNIT = 1e18;

    error TestnetOnly(uint256 chainId);

    function run() external {
        if (block.chainid != RH_TESTNET) revert TestnetOnly(block.chainid);

        WorkSplitFactory works = WorkSplitFactory(vm.envAddress("WORK_SPLIT_FACTORY"));
        address split = _open(works);
        _report(works, split);
    }

    /// The launch itself, kept in its own frame so the reads below do not share a stack with it.
    function _open(WorkSplitFactory works) private returns (address split) {
        uint256 runway = vm.envOr("WORK_RUNWAY", uint256(1e17));
        // Off the factory rather than an environment variable, for the reason the agent rehearsal
        // gives: the split holds one asset, and funding it in another leaves tokens it cannot pay
        // out.
        IERC20 asset = works.RUNWAY_ASSET();

        vm.startBroadcast();
        asset.approve(address(works), runway);
        (split,,,,) = works.createAndLaunch(
            msg.sender,
            uint96(vm.envOr("WORK_COMMISSION_BPS", uint256(2_000))),
            vm.envOr("WORK_TRADE_SCOUT", address(0)),
            _launchParams(),
            _collectionParams(),
            _linkedParams(),
            _noDevBuy(),
            runway
        );
        vm.stopBroadcast();
    }

    /// Everything a page would show, read back off the chain rather than off the arguments the
    /// launch was opened with.
    function _report(WorkSplitFactory works, address split) private view {
        WorkSplit work = WorkSplit(payable(split));
        console2.log("workSplit", split);
        console2.log("token", work.token());
        console2.log("collection", work.collection());
        console2.log("artist", msg.sender);
        console2.log("runway held", works.RUNWAY_ASSET().balanceOf(split));

        (address artist, uint96 rate, address scout, uint256 perMint, address registry) =
            work.terms();
        console2.log("terms.artist", artist);
        console2.log("terms.commissionBps", rate);
        console2.log("terms.tradeScout", scout);
        console2.log("terms.commissionPerMint", perMint);
        console2.log("terms.scoutRegistry", registry);

        // What one mint owes a scout, worked out from the collection's own immutables. If this
        // disagrees with what the split published, its arithmetic has drifted from the collection
        // generation it was deployed against, which is the whole risk this rehearsal exists to
        // catch.
        Collection721 pieces = Collection721(work.collection());
        uint256 net = (pieces.PRICE_QUOTE() * (10_000 - pieces.PROTOCOL_FEE_BPS())) / 10_000;
        uint256 expected = ((net * (10_000 - pieces.mintToCurveBps())) / 10_000) * rate / 10_000;
        console2.log("expected perMint", expected);
        console2.log("agrees", expected == perMint);

        console2.log("split is the collection's creator", pieces.CREATOR() == split);
        console2.log("split is vouched", works.isFromFactory(split));
        console2.log("registry names this factory", ScoutRegistry(registry).SPLIT_FACTORY());
    }

    function _launchParams() private pure returns (LaunchParams memory p) {
        p.name = "Commission Rehearsal";
        p.symbol = "WORKR";
        p.curveSupply = 800_000_000 * TOKEN_UNIT;
        p.lpTokenSupply = 265_000_000 * TOKEN_UNIT;
        p.vQuoteInit = 5.25e18;
        p.vTokenInit = 1_073_000_000 * TOKEN_UNIT;
        p.graduationQuote = 4.2e18;
        p.lpUnlockAt = 0;
        p.creatorTaxBps = 0;
        p.quote = address(0);
        p.logo = "https://api.ripples.run/v1/launch-assets/images/commission-rehearsal.png";
        p.description = "A rehearsal of the commission launch on the test network.";
        p.website = "https://ripples.run";
    }

    function _collectionParams() private pure returns (CollectionParams memory p) {
        p.name = "Commission Rehearsal Pieces";
        p.symbol = "WORKRP";
        p.priceQuote = 1e16;
        p.maxSupply = 88;
        p.perWalletCap = 0;
        p.mode = Mode.PREGEN;
        p.baseURI = "https://api.ripples.run/v1/launch-assets/commission-rehearsal/";
        p.placeholderURI =
        "https://api.ripples.run/v1/launch-assets/commission-rehearsal/placeholder.json";
        p.royaltyBps = 500;
    }

    function _linkedParams() private pure returns (LinkedParams memory lp) {
        lp.nftAllocationBps = 500;
        lp.mintToCurveBps = 2_000;
        lp.vestDuration = 365 days;
        lp.vestCliff = 30 days;
    }

    function _noDevBuy() private pure returns (DevBuyParams memory d) {
        d.snipeExempt = new address[](0);
    }
}
