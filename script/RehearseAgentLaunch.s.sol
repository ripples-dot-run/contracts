// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { AgentTreasury, Charter } from "../src/AgentTreasury.sol";
import { AgentTreasuryFactory } from "../src/AgentTreasuryFactory.sol";
import { CollectionParams, Mode } from "../src/Collection721.sol";
import { DevBuyParams, LaunchParams, LinkedParams } from "../src/TokenLaunchFactory.sol";

/// One agent launch on a live test network, driven the way the site drives it: approve the
/// runway to the agent factory, then create, fund and launch in one transaction.
/// `WorkAgentTreasury` is the second half, run once the opening tax window has closed.
///
/// The pair exists because the unit suite proves the treasury against a Permit2 stand-in and a
/// harnessed pool manager, and the two things most likely to differ on chain are exactly those:
/// the real allowance ledger and the real router.
///
/// Testnet only. It spends the sender's runway asset and leaves a live market behind it.
///
///   AGENT_TREASURY_FACTORY  the factory deployed by DeployAgentTreasury
///   AGENT_RUNWAY            what to put in the treasury, default 0.1 of the runway asset
contract RehearseAgentLaunch is Script {
    uint256 internal constant RH_TESTNET = 46630;
    uint256 internal constant TOKEN_UNIT = 1e18;

    error TestnetOnly(uint256 chainId);

    function run() external {
        if (block.chainid != RH_TESTNET) revert TestnetOnly(block.chainid);

        AgentTreasuryFactory agents = AgentTreasuryFactory(vm.envAddress("AGENT_TREASURY_FACTORY"));
        uint256 runway = vm.envOr("AGENT_RUNWAY", uint256(1e17));
        // Off the factory rather than an environment variable. The treasury holds and meters one
        // asset, and funding it in another would put tokens in a contract that cannot spend them.
        IERC20 asset = agents.RUNWAY_ASSET();

        vm.startBroadcast();

        asset.approve(address(agents), runway);
        (address treasury, address token, address market, address collection,) = agents.createAndLaunch(
            _charter(msg.sender),
            _launchParams(),
            _collectionParams(),
            _linkedParams(),
            _noDevBuy(),
            runway
        );

        console2.log("agentTreasury", treasury);
        console2.log("token", token);
        console2.log("market", market);
        console2.log("collection", collection);
        console2.log("operator", msg.sender);
        console2.log("runway held", asset.balanceOf(treasury));

        vm.stopBroadcast();
    }

    /// The charter the form's default offers: an agent that can spend a bounded amount a day,
    /// can never sell its own token, and can pay one published address.
    function _charter(address operator) private pure returns (Charter memory c) {
        c.operator = operator;
        c.dailySpend = 1e17;
        c.perCallSpend = 5e16;
        c.dailySell = 0;
        c.dailyMint = 5;
        c.payees = new address[](1);
        c.payees[0] = operator;
    }

    function _launchParams() private pure returns (LaunchParams memory p) {
        p.name = "Agent Rehearsal";
        p.symbol = "AGENTR";
        p.curveSupply = 800_000_000 * TOKEN_UNIT;
        p.lpTokenSupply = 265_000_000 * TOKEN_UNIT;
        p.vQuoteInit = 5.25e18;
        p.vTokenInit = 1_073_000_000 * TOKEN_UNIT;
        p.graduationQuote = 4.2e18;
        p.lpUnlockAt = 0;
        p.creatorTaxBps = 0;
        p.quote = address(0);
        p.logo = "https://api.ripples.run/v1/launch-assets/images/agent-rehearsal.png";
        p.description = "A rehearsal of the agent launch on the test network.";
        p.website = "https://ripples.run";
    }

    function _collectionParams() private pure returns (CollectionParams memory p) {
        p.name = "Agent Rehearsal Pieces";
        p.symbol = "AGENTRP";
        p.priceQuote = 1e16;
        p.maxSupply = 88;
        p.perWalletCap = 0;
        p.mode = Mode.PREGEN;
        p.baseURI = "https://api.ripples.run/v1/launch-assets/agent-rehearsal/";
        p.placeholderURI =
        "https://api.ripples.run/v1/launch-assets/agent-rehearsal/placeholder.json";
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
