#!/usr/bin/env bash
# Exercises script/verify.sh against stub `forge` and `cast` binaries, so the parts that cannot
# be re-run against a chain stay covered: that a factory is offered the unlinked input its
# deploy compiled before the linked one, where the library links come from when the broadcast
# directory is absent (it is gitignored, so this is the normal case on any other machine), which
# LPLocker constructor shape each deployed locker is verified with, and that a working tree the
# deployment was not built from is called out with a checkout that keeps this script.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
FAILED=0

STUB_HOME=$(mktemp -d)
trap 'rm -rf "$STUB_HOME"' EXIT
mkdir -p "$STUB_HOME/bin"

cat >"$STUB_HOME/bin/forge" <<'STUB'
#!/usr/bin/env bash
echo "forge $*" >>"$STUB_LOG"
# Blockscout cannot guess a child contract's arguments here, which is what pushes verify.sh
# onto the rebuild-from-immutables path this test is about.
case "$*" in *--guess-constructor-args*) exit 1 ;; esac
# A verifier that will not resolve library placeholders itself rejects the unlinked factory,
# which is the only thing that should send verify.sh to its linked retry.
if [ "${STUB_UNLINKED_OK:-1}" = "0" ]; then
  case "$*" in
    *Factory.sol:*) case "$*" in *--libraries*) ;; *) exit 1 ;; esac ;;
  esac
fi
exit 0
STUB

cat >"$STUB_HOME/bin/cast" <<'STUB'
#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$*" in
  *CREATOR_FEE_BPS*)
    [ "${STUB_LOCKER_SPLIT:-1}" = "1" ] || { echo "execution reverted" >&2; exit 1; }
    echo 5000 ;;
  *"HOOK()"*)
    [ "${STUB_LAUNCH_SHAPE:-pool}" = "pool" ] || { echo "execution reverted" >&2; exit 1; }
    echo 0x7777777777777777777777777777777777777777 ;;
  *totalOwed*)
    [ "${STUB_LOCKER_ESCROW:-1}" = "1" ] || { echo "execution reverted" >&2; exit 1; }
    echo 0 ;;
  *TOKEN_FACTORY*) echo 0x8888888888888888888888888888888888888888 ;;
  *NFT_FACTORY*) echo 0x9999999999999999999999999999999999999999 ;;
  *defaultQuote*) echo 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa ;;
  *feeToken*) echo 0xbBbBBBBbbBBBbbbBbbBbbbbbBBbBbbbbBbBbbBBb ;;
  *launchCount*) echo 1 ;;
  *collectionCount*) echo 1 ;;
  *allCollections*) echo 0xcccccccccccccccccccccccccccccccccccccccc ;;
  *allLaunches*) printf '0x1111111111111111111111111111111111111111\n0x2222222222222222222222222222222222222222\n0x3333333333333333333333333333333333333333\n0x4444444444444444444444444444444444444444\n' ;;
  "logs "*) echo '[]' ;;
  "abi-encode "*) echo 0xdeadbeef ;;
  *UNLOCK_AT*) echo 18446744073709551615 ;;
  *) echo 0x5555555555555555555555555555555555555555 ;;
esac
STUB

chmod +x "$STUB_HOME/bin/forge" "$STUB_HOME/bin/cast"

# 4663 is the only chain with a Blockscout instance, so it is the only one verify.sh will run for.
# `$6` picks which generation of `Launch` the stubbed factory answers with: `pool` is
# {token, locker, hook, creator} and `curve` is the pre-pool {token, curve, locker, creator}.
# verify.sh tells them apart by asking the second address whether it answers `HOOK()`, so that is
# the read the stub gates.
run_verify() {
  STUB_LOG="$1" STUB_LOCKER_SPLIT="$2" STUB_UNLINKED_OK="${3:-1}" \
    STUB_LOCKER_ESCROW="${4:-1}" DEPLOYMENTS="${5:-$ROOT/deployments.json}" \
    STUB_LAUNCH_SHAPE="${6:-pool}" \
    PATH="$STUB_HOME/bin:$PATH" \
    RPC_URL=http://stub \
    TOKEN_FACTORY=0x6666666666666666666666666666666666666666 \
    "$ROOT/script/verify.sh" 4663 0x7777777777777777777777777777777777777777 \
    >"$1.out" 2>"$1.err" || true
}

# Historical generations use explicit fixtures so a new production deployment cannot silently
# change what the legacy tests exercise. Current-generation checks still read deployments.json.
v1_record() {
  jq '.robinhoodMainnet
      | del(.quoteRegistry, .stockLinkRegistry, .launchRouter)
      | .libraries = {
          CollectionDeployer: "0x1111111111111111111111111111111111111111",
          LaunchDeployer: "0x2222222222222222222222222222222222222222",
          LockerDeployer: "0x3333333333333333333333333333333333333333",
          VestingDeployer: "0x4444444444444444444444444444444444444444"
        }
      | { robinhoodMainnet: . }' "$ROOT/deployments.json" >"$1"
}

v2_record() {
  jq '.robinhoodMainnet
      + { quoteRegistry: "0xQR", stockLinkRegistry: "0xSL" }
      + { libraries: (.robinhoodMainnet.libraries + { TokenDeployer: "0xTD" }) }
      | { robinhoodMainnet: . }
      | .robinhoodMainnet.chainId = 4663' "$v1_fixture" >"$1"
}

# A record whose commission rail is deployed. Both keys are null on every committed record until
# the first `DeployWorkSplit` run, so the filled shape needs a fixture of its own.
work_record() {
  jq --arg scout "$2" '.robinhoodMainnet
      + { workSplitFactory: "0xWS", scoutRegistry: $scout }
      | { robinhoodMainnet: . }' "$ROOT/deployments.json" >"$1"
}

expect() {
  local label="$1" log="$2" pattern="$3"
  if grep -qF -- "$pattern" "$log"; then return 0; fi
  echo "FAIL: $label" >&2
  echo "  expected to find: $pattern" >&2
  FAILED=1
}

refute() {
  local label="$1" log="$2" pattern="$3"
  if ! grep -qF -- "$pattern" "$log"; then return 0; fi
  echo "FAIL: $label" >&2
  echo "  expected not to find: $pattern" >&2
  FAILED=1
}

split_log="$STUB_HOME/split.log"
run_verify "$split_log" 1

# The deploy compiled its factories unlinked and patched the placeholders afterwards, so its
# metadata records no libraries. A --libraries flag on the accepted attempt would put them back
# into the metadata and cost the full match.
refute "a factory the verifier accepts is never sent library links" "$split_log" \
  "src/LaunchpadFactory.sol:LaunchpadFactory --constructor-args 0xdeadbeef --libraries"
refute "the token factory the verifier accepts is never sent library links" "$split_log" \
  "src/TokenLaunchFactory.sol:TokenLaunchFactory --constructor-args 0xdeadbeef --libraries"

# Each library is still verified in its own right, from the address deployments.json records.
for name in $(jq -r ' .robinhoodMainnet.libraries | keys[]' "$ROOT/deployments.json"); do
  addr=$(jq -r --arg n "$name" '.robinhoodMainnet.libraries[$n]' "$ROOT/deployments.json")
  [ "$addr" != "null" ] || { echo "FAIL: deployments.json records no $name for 4663" >&2; FAILED=1; continue; }
  expect "$name is itself verified" "$split_log" "$addr src/libraries/$name.sol:$name"
done

# A verifier that will not resolve the placeholders gets the linked input instead, from the same
# recorded addresses, with the partial match spelled out.
linked_log="$STUB_HOME/linked.log"
run_verify "$linked_log" 1 0

for name in $(jq -r ' .robinhoodMainnet.libraries | keys[]' "$ROOT/deployments.json"); do
  addr=$(jq -r --arg n "$name" '.robinhoodMainnet.libraries[$n]' "$ROOT/deployments.json")
  [ "$addr" != "null" ] || continue
  expect "$name is linked from deployments.json on the retry" "$linked_log" \
    "--libraries src/libraries/$name.sol:$name:$addr"
done
expect "the retry is called what it is" "$linked_log.err" "can only be a partial match"
expect "both factories are retried" "$linked_log" \
  "src/LaunchpadFactory.sol:LaunchpadFactory --constructor-args 0xdeadbeef --libraries"

# A path-limited checkout is the instruction: taking the whole revision would undo this script
# and the deployment record, which is where the library addresses and these fixes live. Which
# way this goes depends on the tree the test runs in, so ask git the same question verify.sh
# asks. An unknown commit (a shallow clone) also counts as a tree that has to be warned about.
source_commit=$(jq -r '.robinhoodMainnet.sourceCommit' "$ROOT/deployments.json")
if git -C "$ROOT" diff --quiet "$source_commit" -- src 2>/dev/null; then
  refute "sources already at the deployed revision are not warned about" \
    "$split_log.err" "$source_commit"
else
  expect "the deployed revision is named" "$split_log.err" "$source_commit"
  expect "only the sources are checked out" "$split_log.err" "git checkout $source_commit -- src"
  if grep -qE "git checkout $source_commit *\$" "$split_log.err"; then
    echo "FAIL: the warning still offers a whole-revision checkout" >&2
    FAILED=1
  fi
fi

expect "a pool-generation locker verifies with the nine-argument constructor" \
  "$split_log" \
  "abi-encode c(address,address,address,address,address,address,address,uint96,uint64)"
expect "and the launch hook is verified as the singleton it is" \
  "$split_log" "src/hook/LaunchHook.sol:LaunchHook"

expect "a locker carrying the pull escrow is probed for it and says so" \
  "$split_log.err" "carries the pull escrow"

no_escrow_log="$STUB_HOME/no-escrow.log"
run_verify "$no_escrow_log" 1 1 0
expect "a locker from before the escrow is called out rather than assumed" \
  "$no_escrow_log.err" "predates the pull escrow"

# Both `CollectionCreated` shapes are asked for. A v2 factory emits the twelve-field tuple and a
# v1 one the eleven-field tuple, and filtering for a single topic finds nothing on the other
# generation, which reads as a collection with no creation log, not as a bug.
expect "the v2 CollectionCreated tuple is asked for first" "$split_log" \
  "CollectionCreated(address,address,(string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96,address))"
expect "and the v1 tuple is the fallback" "$split_log" \
  "CollectionCreated(address,address,(string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96)) --json"

# A v1 record links four libraries and names no registries; nothing here may invent a fifth.
v1_fixture="$STUB_HOME/deployments-v1.json"
v1_record "$v1_fixture"
v1_log="$STUB_HOME/v1.log"
run_verify "$v1_log" 1 1 1 "$v1_fixture" curve
refute "a v1 record is not asked for TokenDeployer" "$v1_log" \
  "src/libraries/TokenDeployer.sol:TokenDeployer"
expect "and the absent quote registry is called out, not silently skipped" "$v1_log.err" \
  "no quoteRegistry in the record"
expect "and so is the absent stock link registry" "$v1_log.err" \
  "no stockLinkRegistry in the record"

v2_fixture="$STUB_HOME/deployments-v2.json"
v2_record "$v2_fixture"
v2_log="$STUB_HOME/v2.log"
run_verify "$v2_log" 1 1 1 "$v2_fixture"

expect "the fifth deployer library is verified on a v2 record" "$v2_log" \
  "0xTD src/libraries/TokenDeployer.sol:TokenDeployer"
expect "the quote registry verifies with its three-address constructor" "$v2_log" \
  "abi-encode c(address,address,address)"
expect "the quote registry itself is verified" "$v2_log" \
  "0xQR src/QuoteRegistry.sol:QuoteRegistry"
expect "the stock link registry verifies with its two-address constructor" "$v2_log" \
  "abi-encode c(address,address) 0x8888888888888888888888888888888888888888 0x9999999999999999999999999999999999999999"
expect "the stock link registry itself is verified" "$v2_log" \
  "0xSL src/StockLinkRegistry.sol:StockLinkRegistry"
v2_linked_log="$STUB_HOME/v2-linked.log"
run_verify "$v2_linked_log" 1 0 1 "$v2_fixture"
expect "and the token rail's linked retry carries all five libraries" "$v2_linked_log" \
  "--libraries src/libraries/TokenDeployer.sol:TokenDeployer:0xTD"

# A v2 record that forgot the new library is the one failure nothing on chain could recover
# from: a library address exists in no place but this file.
missing_lib="$STUB_HOME/deployments-missing-lib.json"
jq 'del(.robinhoodMainnet.libraries.TokenDeployer)' "$v2_fixture" >"$missing_lib"
missing_log="$STUB_HOME/missing-lib.log"
run_verify "$missing_log" 1 1 1 "$missing_lib"
expect "a v2 record missing a deployer library is refused" "$missing_log.err" \
  "a v2 record must name all five deployer libraries"

# The commission rail. A scout holds an artist to a published rate by reading the contract that
# enforces it, so an unverified WorkSplitFactory is a rate nobody can check. Neither key is filled
# on any network yet, so the committed record must say so rather than report full coverage.
expect "an unrecorded commission rail is called out, not silently skipped" "$split_log.err" \
  "no workSplitFactory in the record"

work_fixture="$STUB_HOME/deployments-work.json"
work_record "$work_fixture" 0x5555555555555555555555555555555555555555
work_log="$STUB_HOME/work.log"
run_verify "$work_log" 1 1 1 "$work_fixture"

expect "the work split factory verifies with its one-address constructor" "$work_log" \
  "abi-encode c(address) 0x8888888888888888888888888888888888888888"
expect "the work split factory itself is verified" "$work_log" \
  "0xWS src/WorkSplitFactory.sol:WorkSplitFactory"
# The registry is created by CREATE inside the factory's constructor, so it has no creation
# transaction: the guess is tried first and the rebuild uses its one immutable.
expect "and the scout registry is verified from its own immutable" "$work_log" \
  "0x5555555555555555555555555555555555555555 src/ScoutRegistry.sol:ScoutRegistry --constructor-args"

# The record and the factory disagree about the registry only if the record was edited by hand.
# The address the splits actually read is the factory's, and the record's is named as the error.
mismatch_fixture="$STUB_HOME/deployments-work-mismatch.json"
work_record "$mismatch_fixture" 0x1234567890123456789012345678901234567890
mismatch_log="$STUB_HOME/work-mismatch.log"
run_verify "$mismatch_log" 1 1 1 "$mismatch_fixture"
expect "a record naming the wrong scout registry is reported" "$mismatch_log.err" \
  "scoutRegistry in the record is 0x1234567890123456789012345678901234567890"
expect "and the registry the factory names is the one verified" "$mismatch_log" \
  "0x5555555555555555555555555555555555555555 src/ScoutRegistry.sol:ScoutRegistry"

# The pre-pool generation remains covered independently of the current deployment. Its sources come back with a
# path-limited checkout of the network's `sourceCommit`, as the header of verify.sh says, so
# these branches have to keep working.
curve_log="$STUB_HOME/curve.log"
run_verify "$curve_log" 1 1 1 "$v1_fixture" curve
expect "a curve-generation locker verifies with the seven-argument constructor" \
  "$curve_log" "abi-encode c(address,address,address,address,address,uint96,uint64)"
expect "and its curve is verified beside it" "$curve_log" "src/BondingCurve.sol:BondingCurve"

legacy_log="$STUB_HOME/legacy.log"
run_verify "$legacy_log" 0 1 1 "$v1_fixture" curve

expect "a locker from before the split verifies with the five-argument constructor" \
  "$legacy_log" "abi-encode c(address,address,address,address,uint64)"
expect "the older shape is called out" "$legacy_log.err" "predates the creator fee split"

if [ "$FAILED" -ne 0 ]; then
  echo "verify.sh checks failed" >&2
  exit 1
fi
echo "verify.sh checks passed"
