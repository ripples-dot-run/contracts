# v4-core provenance

The files under `src/` here are copied verbatim from Uniswap v4-core. Only the parts this
project imports are kept: the `interfaces`, `libraries`, and `types` directories. The pool
manager implementation, tests, scripts, and v4-core's own dependencies are not vendored,
which is why this is a copy rather than a submodule.

## Upstream

- Repository: https://github.com/Uniswap/v4-core
- Commit: `d9f8bfd39070b6114f2cf6c49df570fd6f998edb`
- Committed: 2025-04-22

Every vendored file matches its content in that commit exactly. The commit is the parent of
Uniswap v4-core #964 ("resolve circular dependency that breaks clean builds"), which is the
first upstream change to diverge from these files (it edits `IHooks.sol`, `IPoolManager.sol`,
and `Hooks.sol`).

## Vendored paths

Paths are relative to this directory.

```
src/interfaces/IExtsload.sol
src/interfaces/IExttload.sol
src/interfaces/IHooks.sol
src/interfaces/IPoolManager.sol
src/interfaces/IProtocolFees.sol
src/interfaces/callback/IUnlockCallback.sol
src/interfaces/external/IERC20Minimal.sol
src/interfaces/external/IERC6909Claims.sol
src/libraries/BitMath.sol
src/libraries/CurrencyDelta.sol
src/libraries/CurrencyReserves.sol
src/libraries/CustomRevert.sol
src/libraries/FixedPoint128.sol
src/libraries/FixedPoint96.sol
src/libraries/FullMath.sol
src/libraries/Hooks.sol
src/libraries/LPFeeLibrary.sol
src/libraries/LiquidityMath.sol
src/libraries/Lock.sol
src/libraries/NonzeroDeltaCount.sol
src/libraries/ParseBytes.sol
src/libraries/Pool.sol
src/libraries/Position.sol
src/libraries/ProtocolFeeLibrary.sol
src/libraries/SafeCast.sol
src/libraries/SqrtPriceMath.sol
src/libraries/StateLibrary.sol
src/libraries/SwapMath.sol
src/libraries/TickBitmap.sol
src/libraries/TickMath.sol
src/libraries/TransientStateLibrary.sol
src/libraries/UnsafeMath.sol
src/types/BalanceDelta.sol
src/types/BeforeSwapDelta.sol
src/types/Currency.sol
src/types/PoolId.sol
src/types/PoolKey.sol
src/types/Slot0.sol
```

## Re-verifying against upstream

Git blob hashes are content addresses, so a matching hash proves the file content is identical
byte for byte. To confirm every vendored file still matches the pinned commit, compare the blob
hash of each file against upstream's tree at that commit. From the repository root:

```sh
COMMIT=d9f8bfd39070b6114f2cf6c49df570fd6f998edb

# upstream: path -> blob hash, for the pinned commit
gh api "repos/Uniswap/v4-core/git/trees/$COMMIT?recursive=1" \
  --jq '.tree[] | select(.type=="blob") | "\(.path) \(.sha)"' | sort > /tmp/upstream.txt

# local: same, for the vendored files
git ls-files --stage contracts/lib/v4-core/ \
  | awk '{sub("contracts/lib/v4-core/","",$4); print $4" "$2}' | sort > /tmp/vendored.txt

# any output means a file drifted; no output means all match
join /tmp/vendored.txt /tmp/upstream.txt | awk '$2 != $3 { print "DRIFT:", $1 }'
```

A single file can also be checked directly:

```sh
diff <(gh api "repos/Uniswap/v4-core/contents/src/libraries/Pool.sol?ref=$COMMIT" \
        --jq '.content' | base64 -d) \
     contracts/lib/v4-core/src/libraries/Pool.sol
```

## Updating

To move to a newer v4-core, re-copy the same paths from the target commit, update the commit
hash and date above, re-run the verification, and run `forge build && forge test`.

## Licensing

This tree is not uniformly licensed and the SPDX header on each file is the authority. Thirty-three
files are MIT. Six are BUSL-1.1:

- `src/libraries/Pool.sol`
- `src/libraries/Position.sol`
- `src/libraries/Lock.sol`
- `src/libraries/CurrencyDelta.sol`
- `src/libraries/CurrencyReserves.sol`
- `src/libraries/NonzeroDeltaCount.sol`

`contracts/src/libraries/PoolDeployer.sol` imports `Pool.sol` for `tickSpacingToMaxLiquidityPerTick`,
so BUSL-licensed code is compiled into the deployed `PoolDeployer` library and into its verified
source. Anyone forking this repository takes those terms with those files. Keep the headers intact.

Ripples' own contracts under `contracts/src/` are MIT, and the repository's `LICENSE` covers them
alone.
