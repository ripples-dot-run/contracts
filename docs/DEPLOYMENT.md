# Deployment (contracts)

`ops/DEPLOY.md` is the runbook: chain order, keys, services, DNS, and smoke tests. This file
covers the contracts only, what `script/Deploy.s.sol` reads, and what to check on chain once it
lands.

The WETH migration changes immutable constructor bindings. Existing USDG deployments remain
historical records; they cannot be converted by changing an environment variable. Deploy a new
factory stack and point every client at its WETH, factory, and token-factory addresses together.

## Inputs

| Variable | Meaning |
| --- | --- |
| `TREASURY` | Receives launch fees and the protocol share of mint revenue |
| `PLATFORM_SIGNER` | Reveal-worker signer for one-shot LIVE token metadata; cannot launch or mint |
| `POOL_MANAGER` | Uniswap v4 PoolManager. Required on testnet. Mainnet is pinned to the canonical address; a different supplied value reverts `UnexpectedPoolManager` |
| `FACTORY_OWNER` | Next factory admin; defaults to the broadcasting sender |
| `WETH` | Payment-token override; leave unset on testnet to deploy `TestnetWETH` |
| `ALLOW_TESTNET_WETH_OVERRIDE` | Required acknowledgment before a supplied `WETH` can be used on 46630 |
| `TESTNET_WETH_OWNER` | Owner of a newly deployed `TestnetWETH`; defaults to `FACTORY_OWNER` |
| `TESTNET_FAUCET_OPERATOR` | Hot signer allowed to sponsor bounded faucet claims; may be `PLATFORM_SIGNER` and is required on 46630 when `WETH` is unset |
| `TESTNET_FAUCET_RESERVE` | Initial finite faucet reserve in 18-decimal token wei; defaults to 1,000,000 WETH |
| `GRADUATION_KEEPER` | Separately funded keeper address recorded with a 46630 deployment; must differ from `PLATFORM_SIGNER` |
| `ASSET_ORIGIN` | HTTPS origin serving collection documents, no trailing slash; required on 4663 and 46630 |
| `TOKEN_LAUNCH_FEE` | Token-rail launch fee in WETH wei; unset keeps the 0.0005 WETH contract default |
| `ALLOW_MAINNET_DEPLOY` | Must be `true` to broadcast on chain 4663 |
| `WRITE_DEPLOYMENTS` | Set `false` to stop even a broadcast run from updating `deployments.json` |
| `SOURCE_COMMIT` | Revision being deployed, recorded in `deployments.json`; required whenever the run writes the file. Use `SOURCE_COMMIT=$(git rev-parse HEAD)` |

`.env.example` lists the same set. On 4663 the payment token is pinned to canonical WETH
`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`; a supplied `WETH` must equal it. It has 18
decimals and the EIP-2612 domain `{ name: "WETH", version: "1" }` on chain 4663.

Canonical WETH is not assumed on 46630. With `WETH` unset, the script deploys an
access-controlled `TestnetWETH` with 18 decimals, EIP-2612 `permit`, and the domain
`{ name: "WETH", version: "1" }`. Supplying a token on 46630 instead requires
`ALLOW_TESTNET_WETH_OVERRIDE=true`; every factory and collection binds that address
immutably.

`TestnetWETH` keeps issuer actions (`mint`, `burn`, pause, and freeze) behind two-step
ownership. Its public faucet never mints: it transfers 1 WETH from a finite reserve and limits
each recipient to one claim per 24 hours. A wallet with testnet ETH calls `faucet()` directly.
The configured faucet operator calls `faucet(address)` for an authenticated embedded wallet.
Native testnet gas comes from the separate Robinhood faucet linked in the web app. The operator
may be the platform signer because it cannot mint, burn, pause, freeze, or bypass the recipient
cooldown. Keep the owner key off the API host.

`WETHSettlementRouter` remains available as a standalone primitive for applications that need
third-party settlement, but `Deploy.s.sol` does not deploy or configure it. The connected-wallet
flows call the factories and launched contracts directly.

Both factories publish `assetOrigin`, the origin their collections' ERC-7572 document is served
from. A collection reads it once at creation and keeps what it was born with, so `ASSET_ORIGIN`
is required on both Robinhood chains and the factory owner's later `setAssetOrigin` moves new
collections only. Both the deploy script and `setAssetOrigin` require an HTTPS origin with no
trailing slash, since a collection appends its own path and can never be corrected. On
`https://api.ripples.run` a collection's document is
`https://api.ripples.run/v1/collection-assets/<collection address>/contract.json`, with the
address lowercase.

A collection's owner can repoint that document at any time with `setContractURI`, including after
`freezeMetadata`. Freezing covers the artwork links every token resolves through, which is the
promise a collector holds; the collection document is the marketplace page beside them.

On 46630, `GRADUATION_KEEPER` is required deployment metadata. The deploy
script rejects a `GRADUATION_KEEPER` equal to `PLATFORM_SIGNER` before transaction recording
starts. The reveal signer and graduation keeper are independent funded services and must not
share a key or nonce stream.

## Sender

The deployer is whichever account forge broadcasts as (`--private-key`, `--account`,
`--keystore`, `--sender`). No environment variable overrides it. The broadcaster owns both
factories while the one-shot graduation hook is wired. If `FACTORY_OWNER` differs, the script
starts a two-step transfer and records both `owner` and `pendingOwner`; the recipient must call
`acceptOwnership`.

## deployments.json

Only a `--broadcast` run on 4663 or 46630 rewrites `deployments.json`. Simulations, fork
rehearsals, and `forge test` print the same JSON record to stdout and leave the file alone, so
the committed record always describes chain state that exists. Commit it after a real deploy.

Each new network record includes `weth` alongside the factories, hook, PoolManager, treasury,
signer, owner, and pending owner. It also carries the two things verification cannot recover
from the chain: `sourceCommit`, the revision the live bytecode was built from, and `libraries`,
the four deployer libraries the factories delegate to. The forge broadcast record holds both and
is not committed, so on any other machine `deployments.json` is the only source. A write replaces
a network's whole entry, which is why `SOURCE_COMMIT` is mandatory on a writing run.
A 46630 broadcast also writes the active token under
`weth["46630"]`, including its EIP-712 domain and, for `TestnetWETH`, its owner, faucet operator,
claim amount, cooldown, and reserve. Existing `usdg` records describe the legacy deployment and
must not be hand-edited into WETH records.

## Explorer verification

`script/verify.sh` recompiles from the working tree, so the sources have to be the ones the live
bytecode was built from. When `sourceCommit` is not the revision in hand, restore the sources and
only the sources:

```bash
git checkout <sourceCommit> -- src      # undo with: git checkout HEAD -- src
```

Checking the whole revision out would take `deployments.json` and `script/verify.sh` back with
it, and both carry fixes made after the deploy, including the library addresses the script reads.
The script compares `src/` against `sourceCommit` itself and prints the command when they differ.

Both factories delegate to linked libraries, and `forge script` links after compilation: it
deploys each library and patches the placeholders in bytecode solc has already emitted, so the
metadata hashed into the deployed bytes records no libraries. The script offers each factory that
same unlinked input first. If the verifier will not resolve the placeholders on its own, the
script retries with the recorded addresses, and says so. That second input carries the links in
its metadata, which changes its digest, so it can reach a partial match and never a full one.
A partial match on a factory after that retry is the expected result, not a failure.

## Pre-deploy verification

```bash
forge test
forge snapshot --check \
  --no-match-path 'test/*Fork.t.sol' \
  --no-match-test '^(testFuzz|invariant_)'
```

The fork suites (`test/*Fork.t.sol`) run against canonical WETH and the real 4663 PoolManager
through the `rh_mainnet` alias, overridable with `RH_MAINNET_RPC_URL`. With no reachable
endpoint they skip, so read the test counts. They are excluded from the gas snapshot because
their gas changes with upstream PoolManager state. Fuzz and invariant suites still run in the
test command, but their aggregate gas depends on runner scheduling even with a fixed seed, so
the snapshot tracks deterministic unit cases only.

## After deploy

Confirm on chain before announcing anything:

- `QUOTE()`, `treasury()`, `platformSigner()`, `owner()`, and `pendingOwner()` on both factories;
- `launchFee()` = `500000000000000` and `defaultProtocolFeeBps()` = 250 on the NFT factory;
- one end-to-end launch and mint through the connected-wallet paths;
- a LIVE-mode reveal, then `creatorWithdraw()` and `protocolWithdraw()` landing the expected
  split, with `protocolWithdraw()` paying the factory's current treasury.

Keep the platform signer rotatable: the factory owner can call `setPlatformSigner` on any
deployed collection, which is the recovery path if the reveal key is lost or leaked.

## PREGEN metadata lives at extensionless keys

`tokenURI` for a PREGEN drop returns `baseURI` concatenated with the decimal token id and
nothing else: no `.json`, no separator beyond whatever `baseURI` already ends with. Token 1
of a drop whose `baseURI` is `https://cdn.example/meta/<collection>/` resolves to
`https://cdn.example/meta/<collection>/1`.

Store each PREGEN token's metadata at the extensionless key
`meta/<collection>/<tokenId>` and serve it with `Content-Type: application/json`. Set
`baseURI` to that prefix with the trailing slash.
