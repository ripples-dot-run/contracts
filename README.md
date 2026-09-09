# Ripples contracts

Solidity source for the Ripples launchpad on Robinhood Chain, chain 4663. A launch creates a
fixed-supply token with a market built into it, and it can carry an NFT collection tied to that
market. This repository is the source those contracts were compiled from.

Ripples runs on Solana as well. That program is not in this repository.

## Deployed

| | |
| --- | --- |
| Token launch factory | [`0x149eB358fF19056c0952577fb248C7f7c861eCaF`](https://robinhoodchain.blockscout.com/address/0x149eB358fF19056c0952577fb248C7f7c861eCaF) |
| Launchpad factory | [`0x5136aBf2F4059E390459a7dc9FAD4b0859834894`](https://robinhoodchain.blockscout.com/address/0x5136aBf2F4059E390459a7dc9FAD4b0859834894) |
| Launch hook | [`0xaF59944A7d03B914567cb0272b7E588A7aE7AAC4`](https://robinhoodchain.blockscout.com/address/0xaF59944A7d03B914567cb0272b7E588A7aE7AAC4) |
| Quote registry | [`0x2BA6B82cD29Bf81DD26691Bd9625B0942527E9Ba`](https://robinhoodchain.blockscout.com/address/0x2BA6B82cD29Bf81DD26691Bd9625B0942527E9Ba) |
| Launch router | [`0x22DB9B2c6C6DB56ABC3fc196E4bC1FBb9c4338a6`](https://robinhoodchain.blockscout.com/address/0x22DB9B2c6C6DB56ABC3fc196E4bC1FBb9c4338a6) |
| Buyback burner | [`0xA206C88C69C241A8BdF02636b890E7573bFfC20f`](https://robinhoodchain.blockscout.com/address/0xA206C88C69C241A8BdF02636b890E7573bFfC20f) |

Verify deployed bytecode against the verified sources before trusting an address. The full record,
read live from the chain, is at [ripples.run/proof](https://ripples.run/proof).

Contract ownership is held by a Safe.

## How a launch works

A launch is a Uniswap v4 pool from its first trade. `LaunchHook` is the singleton hook every market
trades through: it prices the curve, charges the trade fee, and keeps the ledger each party is paid
from. `TokenLaunchFactory` validates a launch and checks the arithmetic of its supply before
anything is deployed. `LPLocker` holds the pool position and settles graduation, when the raise and
the reserved supply move into the permanent position and lock.

A combined launch adds `Collection721` and `AllocationVesting`. A share of every mint routes into
the token's market, capped at what the market still needs, and each mint records a claim on a share
of the supply reserved for minters, released after a cliff.

## Guardrails

Fixed at creation and immutable for the life of a market: the settlement asset, the funding target,
the trade fee, the creator's own charge, and the hook. No owner call reaches a market that already
exists.

Bounded on chain: the trade fee at 20% and the creator's charge at 10%, checked in both the factory
and the hook; the launch fee; the royalty at 10%; and the seed price band a launch must open inside.
The liquidity lock is permanent when a launch declares it so, refused independently by the locker
and the hook. Ownership is two-step throughout and `renounceOwnership` is disabled.

For the first three seconds of a launch a non-exempt buyer pays an opening tax that starts near the
whole trade and falls linearly to zero. It buys no tokens.

## Build

```
forge install
forge build
forge test
```

`foundry.toml` pins the compiler. `lib/v4-core/PROVENANCE.md` records which Uniswap commit the
vendored files came from and how to re-verify them.

Tests are not in this repository yet.

## Security

Report a suspected vulnerability privately to security@ripples.run before disclosing it anywhere
public. The organization's [security policy](https://github.com/ripples-dot-run/.github/blob/main/SECURITY.md)
has the detail.

## Licence

Ripples' contracts are MIT; see `LICENSE`. Vendored dependencies keep their upstream terms, which
are not all MIT. `lib/v4-core/PROVENANCE.md` names the six Uniswap files that are BUSL-1.1 and the
one Ripples library that compiles one of them in.
