# What is in this directory

Production contracts, and a few that are not. Nothing here is deployed to mainnet unless
`contracts/deployments.json` names its address.

## Production

The launchpad: `TokenLaunchFactory`, `LaunchpadFactory`, `QuoteRegistry`, `LaunchLens`, and the
singleton `hook/LaunchHook` that every market trades through. What a launch creates: `AgentToken`,
`Collection721`, `LPLocker`, `AllocationVesting`. Trading and settlement: `LaunchRouter`,
`WETHSettlementRouter`. The buyback: `BuybackBurner` and `UniswapV4Venue`. The deploy-time helpers
in `libraries/` exist because the factories would otherwise exceed the 24,576-byte contract limit.

## Not production

`TestnetWETH`, `TestnetStockToken` and `TestWETHBase` are test networks only. `TestnetWETH` is the
settlement asset on Robinhood Chain's test network, 46630, and is recorded there; it is not on
mainnet and is not a wrapped ether anyone should hold.

`tt/` is throwaway probe code, used once to prove a hook address could be mined and a pool opened
against a live node. It is deployed to no network, recorded in no deployment file, and mints a
token named for what it is. It is kept because the probe is worth repeating on a new chain.

## Reading order

`hook/LaunchHook.sol` is where the money moves: it prices every trade, charges the fee, and holds
the ledger a launch is paid from. `TokenLaunchFactory.sol` is where a launch is validated and the
arithmetic of its supply is checked. Everything else follows from those two.
