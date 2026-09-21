// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { AgentTreasury } from "../src/AgentTreasury.sol";
import { Collection721 } from "../src/Collection721.sol";

/// The second half of the agent rehearsal: work a live treasury as its operator, once the
/// opening tax window has closed. Every call here is one an agent makes for itself, and the
/// point of running them on chain is the two pieces the unit suite has to stand in for, the real
/// Permit2 ledger and the real router.
///
/// The charter the first half writes lists one payee, the sender, so this has to run as the
/// same wallet.
///
///   AGENT_TREASURY  the treasury to work
///   AGENT_BUY       quote to put through the market, default 0.02 of the runway asset
///   AGENT_PAY       what to pay the published payee, default 0.001
contract WorkAgentTreasury is Script {
    uint256 internal constant RH_TESTNET = 46630;

    error TestnetOnly(uint256 chainId);

    function run() external {
        if (block.chainid != RH_TESTNET) revert TestnetOnly(block.chainid);

        AgentTreasury agent = AgentTreasury(vm.envAddress("AGENT_TREASURY"));
        uint256 buy = vm.envOr("AGENT_BUY", uint256(2e16));

        vm.startBroadcast();

        // No floor on either order: a rehearsal has no price to protect, and a floor here would
        // only turn a moved market into a failed run.
        (uint256 spent, uint256 received) = agent.buy(buy, 0, block.timestamp + 300);
        console2.log("bought spent", spent);
        console2.log("bought received", received);

        agent.mint(1, 0);
        console2.log("pieces held", Collection721(agent.collection()).balanceOf(address(agent)));

        agent.pay(msg.sender, vm.envOr("AGENT_PAY", uint256(1e15)));
        agent.note(keccak256("rehearsal"), "https://ripples.run/agent/rehearsal");

        (uint256 quoteFees, uint256 tokenFees) = agent.claimFees();
        console2.log("fees claimed quote", quoteFees);
        console2.log("fees claimed token", tokenFees);

        (uint256 spendLeft, uint256 sellLeft, uint256 mintLeft) = agent.remainingToday();
        console2.log("remaining spend", spendLeft);
        console2.log("remaining sell", sellLeft);
        console2.log("remaining mint", mintLeft);

        vm.stopBroadcast();
    }
}
