#!/usr/bin/env bash
# Holds the agent and combined Dual Fill contracts to the ABI the API, the opener, the SDK and the
# web hard-code (docs/plans/dual-fill-agents/interfaces.md §5.6 and §7.2.4). Each consumer writes
# its own `parseAbi` from those signatures, so a function, event or error that drifts here reaches
# them as four bytes nobody decodes rather than as a compile error.
#
#   script/check-dual-fill-shapes-abi.sh
#
# Each contract must expose exactly its interface's functions and events. Its errors are the
# interface's plus, at most, the two its libraries raise. Every pinned selector, topic and error
# id below must be present with the value shown, and the combined pair must answer every other
# selector, topic and error of the token pair with the same value. The combined pair's suites must
# carry a same-named counterpart of every token pair suite's test, and none of the agent or
# combined contracts, scripts or suites may compile with a warning. Exits non-zero on any
# difference.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

LP='(string,string,uint256,uint256,uint256,uint256,uint256,uint64,uint96,address,string,string,string,string,string,string,string)'
CH='(address,uint128,uint128,uint128,uint32,address[])'
FT='(bytes32,uint256,uint64,uint64,bool,uint256)'
CP='(string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96,address)'
LKP='(uint96,uint96,uint64,uint64,bool,bool)'
LIBRARY_ERRORS=$'ReentrancyGuardReentrantCall()\nSafeERC20FailedOperation(address)'

INSPECTED=$(mktemp -d)
trap 'rm -rf "$INSPECTED"' EXIT

# macOS still ships bash 3.2, which has no associative arrays, so each answer is kept in a file.
for contract in DualFillAgentFactory IDualFillAgentFactory DualFillAgentTreasury \
  IDualFillAgentTreasury LinkedDualFillFactory ILinkedDualFillFactory LinkedDualFill \
  ILinkedDualFill DualFillFactory DualFill; do
  for field in methodIdentifiers events errors; do
    forge inspect "$contract" "$field" --json 2>/dev/null >"$INSPECTED/$contract.$field"
  done
done
for suite in DualFillTest LinkedDualFillTest DualFillAdversarialTest LinkedDualFillAdversarialTest \
  DualFillInvariant LinkedDualFillInvariant; do
  forge inspect "$suite" methodIdentifiers --json 2>/dev/null >"$INSPECTED/$suite.methodIdentifiers"
done

signatures() { jq -r 'keys[]' "$INSPECTED/$1.$2" | LC_ALL=C sort; }

compare_exact() {
  local contract="$1" interface="$2" field="$3" got want
  got=$(signatures "$contract" "$field")
  want=$(signatures "$interface" "$field")
  if [ "$got" != "$want" ]; then
    fail "$contract $field differ from $interface"
    diff <(echo "$want") <(echo "$got") >&2 || true
  fi
}

compare_errors() {
  local contract="$1" interface="$2" got want missing extra
  got=$(signatures "$contract" errors)
  want=$(signatures "$interface" errors)
  missing=$(LC_ALL=C comm -23 <(echo "$want") <(echo "$got"))
  extra=$(LC_ALL=C comm -13 <(echo "$want") <(echo "$got") \
    | LC_ALL=C comm -23 - <(LC_ALL=C sort <<<"$LIBRARY_ERRORS"))
  [ -z "$missing" ] || fail "$contract is missing $interface errors: $(echo $missing)"
  [ -z "$extra" ] || fail "$contract raises errors outside $interface: $(echo $extra)"
}

for pair in DualFillAgentFactory:IDualFillAgentFactory DualFillAgentTreasury:IDualFillAgentTreasury \
  LinkedDualFillFactory:ILinkedDualFillFactory LinkedDualFill:ILinkedDualFill; do
  compare_exact "${pair%%:*}" "${pair##*:}" methodIdentifiers
  compare_exact "${pair%%:*}" "${pair##*:}" events
  compare_errors "${pair%%:*}" "${pair##*:}"
done

# forge names a struct argument of an event by its type rather than spelling out the tuple, so an
# event is found by name and the topic, which hashes the full tuple, is what is compared.
topic_of() {
  jq -r --arg n "$2" 'to_entries[] | select((.key | split("(")[0]) == $n) | .value' \
    "$INSPECTED/$1.events"
}

# Every selector, topic and error the token pair answers, the combined pair answers identically.
# `createFill`, `CURVE_SUPPLY` and `open` are the ones §7.2.2 replaces.
while read -r signature; do
  case "$signature" in createFill\(*|CURVE_SUPPLY\(\)) continue ;; esac
  want=$(jq -r --arg s "$signature" '.[$s]' "$INSPECTED/DualFillFactory.methodIdentifiers")
  got=$(jq -r --arg s "$signature" '.[$s] // empty' "$INSPECTED/LinkedDualFillFactory.methodIdentifiers")
  [ "$got" = "$want" ] || fail "LinkedDualFillFactory $signature is ${got:-absent}, DualFillFactory's is $want"
done < <(signatures DualFillFactory methodIdentifiers)
while read -r signature; do
  case "$signature" in open\(*) continue ;; esac
  want=$(jq -r --arg s "$signature" '.[$s]' "$INSPECTED/DualFill.methodIdentifiers")
  got=$(jq -r --arg s "$signature" '.[$s] // empty' "$INSPECTED/LinkedDualFill.methodIdentifiers")
  [ "$got" = "$want" ] || fail "LinkedDualFill $signature is ${got:-absent}, DualFill's is $want"
done < <(signatures DualFill methodIdentifiers)
for kind in DualFill:LinkedDualFill DualFillFactory:LinkedDualFillFactory; do
  token="${kind%%:*}" linked="${kind##*:}"
  while read -r signature; do
    name="${signature%%(*}"
    [ "$token:$name" = "DualFillFactory:FillCreated" ] && continue
    want=$(topic_of "$token" "$name")
    got=$(topic_of "$linked" "$name")
    [ "$got" = "$want" ] || fail "$linked event $name is ${got:-absent}, $token's is $want"
  done < <(signatures "$token" events)
  while read -r signature; do
    want=$(jq -r --arg s "$signature" '.[$s]' "$INSPECTED/$token.errors")
    got=$(jq -r --arg s "$signature" '.[$s] // empty' "$INSPECTED/$linked.errors")
    [ "$got" = "$want" ] || fail "$linked error $signature is ${got:-absent}, $token's is $want"
  done < <(signatures "$token" errors)
done

# <contract> <field> <signature> <value>. Error pins are looked up on every contract of their
# pair, because §5.6 and §7.2.4 list them once for the pair.
PINS=$(cat <<EOF
DualFillAgentFactory methodIdentifiers createAndFill($CH,$LP,$FT,uint256) 2b2b70bc
DualFillAgentFactory methodIdentifiers treasuryOf(address,bytes32) 9edb32bd
DualFillAgentFactory methodIdentifiers isFromFactory(address) 2e2ecd8d
DualFillAgentFactory methodIdentifiers treasuryCount() c0d10bd3
DualFillAgentFactory methodIdentifiers treasuries(uint256,uint256) 36169483
DualFillAgentFactory methodIdentifiers MAX_PER_CALL_RESERVE_BPS() ea7fea10
DualFillAgentFactory methodIdentifiers MAX_DAILY_RESERVE_BPS() 7e226779
DualFillAgentFactory methodIdentifiers DUAL_FILL_FACTORY() ec86c4dd
DualFillAgentFactory methodIdentifiers LAUNCH_FACTORY() b4461ec8
DualFillAgentFactory methodIdentifiers RUNWAY_ASSET() 17823f40
DualFillAgentFactory methodIdentifiers NATIVE_WRAP() 6c5601ac
DualFillAgentFactory methodIdentifiers ROUTER() 32fe7b26
DualFillAgentFactory methodIdentifiers PERMIT2() 6afdd850
DualFillAgentFactory methodIdentifiers FEE_TOKEN() 73717b08
DualFillAgentFactory methodIdentifiers quoteOf(address) cab1ef67
DualFillAgentTreasury methodIdentifiers startFill($LP,$FT) 4c94a380
DualFillAgentTreasury methodIdentifiers bind() 62358aad
DualFillAgentTreasury methodIdentifiers buy(uint256,uint256,uint256) 40993b26
DualFillAgentTreasury methodIdentifiers sell(uint256,uint256,uint256) d3c9727c
DualFillAgentTreasury methodIdentifiers pay(address,uint256) c4076876
DualFillAgentTreasury methodIdentifiers note(bytes32,string) 4ae34e3d
DualFillAgentTreasury methodIdentifiers claimFees() d294f093
DualFillAgentTreasury methodIdentifiers cancelFill() 9ee6a018
DualFillAgentTreasury methodIdentifiers retireOperator() d0d899a8
DualFillAgentTreasury methodIdentifiers returnRunway() 4e026337
DualFillAgentTreasury methodIdentifiers returnBond() 8a05a751
DualFillAgentTreasury methodIdentifiers charter() c1aadb4d
DualFillAgentTreasury methodIdentifiers remainingToday() fc3c5515
DualFillAgentTreasury methodIdentifiers sellableTokens() 808bcddc
DualFillAgentTreasury methodIdentifiers payees() 4e8086aa
DualFillAgentTreasury methodIdentifiers fill() d9c55ce1
DualFillAgentTreasury methodIdentifiers token() fc0c546a
DualFillAgentTreasury methodIdentifiers locker() d7b96d4e
DualFillAgentTreasury methodIdentifiers boughtTokens() 582c6d70
DualFillAgentTreasury methodIdentifiers isPayee(address) 366653a9
DualFillAgentTreasury methodIdentifiers retired() 2eb38ae0
DualFillAgentTreasury methodIdentifiers CREATOR() e4fbb609
DualFillAgentTreasury methodIdentifiers AGENT_FACTORY() 26cdf834
DualFillAgentTreasury methodIdentifiers OPERATOR() 983d2737
DualFillAgentTreasury methodIdentifiers QUOTE() 9c579839
DualFillAgentTreasury methodIdentifiers FEE_TOKEN() 73717b08
DualFillAgentTreasury methodIdentifiers FILL_FACTORY() b1c26c0b
DualFillAgentTreasury methodIdentifiers DUAL_FILL_KEY() 0e8ceacc
DualFillAgentTreasury methodIdentifiers DAILY_SPEND() 6011cbd1
DualFillAgentTreasury methodIdentifiers PER_CALL_SPEND() e5f63764
DualFillAgentTreasury methodIdentifiers DAILY_SELL() 6c6768ca
DualFillAgentTreasury methodIdentifiers MAX_PAYEES() 5ecc86e8
DualFillAgentFactory events AgentDualFillCreated(address,address,address,address,bytes32,uint256) 0xebe6fc7218fc60683b8bbe69d8e4e6b14dcd8ce8b6c1379426f7fc07e0425bd9
DualFillAgentTreasury events FillStarted(address,bytes32,uint256) 0x033bda7bf11fdf18549a1f433edc81b9d5822672d5b69dc6e6c4e057a4251640
DualFillAgentTreasury events Bound(address,address) 0x0d128562eaa47ab89086803e64a0f96847c0ed3cc63c26251f29ba1aede09d4e
DualFillAgentTreasury events FillCancelled(address) 0x5924e8f5c663cbf9d94e93dabad9ac7323f82cfe85069dc40c4ac75df47cf2a4
DualFillAgentTreasury events RunwayReturned(address,uint256) 0x796a3a10564d81bea438b8ea0d5c4f97140ef425a506ccfc6366d57b3a46e93d
DualFillAgentTreasury events BondReturned(address,uint256) 0x9347cad0e396dd77ea84d092d0e565cf227a1672e5981022e22c07d8d09e12bc
DualFillAgentTreasury events Bought(uint256,uint256) 0x3ccb2ab6980b218b1dd4974b07365cd90a191e170c611da46262fecc208bd661
DualFillAgentTreasury events Sold(uint256,uint256) 0x7ea63cabf285309a7f2750def3e745dd81fc85e39926c5b47f0bd45938e1a412
DualFillAgentTreasury events Paid(address,uint256) 0x737c69225d647e5994eab1a6c301bf6d9232beb2759ae1e27a8966b4732bc489
DualFillAgentTreasury events FeesClaimed(uint256,uint256) 0xa1f87f32d0f17fab0242ca800d736293de8988c14b27747e218cf13d5c249f53
DualFillAgentTreasury events Noted(bytes32,string) 0xd4d08a94163d1e1ffbf270c31a57b5f1502d91abcd6ac037e0b62cc5af7e4aef
DualFillAgentTreasury events OperatorRetired() 0xa68770f5e7c6c8b6662c89b74137de3ebddabd56f9d487ce9d8ea60e0bab4a8a
agent errors TreasuryExists() e9af3456
agent errors MintUnavailable() 93898ab0
agent errors CharterAboveCap() 1e86ded2
agent errors NoRunway() cafac1b7
agent errors WrongPayment() 788a686f
agent errors NativeUnsupported() 73a5e3bb
agent errors QuoteMismatch() 3acea3d4
agent errors NotCreator() 93687c0b
agent errors NotOperator() 7c214f04
agent errors NotAgentFactory() 7d4dfb46
agent errors AlreadyStarted() 1fbde445
agent errors NotOpened() 6d36408a
agent errors NotRefundable() 3742d1f6
agent errors NothingToReturn() 88edfc11
agent errors FillMismatch() 024a319c
agent errors NoVenue() c186028c
agent errors InvalidSpendLimits() 47eb19a4
agent errors CreatorInCharter() 622ea923
agent errors OverDailySpend(uint256,uint256) 968e68bf
agent errors OverCallSpend(uint256,uint256) df44ea3b
agent errors OverDailySell(uint256,uint256) f1aa3abd
agent errors SellsIncomeOnly(uint256,uint256) 2e8e868c
agent errors NotPayee(address) 525d8c80
agent errors SnipeWindowOpen() 26c60d47
agent errors Retired() c15f68f0
agent errors AlreadyRetired() 0ac03ea0
agent errors UnexpectedBalance() c7a4cf10
LinkedDualFillFactory methodIdentifiers createFill($LP,$CP,$LKP,bytes32,uint256,uint64,uint64,bool,uint256) dc535e9c
LinkedDualFillFactory methodIdentifiers curveSupplyFor(uint96) db7bc409
LinkedDualFillFactory methodIdentifiers TOTAL_SUPPLY() 902d55a5
LinkedDualFillFactory methodIdentifiers LP_SUPPLY() 670171fd
LinkedDualFillFactory methodIdentifiers V_TOKEN_INIT() 34ef3499
LinkedDualFillFactory methodIdentifiers MAX_NFT_ALLOCATION_BPS() f20a3128
LinkedDualFillFactory methodIdentifiers MAX_ROYALTY_BPS() 3dca40e6
LinkedDualFillFactory methodIdentifiers MAX_URI_BYTES() 718a60ee
LinkedDualFillFactory methodIdentifiers MAX_PIECES() 93e136da
LinkedDualFill methodIdentifiers open($LP,$CP,$LKP) ec855e89
LinkedDualFill methodIdentifiers collection() 7de1e536
LinkedDualFill methodIdentifiers vesting() 44c63eec
LinkedDualFill methodIdentifiers DUAL_FILL_KEY() 0e8ceacc
LinkedDualFillFactory events FillCreated(address,address,bytes32,uint256,uint64,uint64,bool,uint256,bytes32,$LP,$CP,$LKP) 0x3f5bfa35fd1339f5fb34156fdedbd6866ad2474437afb17b271e113136c28ccf
LinkedDualFill events CollectionOpened(address,address) 0x2b23f7c6fc26148cee31ca8edf5b8e65c5d38af84c2e194d0366d330db459a7c
LinkedDualFill events Opened(address,address,bytes32,address,uint256,uint256,uint256) 0xf849d2586cabd9983f79f1db336a8684e1489b070cefc38d37db4d37858eff0e
linked errors InvalidCollection() a2e2e542
linked errors InvalidCoupling() c693be1a
linked errors OpenAloneRefused() 069db3b4
linked errors InvalidDualFillKey() 14b49c8d
linked errors SupplyMismatch() f6beef52
linked errors EconomicsMismatch() 42889d84
linked errors QuoteDecimalsMismatch() 17b41e76
EOF
)

while read -r contract field signature value; do
  if [ "$contract" = agent ] || [ "$contract" = linked ]; then
    pair=DualFillAgentFactory.errors
    other=DualFillAgentTreasury.errors
    if [ "$contract" = linked ]; then pair=LinkedDualFillFactory.errors other=LinkedDualFill.errors; fi
    got=$(jq -rs --arg s "$signature" '(.[0] + .[1])[$s] // empty' \
      "$INSPECTED/$pair" "$INSPECTED/$other")
  elif [ "$field" = events ]; then
    got=$(topic_of "$contract" "${signature%%(*}")
  else
    got=$(jq -r --arg s "$signature" '.[$s] // empty' "$INSPECTED/$contract.$field")
  fi
  [ "$got" = "$value" ] || fail "$contract $signature is ${got:-absent}, pinned $value"
done <<<"$PINS"

# §7.2.6: a same-named counterpart of every token pair test, in the suite of the same kind.
tests() { jq -r 'keys[] | select(test("^(test|invariant)"))' "$INSPECTED/$1.methodIdentifiers" | LC_ALL=C sort; }
for suites in DualFillTest:LinkedDualFillTest DualFillAdversarialTest:LinkedDualFillAdversarialTest \
  DualFillInvariant:LinkedDualFillInvariant; do
  token="${suites%%:*}" linked="${suites##*:}"
  echo "$token: $(tests "$token" | wc -l | tr -d ' ') tests; $linked: $(tests "$linked" | wc -l | tr -d ' ')"
  missing=$(LC_ALL=C comm -23 <(tests "$token") <(tests "$linked"))
  [ -z "$missing" ] || fail "$linked has no counterpart of: $(echo $missing)"
done

# forge prints a file's warnings only in the run that compiles it, and the inspections above may
# have read every artifact from the cache, so these files are compiled again from nothing. A
# warning counts when it points into one of them, not into something they import.
SOURCES=(
  src/{DualFillAgentFactory,DualFillAgentTreasury,LinkedDualFillFactory,LinkedDualFill}.sol
  src/interfaces/I{DualFillAgentFactory,DualFillAgentTreasury,LinkedDualFillFactory,LinkedDualFill}.sol
  src/libraries/{DualFillAgentTreasuryDeployer,LinkedDualFillDeployer}.sol
  script/{DeployDualFillAgent,DeployLinkedDualFill,RehearseDualFillShapes}.s.sol
  test/{DualFillAgent,LinkedDualFill}{,Adversarial,Invariant,Fork,TestnetFork}.t.sol
  test/Deploy{DualFillAgent,LinkedDualFill}Script.t.sol
)
if forge build --no-lint --out "$INSPECTED/out" --cache-path "$INSPECTED/cache" "${SOURCES[@]}" \
  >"$INSPECTED/build" 2>&1; then
  if grep -q 'with warnings' "$INSPECTED/build" && ! grep -q '^Warning (' "$INSPECTED/build"; then
    fail "forge reported warnings in a form this script does not read"
  fi
  while read -r location warning; do
    case " ${SOURCES[*]} " in *" ${location%%:*} "*) fail "$location $warning" ;; esac
  done < <(awk '
    /^Warning \(/ { warning = $0; next }
    warning != "" && /^ *--> / { sub(/^ *--> */, ""); print $0, warning }
    { warning = "" }
  ' "$INSPECTED/build")
else
  cat "$INSPECTED/build" >&2
  fail "the agent and combined Dual Fill sources do not compile"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "Dual Fill shapes do not match their pins or compile with warnings" >&2
  exit 1
fi
echo "Dual Fill shapes match their interfaces and every pin, and compile without warnings"
