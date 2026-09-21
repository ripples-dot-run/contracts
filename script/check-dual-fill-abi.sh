#!/usr/bin/env bash
# Holds the compiled Dual Fill contracts to the ABI the API, the opener and the web hard-code
# (docs/plans/dual-fill/interfaces.md §2.6). Each consumer writes its own `parseAbi` from those
# signatures, so a function, event or error that drifts here reaches them as four bytes nobody
# decodes rather than as a compile error.
#
#   script/check-dual-fill-abi.sh
#
# Each contract must expose exactly its interface's functions and events. Its errors are the
# interface's plus, at most, the two its libraries raise. Every pinned selector and topic below
# must be present with the value shown. Exits non-zero on any difference.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }

LP='(string,string,uint256,uint256,uint256,uint256,uint256,uint64,uint96,address,string,string,string,string,string,string,string)'
LIBRARY_ERRORS=$'ReentrancyGuardReentrantCall()\nSafeERC20FailedOperation(address)'

INSPECTED=$(mktemp -d)
trap 'rm -rf "$INSPECTED"' EXIT

# macOS still ships bash 3.2, which has no associative arrays, so each answer is kept in a file.
for contract in DualFillFactory IDualFillFactory DualFill IDualFill TokenLaunchFactory; do
  for field in methodIdentifiers events errors; do
    forge inspect "$contract" "$field" --json 2>/dev/null >"$INSPECTED/$contract.$field"
  done
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

compare_exact DualFillFactory IDualFillFactory methodIdentifiers
compare_exact DualFillFactory IDualFillFactory events
compare_errors DualFillFactory IDualFillFactory
compare_exact DualFill IDualFill methodIdentifiers
compare_exact DualFill IDualFill events
compare_errors DualFill IDualFill

# <contract> <field> <signature> <value>. Error pins are looked up on both contracts: §2.6 lists
# them once for the pair.
PINS=$(cat <<EOF
DualFillFactory methodIdentifiers createFill($LP,bytes32,uint256,uint64,uint64,bool,uint256) 81a81c08
DualFillFactory methodIdentifiers fillOf(address,bytes32) 08d2ffc7
DualFillFactory methodIdentifiers isFill(address) 3b52525a
DualFillFactory methodIdentifiers fillCount() 6051e4dc
DualFillFactory methodIdentifiers fills(uint256,uint256) 7dca72b7
DualFillFactory methodIdentifiers quoteOf(address) cab1ef67
DualFillFactory methodIdentifiers LAUNCH_FACTORY() b4461ec8
DualFillFactory methodIdentifiers QUOTE() 9c579839
DualFillFactory methodIdentifiers FEE_TOKEN() 73717b08
DualFillFactory methodIdentifiers KEEPER() 862a179e
DualFillFactory methodIdentifiers NATIVE_WRAP() 6c5601ac
DualFillFactory methodIdentifiers MAX_FILL_BPS() 049dec70
DualFillFactory methodIdentifiers MIN_DURATION() b6a6d177
DualFillFactory methodIdentifiers MAX_DURATION() b1724b46
DualFillFactory methodIdentifiers MIN_PUBLIC_WINDOW() 61b08a36
DualFillFactory methodIdentifiers OPEN_GRACE() f52d5452
DualFillFactory methodIdentifiers CURVE_SUPPLY() 1e4c7292
DualFillFactory methodIdentifiers LP_SUPPLY() 670171fd
DualFillFactory methodIdentifiers V_TOKEN_INIT() 34ef3499
DualFillFactory methodIdentifiers MAX_CREATOR_TAX_BPS() 2975067d
DualFillFactory methodIdentifiers MAX_NAME_BYTES() 680c60c7
DualFillFactory methodIdentifiers MAX_SYMBOL_BYTES() 8a4940f2
DualFill methodIdentifiers LAUNCH_FACTORY() b4461ec8
DualFill methodIdentifiers QUOTE() 9c579839
DualFill methodIdentifiers FEE_TOKEN() 73717b08
DualFill methodIdentifiers KEEPER() 862a179e
DualFill methodIdentifiers NATIVE_WRAP() 6c5601ac
DualFill methodIdentifiers OPEN_GRACE() f52d5452
DualFill methodIdentifiers MAX_WALLET_SHARE_BPS() fef2b42b
DualFill methodIdentifiers WITHDRAW_FREEZE() c68a064f
DualFill methodIdentifiers deposit(uint256) b6b55f25
DualFill methodIdentifiers depositEth() 439370b1
DualFill methodIdentifiers withdraw(uint256) 2e1a7d4d
DualFill methodIdentifiers cancel() ea8a1af0
DualFill methodIdentifiers abort() 35a063b4
DualFill methodIdentifiers open($LP) dcbad0d3
DualFill methodIdentifiers claim() 4e71d92d
DualFill methodIdentifiers claimFor(address) ddeae033
DualFill methodIdentifiers refundFor(address) 57aba4ab
DualFill methodIdentifiers returnFeeBudget() cb64ed16
DualFill methodIdentifiers claimFees() d294f093
DualFill methodIdentifiers handOverFees() 18e3509d
DualFill methodIdentifiers refundable() bf89662d
DualFill methodIdentifiers remaining() 55234ec0
DualFill methodIdentifiers claimable(address) 402914f5
DualFill methodIdentifiers terms() d5025625
DualFill methodIdentifiers snapshot() 9711715a
DualFill methodIdentifiers FACTORY() 2dd31000
DualFill methodIdentifiers CREATOR() e4fbb609
DualFill methodIdentifiers DUAL_FILL_KEY() 0e8ceacc
DualFill methodIdentifiers TARGET() cc1f2afa
DualFill methodIdentifiers DEADLINE() a082c86e
DualFill methodIdentifiers PUBLIC_UNTIL() 6df48f6b
DualFill methodIdentifiers OPEN_ALONE() c8c19623
DualFill methodIdentifiers FEE_BUDGET() 2a4e3125
DualFill methodIdentifiers PARAMS_HASH() 1411a9ef
DualFill methodIdentifiers status() 200d2ed2
DualFill methodIdentifiers totalDeposited() ff50abdc
DualFill methodIdentifiers contributorCount() ecfd8928
DualFill methodIdentifiers depositorCount() 277e9d28
DualFill methodIdentifiers depositors(uint256,uint256) 3a69d7c0
DualFill methodIdentifiers depositOf(address) 23e3fbd5
DualFill methodIdentifiers openedAt() 38930203
DualFill methodIdentifiers token() fc0c546a
DualFill methodIdentifiers locker() d7b96d4e
DualFill methodIdentifiers poolId() 3e0dc34e
DualFill methodIdentifiers tokensForFill() 8411b086
DualFill methodIdentifiers quoteBack() 60a28ff6
DualFill methodIdentifiers claimedDeposits() 553b27c0
DualFill methodIdentifiers claimedTokens() 0d92e3e8
DualFill methodIdentifiers claimedQuote() 7447efd3
DualFill methodIdentifiers feesHandedOver() 39164221
DualFill methodIdentifiers feeBudgetSettled() a7e6ac9f
TokenLaunchFactory methodIdentifiers createLaunch($LP) 9fbace92
TokenLaunchFactory methodIdentifiers createLaunch($LP,(uint256,uint256,address[])) 41785e23
DualFillFactory events FillCreated(address,address,bytes32,uint256,uint64,uint64,bool,uint256,bytes32,$LP) 0x00a4d22a91b6b8283c2b127728ec8deeda1a3ae5cb1c462f802b4cf6f0733ce4
DualFill events Deposited(address,uint256,uint256,bool) 0x65e6f89b6907d6277741ee4ccbc4ae260163a17f16bbb55b5344dff064867c40
DualFill events Withdrawn(address,uint256,uint256) 0x92ccf450a286a957af52509bc1c9939d1a6a481783e142e41e2499f0bb66ebc6
DualFill events Filled(uint256) 0xd14df08fabc3175c71c9c6b212bd0fd290d0e78a5f809c5f28deb5ba6f029b91
DualFill events Cancelled() 0x63b958841f79ab97cb5456da181454b9932c0e15a3b17f1cbd27e2a8bc610437
DualFill events Aborted(address) 0x13c3922f06c44c3cac6a2c721f8ec8db793360b0180d5e560ca2028de2037eaa
DualFill events Opened(address,address,bytes32,address,uint256,uint256,uint256) 0xf849d2586cabd9983f79f1db336a8684e1489b070cefc38d37db4d37858eff0e
DualFill events Claimed(address,uint256,uint256) 0x987d620f307ff6b94d58743cb7a7509f24071586a77759b77c2d4e29f75a2f9a
DualFill events Refunded(address,uint256) 0xd7dee2702d63ad89917b6a4da9981c90c4d24f8c2bdfd64c604ecae57d8d0651
DualFill events FeeBudgetReturned(uint256) 0xc721e23deda263c544f0b77b4fbc995baa8253a1443e8c5b4b64b1d7568596a6
DualFill events CreatorFeesForwarded(uint256,uint256) 0xaa330b55610f73593b7470d1932f2523ccc17286e023c6ec532d595cc6a2acd5
DualFill events FeesHandedOver(address) 0xbb1a6597846990220fd35033701ecd7153257e500949af585ec78e5e27cfebe3
errors errors ZeroAddress() d92e233d
errors errors NotAContract() 09ee12d5
errors errors NativeUnsupported() 73a5e3bb
errors errors WrongPayment() 788a686f
errors errors FillExists() 8c9b009b
errors errors InvalidDualFillKey() 14b49c8d
errors errors InvalidDeadline() 769d11e4
errors errors InvalidTarget() 82d5d76a
errors errors SupplyMismatch() f6beef52
errors errors EconomicsMismatch() 42889d84
errors errors QuoteMismatch() 3acea3d4
errors errors QuoteDecimalsMismatch() 17b41e76
errors errors InvalidParams() a86b6512
errors errors FeeBudgetTooLow() 8a033e38
errors errors NotKeeper() f512b278
errors errors NotCreator() 93687c0b
errors errors NotFilling() f381ae23
errors errors DeadlinePassed() 70f65caa
errors errors NotFull() d9b5acd5
errors errors OpenWindowClosed() 988a0c71
errors errors ParamsMismatch() e6928806
errors errors FeeAboveBudget() 0a2ebfb9
errors errors NotOpened() 6d36408a
errors errors NothingDeposited() 69b95dc9
errors errors ZeroAmount() 1f2a2005
errors errors NotRefundable() 3742d1f6
errors errors AlreadySettled() 560ff900
errors errors AlreadyHandedOver() e047fed4
errors errors SnipeWindowOpen() 26c60d47
errors errors TransferFailed() 90b8ec18
errors errors OpenAloneFill() 193e864f
errors errors WalletLimitReached() 84dab646
errors errors WithdrawalsFrozen() fad3696e
EOF
)

while read -r contract field signature value; do
  if [ "$contract" = errors ]; then
    got=$(jq -rs --arg s "$signature" '(.[0] + .[1])[$s] // empty' \
      "$INSPECTED/DualFillFactory.errors" "$INSPECTED/DualFill.errors")
  elif [ "$field" = events ]; then
    # forge names a struct argument of an event by its type rather than spelling out the tuple,
    # so the event is found by name and the topic, which hashes the full tuple, is the check.
    got=$(jq -r --arg n "${signature%%(*}" \
      'to_entries[] | select((.key | split("(")[0]) == $n) | .value' "$INSPECTED/$contract.$field")
  else
    got=$(jq -r --arg s "$signature" '.[$s] // empty' "$INSPECTED/$contract.$field")
  fi
  [ "$got" = "$value" ] || fail "$contract $signature is ${got:-absent}, pinned $value"
done <<<"$PINS"

if [ "$FAILED" -ne 0 ]; then
  echo "Dual Fill ABI does not match its pins" >&2
  exit 1
fi
echo "Dual Fill ABI matches its interfaces and every pin"
