#!/usr/bin/env bash
# Verify deployed contracts on Robinhood Chain Blockscout.
#
#   RPC_URL=... script/verify.sh <chain-id> <factory-address>
#
# <factory-address> is the LaunchpadFactory (NFT rail). Robinhood testnet currently has no
# supported Blockscout verification endpoint; on mainnet the payment token is canonical WETH.
#
# Optional environment (token rail, deployed by the same Deploy.s.sol run):
#   TOKEN_FACTORY    TokenLaunchFactory address. Set it to also verify the token rail:
#                    the factory, every launch's AgentToken and LPLocker, and the
#                    Collection721/AllocationVesting of any linked launch.
#                    A factory redeploy leaves the one it replaced in the record's
#                    `legacyTokenLaunchFactories`; run this once per entry to reach the launches
#                    each of them created, with `src` at that entry's own revision.
#   GRADUATION_HOOK  The singleton LaunchHook, mined so its low 14 bits carry its permissions.
#                    Defaults to the address the network's record names, so a run that reads the
#                    committed record verifies the hook without being told about it.
#   FROM_BLOCK       First block to scan for factory events (bounds getLogs). Default 0.
#                    Raise it to the factory deploy block if the RPC caps the log span.
#
# The factories are verified from the Deploy.s.sol broadcast record when present, then from
# deployments.json, then from current on-chain state. Only deployments.json is committed, and it
# names the revision each network was deployed from. Verification recompiles from the working
# tree, so put the sources back to that revision before running this, and nothing else:
#
#   git checkout <sourceCommit> -- src      # undo with: git checkout HEAD -- src
#
# Checking the whole revision out would take deployments.json and this script back with it, and
# both carry fixes made after the last deploy, including the library links below. Compiler
# settings are inputs too: if foundry.toml, remappings.txt or a lib/ pin has moved since the
# deploy, put those back as well.
#
# Factory-deployed children (collections, tokens, curves, lockers, vesting) are created by
# CREATE inside a user or agent transaction, so they have no standalone creation transaction
# for --guess-constructor-args to read. Each child is tried with --guess-constructor-args first
# (Blockscout can match it from its internal creation trace), and on failure its constructor
# arguments are rebuilt: the collection's from the CollectionCreated event bytes spliced onto
# the trailing addresses, the token rail's from the children's own immutable getters.
set -euo pipefail

cd "$(dirname "$0")/.."

CHAIN_ID="${1:?usage: verify.sh <chain-id> <factory-address>}"
FACTORY="${2:?usage: verify.sh <chain-id> <factory-address>}"
TOKEN_FACTORY="${TOKEN_FACTORY:-}"
GRADUATION_HOOK="${GRADUATION_HOOK:-}"
FROM_BLOCK="${FROM_BLOCK:-0}"
: "${RPC_URL:?set RPC_URL to the chain being verified}"

# Robinhood Chain publishes one Blockscout instance, and it indexes mainnet only.
# Testnet deploys have no explorer to verify against.
if [ "$CHAIN_ID" != "4663" ]; then
  echo "chain $CHAIN_ID has no Blockscout instance; nothing to verify" >&2
  exit 0
fi
# Blockscout sits behind Cloudflare and answers a burst of verification calls with a challenge
# page where forge expects JSON. Point VERIFIER_URL at ops/rh-rpc-proxy.mjs to get through it.
# VERIFIER_KEY is the explorer API key (BLOCKSCOUT_API_KEY in keys.env). Without one the
# instance rate-limits after about two contracts and the rest report "Too many requests".
VERIFIER_URL="${VERIFIER_URL:-https://robinhoodchain.blockscout.com/api}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

FAILURES=()
note_failure() { FAILURES+=("$1"); echo "!! $1" >&2; }

# --rpc-url is mandatory: --guess-constructor-args reads the creation input over it, and
# without it the guess silently degrades and the args never match.
verify() {
  forge verify-contract \
    --verifier blockscout \
    --verifier-url "$VERIFIER_URL" \
    ${VERIFIER_KEY:+--etherscan-api-key "$VERIFIER_KEY"} \
    --chain-id "$CHAIN_ID" \
    --rpc-url "$RPC_URL" \
    --watch \
    "$@"
}

read_addr() { local t="$1" sig="$2"; shift 2; cast call "$t" "$sig" "$@" --rpc-url "$RPC_URL" | awk '{print $1}'; }
call() { read_addr "$FACTORY" "$1"; }

pad_addr() { local a="${1#0x}"; printf '%064s' "$(echo "$a" | tr 'A-Z' 'a-z')" | tr ' ' '0'; }
pad_uint() { cast to-uint256 "$1" | sed 's/^0x//'; }

# LaunchpadFactory (NFT rail).
# Constructor arguments come from the deployment record, not from current storage:
# treasury, platformSigner and owner are all settable after launch, and reading them live
# would encode arguments the creation code never carried.
BROADCAST="broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
FACTORY_ARGS=""
if [ -f "$BROADCAST" ]; then
  FACTORY_ARGS=$(jq -r --arg addr "$(echo "$FACTORY" | tr 'A-Z' 'a-z')" '
    [ .transactions[]
      | select((.contractAddress // "" | ascii_downcase) == $addr)
      | .arguments // [] ] | first // [] | join(" ")' "$BROADCAST")
fi

# The network's committed record. broadcast/ is machine-local, so this is the only source of
# the deploy's library links and source revision anywhere but the machine that ran it.
# `DEPLOYMENTS` is overridable so `verify.test.sh` can drive the branches a given record does not
# reach; a real run leaves it alone and reads the committed file.
DEPLOYMENTS="${DEPLOYMENTS:-deployments.json}"
DEPLOYMENT=$(jq --argjson id "$CHAIN_ID" '
  [ to_entries[] | select((.value | type) == "object" and .value.chainId == $id) | .value ]
  | first // {}' "$DEPLOYMENTS")

# Verification recompiles from the working tree, so sources that are not the deployed revision
# produce different bytecode and nothing matches, however good the constructor arguments are.
# The comparison is against src/ alone, not HEAD: the fix is a path-limited checkout, which
# leaves HEAD where it was, and a whole-revision checkout would undo this script and the
# deployment record along with it.
SOURCE_COMMIT=$(echo "$DEPLOYMENT" | jq -r '.sourceCommit // empty')
# One hook serves every launch on a network, and the record names it under both the name it was
# announced with and the one the pre-pool generation used.
GRADUATION_HOOK="${GRADUATION_HOOK:-$(
  echo "$DEPLOYMENT" | jq -r '.launchHook // .graduationHook // empty'
)}"
source_state() {
  { [ -n "$SOURCE_COMMIT" ] && git rev-parse --git-dir >/dev/null 2>&1; } || { echo skip; return; }
  git rev-parse --verify -q "$SOURCE_COMMIT^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  if git diff --quiet "$SOURCE_COMMIT" -- src; then echo match; else echo differs; fi
}
SOURCE_STATE=$(source_state)
case "$SOURCE_STATE" in
  match | skip) ;;
  *)
    if [ "$SOURCE_STATE" = unknown ]; then
      echo "chain $CHAIN_ID was deployed from $SOURCE_COMMIT, which this clone does not carry" >&2
    else
      echo "chain $CHAIN_ID was deployed from $SOURCE_COMMIT; src/ here is not that revision" >&2
    fi
    echo "every contract below will fail until it is. Restore the sources only:" >&2
    echo "  git checkout $SOURCE_COMMIT -- src" >&2
    echo "  (undo with: git checkout HEAD -- src)" >&2
    echo "a whole-revision checkout would take this script and deployments.json back with it" >&2
    ;;
esac

# Both factories delegate deployment to linked libraries, and forge script links them after
# compilation: it deploys each library and patches the __$...$__ placeholders in bytecode solc
# has already emitted. The metadata hashed into the deployed bytes therefore records no
# libraries. --libraries here would put them in the standard JSON's settings.libraries, which
# solc folds back into that metadata, so the recompiled code differs from the chain's in the
# metadata digest and can never be a full match. Measured on 4663's TokenLaunchFactory at
# 25f38804: unlinked, its 20,026-byte runtime reproduces the deployed code exactly once the
# placeholders are patched and the immutables masked; linked, the same build differs in bytes
# 19983 to 20014 and nowhere else.
#
# So each factory is offered the input its own deploy compiled, and the recorded links are held
# back for the retry below in case the verifier cannot resolve the placeholders itself.
# forge records links in the broadcast's top-level .libraries array as "path:Name:address". The
# per-transaction records are not a reliable source: a library deployed through the CREATE2
# proxy has no contractAddress of its own.
# Read once, above the library check that depends on it: a record carrying a quote registry is a
# v2 deployment, and a v2 deployment links five libraries.
QUOTE_REGISTRY_RECORDED=$(echo "$DEPLOYMENT" | jq -r '.quoteRegistry // empty')
STOCK_LINK_RECORDED=$(echo "$DEPLOYMENT" | jq -r '.stockLinkRegistry // empty')
LAUNCH_ROUTER_RECORDED=$(echo "$DEPLOYMENT" | jq -r '.launchRouter // empty')

library_address() {
  local name="$1" addr=""
  if [ -f "$BROADCAST" ]; then
    addr=$(jq -r --arg n "$name" '
      [ .libraries[]? | split(":") | select(.[1] == $n) | .[2] ] | first // empty' "$BROADCAST")
  fi
  [ -n "$addr" ] || addr=$(echo "$DEPLOYMENT" | jq -r --arg n "$name" '.libraries[$n] // empty')
  echo "$addr"
}

libraries_flags() {
  local name addr
  for name in "$@"; do
    addr=$(library_address "$name")
    if [ -z "$addr" ]; then
      echo "no address recorded for $name; the linked retry cannot cover it" >&2
      continue
    fi
    printf -- '--libraries src/libraries/%s.sol:%s:%s ' "$name" "$name" "$addr"
  done
}

verify_library() {
  local name="$1" addr
  addr=$(library_address "$name")
  if [ -z "$addr" ]; then
    note_failure "$name (no address in $BROADCAST or deployments.json)"
    return
  fi
  verify "$addr" "src/libraries/$name.sol:$name" || note_failure "$name $addr"
}

# A factory, from the compiler input its deploy used. Only if the verifier will not take the
# unlinked placeholders is the linked input sent, and that one carries the links in its metadata,
# so it matches everything except the metadata digest.
verify_factory() {
  local addr="$1" contract="$2" args="$3" libs="$4"
  if verify "$addr" "$contract" --constructor-args "$args"; then return 0; fi
  [ -n "$libs" ] || return 1
  echo "unlinked input rejected for $contract $addr; retrying with the recorded links" >&2
  echo "a linked input changes the metadata digest, so this can only be a partial match" >&2
  # shellcheck disable=SC2086
  verify "$addr" "$contract" --constructor-args "$args" $libs
}

# The libraries this network's record actually names, rather than a list typed here. A v1
# deployment links four; a v2 one links five, because `TokenDeployer` was split out of the
# deployer library that carried both the token's and the curve's creation code. That library,
# not the factory, is where EIP-170 bites. Reading the record keeps both generations verifiable
# from the same script, and the check below is what stops a v2 record quietly omitting the new
# one: nothing on chain can rediscover a library address, so an unnamed library is an
# unverifiable factory forever.
RECORDED_LIBS=$(echo "$DEPLOYMENT" | jq -r '.libraries // {} | keys[]' | tr '\n' ' ')
if [ -z "$(echo "$RECORDED_LIBS" | tr -d ' ')" ]; then
  echo "no libraries recorded for chain $CHAIN_ID; both factories will fail to match" >&2
fi
if [ -n "$QUOTE_REGISTRY_RECORDED" ]; then
  case " $RECORDED_LIBS " in
    *" TokenDeployer "*) ;;
    *) note_failure "TokenDeployer (a v2 record must name all five deployer libraries)" ;;
  esac
fi

# shellcheck disable=SC2086
NFT_LIBS=$(libraries_flags CollectionDeployer)
# shellcheck disable=SC2086
TOKEN_LIBS=$(libraries_flags $RECORDED_LIBS)

for lib in $RECORDED_LIBS; do
  verify_library "$lib"
done

# Both factory constructors keep their deployed shapes in v2. The shared quote registry arrives
# through an owner-only `setQuoteRegistry` in the deploy's pre-handoff window rather than as a
# constructor argument, precisely so neither factory's creation code (and neither string below)
# moves. A dynamic allowlist array in a constructor would have broken these one-liners outright.
if [ -n "$FACTORY_ARGS" ]; then
  # shellcheck disable=SC2086
  ENCODED=$(cast abi-encode 'c(address,address,address,address)' $FACTORY_ARGS)
else
  echo "no broadcast record at $BROADCAST; falling back to current factory state" >&2
  echo "if any admin address has been rotated since deploy, verification will not match" >&2
  ENCODED=$(cast abi-encode 'c(address,address,address,address)' \
    "$(call 'QUOTE()(address)')" \
    "$(call 'treasury()(address)')" \
    "$(call 'platformSigner()(address)')" \
    "$(call 'owner()(address)')")
fi

verify_factory "$FACTORY" src/LaunchpadFactory.sol:LaunchpadFactory "$ENCODED" "$NFT_LIBS" ||
  note_failure "LaunchpadFactory $FACTORY"

# The shared quote registry, if this network has one. Its constructor is
# (defaultQuote, feeToken, owner). The first two are immutable and read back exactly as they were
# passed; the owner is the broadcaster that seeded the allowlist, which is the record's `owner`
# and not the live `owner()`: an Ownable2Step handoff that has been accepted would answer with
# the new holder and encode an argument the creation code never carried.
if [ -n "$QUOTE_REGISTRY_RECORDED" ]; then
  QUOTE_REGISTRY="$QUOTE_REGISTRY_RECORDED"
  QR_ENC=$(cast abi-encode 'c(address,address,address)' \
    "$(read_addr "$QUOTE_REGISTRY" 'defaultQuote()(address)')" \
    "$(read_addr "$QUOTE_REGISTRY" 'feeToken()(address)')" \
    "$(echo "$DEPLOYMENT" | jq -r '.owner')")
  verify "$QUOTE_REGISTRY" src/QuoteRegistry.sol:QuoteRegistry --constructor-args "$QR_ENC" ||
    note_failure "QuoteRegistry $QUOTE_REGISTRY"
else
  echo "no quoteRegistry in the record for chain $CHAIN_ID; skipping it" >&2
fi

# The stock-link registry, deployed by its own script and recorded by hand. Its constructor is
# (tokenLaunchFactory, launchpadFactory), the **token rail first**, and both are immutable, so
# the two reads below are the constructor arguments and also a cross-check that the pair was not
# deployed swapped. Both factories answer `isFromFactory`, so an address alone proves nothing.
if [ -n "$STOCK_LINK_RECORDED" ]; then
  STOCK_LINK="$STOCK_LINK_RECORDED"
  SL_TOKEN=$(read_addr "$STOCK_LINK" 'TOKEN_FACTORY()(address)')
  SL_NFT=$(read_addr "$STOCK_LINK" 'NFT_FACTORY()(address)')
  SL_ENC=$(cast abi-encode 'c(address,address)' "$SL_TOKEN" "$SL_NFT")
  verify "$STOCK_LINK" src/StockLinkRegistry.sol:StockLinkRegistry --constructor-args "$SL_ENC" ||
    note_failure "StockLinkRegistry $STOCK_LINK"
else
  echo "no stockLinkRegistry in the record for chain $CHAIN_ID; skipping it" >&2
fi

# The trading router. Its constructor is (poolManager, hook, permit2), all three immutable and
# all three exposed, so the reads below are the constructor arguments and also a check that the
# router on file is keyed to this network's hook. It carries no owner, so nothing about it can
# have moved since it was deployed.
if [ -n "$LAUNCH_ROUTER_RECORDED" ]; then
  LAUNCH_ROUTER="$LAUNCH_ROUTER_RECORDED"
  LR_ENC=$(cast abi-encode 'c(address,address,address)' \
    "$(read_addr "$LAUNCH_ROUTER" 'POOL_MANAGER()(address)')" \
    "$(read_addr "$LAUNCH_ROUTER" 'HOOK()(address)')" \
    "$(read_addr "$LAUNCH_ROUTER" 'PERMIT2()(address)')")
  verify "$LAUNCH_ROUTER" src/LaunchRouter.sol:LaunchRouter --constructor-args "$LR_ENC" ||
    note_failure "LaunchRouter $LAUNCH_ROUTER"
else
  echo "no launchRouter in the record for chain $CHAIN_ID; skipping it" >&2
fi

# NFT collections.
# A collection's constructor is (CollectionParams p, address creator, uint96 protocolFeeBps,
# address quote, address treasury, address platformSigner). The CollectionCreated event data is
# abi.encode(p), a single dynamic tuple, so it is exactly the tail the constructor encoding
# needs: prepend the six-word head (offset to p, then the five trailing scalars) and splice the
# event's p-body on. creator/fee/quote/treasury come from the collection's immutables; the
# construction-time platformSigner is read from the factory at the collection's creation block,
# so a later signer rotation does not break the match.
collection_args() {
  local addr="$1" body
  local creator fee quote treasury signer block data
  creator=$(read_addr "$addr" 'CREATOR()(address)')
  fee=$(read_addr "$addr" 'PROTOCOL_FEE_BPS()(uint96)')
  quote=$(read_addr "$addr" 'QUOTE()(address)')
  treasury=$(read_addr "$addr" 'TREASURY()(address)')

  local topic
  topic="0x$(pad_addr "$addr")"
  local logs
  # `CollectionParams` gained an appended `address quote` (DQ2), so the event's tuple type (and
  # with it the event's topic0) changed. A v1 factory emits the eleven-field shape and a v2 one
  # the twelve-field shape, so both are asked for and whichever answers is used. Filtering for
  # one topic alone finds nothing on the other generation and reports it as a collection with no
  # creation log, which is silently a verification that never happened.
  local v2_sig v1_sig
  v2_sig='CollectionCreated(address,address,(string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96,address))'
  v1_sig='CollectionCreated(address,address,(string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96))'
  logs=$(cast logs --rpc-url "$RPC_URL" --from-block "$FROM_BLOCK" --address "$FACTORY" \
    "$v2_sig" --json 2>/dev/null) || logs='[]'
  if [ "$(echo "$logs" | jq 'length')" = "0" ]; then
    logs=$(cast logs --rpc-url "$RPC_URL" --from-block "$FROM_BLOCK" --address "$FACTORY" \
      "$v1_sig" --json 2>/dev/null) || return 1
  fi
  local entry
  entry=$(echo "$logs" | jq -r --arg t "$topic" 'map(select(.topics[2] == $t)) | first // empty')
  [ -n "$entry" ] || return 1
  data=$(echo "$entry" | jq -r '.data')
  block=$(echo "$entry" | jq -r '.blockNumber')
  signer=$(cast call "$FACTORY" 'platformSigner()(address)' --block "$block" --rpc-url "$RPC_URL" |
    awk '{print $1}')

  # Strip 0x and the leading 32-byte offset word of abi.encode(p) to get p's body.
  body="${data#0x}"
  body="${body:64}"

  # head: offset to p (0xc0 = six words), then the five trailing scalars.
  #
  # Still 192, and deliberately so. The plan expected this to move to 224 when `CollectionParams`
  # grew a field, but that would only happen if the *constructor* gained a seventh trailing
  # scalar. It did not: `quote` was appended inside `p`, and `p` is a dynamic tuple whose body
  # lives past the head either way. The head is the six words this printf writes (the offset and
  # the five scalars), and the event's `abi.encode(p)` body, spliced on below, carries the extra
  # field on its own.
  printf '0x%064x%s%s%s%s%s%s' 192 \
    "$(pad_addr "$creator")" "$(pad_uint "$fee")" "$(pad_addr "$quote")" \
    "$(pad_addr "$treasury")" "$(pad_addr "$signer")" "$body"
}

COUNT=$(call 'collectionCount()(uint256)')
for ((i = 0; i < COUNT; i++)); do
  ADDR=$(read_addr "$FACTORY" "allCollections(uint256)(address)" "$i")
  echo "verifying collection $i at $ADDR"
  if verify "$ADDR" src/Collection721.sol:Collection721 --guess-constructor-args; then
    continue
  fi
  echo "guess failed for collection $ADDR; rebuilding args from CollectionCreated" >&2
  if ARGS=$(collection_args "$ADDR") && [ -n "$ARGS" ]; then
    verify "$ADDR" src/Collection721.sol:Collection721 --constructor-args "$ARGS" ||
      note_failure "Collection721 $ADDR"
  else
    note_failure "Collection721 $ADDR (no CollectionCreated log in range from $FROM_BLOCK)"
  fi
done

# Token rail.
if [ -n "$TOKEN_FACTORY" ]; then
  tcall() { read_addr "$TOKEN_FACTORY" "$1"; }

  # Deploy.s.sol deploys the token rail in the same run as the NFT rail, so its constructor
  # arguments are in the same broadcast record.
  TF_ARGS=""
  if [ -f "$BROADCAST" ]; then
    TF_ARGS=$(jq -r --arg addr "$(echo "$TOKEN_FACTORY" | tr 'A-Z' 'a-z')" '
      [ .transactions[]
        | select((.contractAddress // "" | ascii_downcase) == $addr)
        | .arguments // [] ] | first // [] | join(" ")' "$BROADCAST")
  fi
  if [ -n "$TF_ARGS" ]; then
    # shellcheck disable=SC2086
    TF_ENC=$(cast abi-encode 'c(address,address,address,address,address)' $TF_ARGS)
  else
    echo "no token-factory args in $BROADCAST; using current state (breaks if admin rotated)" >&2
    TF_ENC=$(cast abi-encode 'c(address,address,address,address,address)' \
      "$(tcall 'QUOTE()(address)')" \
      "$(tcall 'POOL_MANAGER()(address)')" \
      "$(tcall 'treasury()(address)')" \
      "$(tcall 'platformSigner()(address)')" \
      "$(tcall 'owner()(address)')")
  fi
  verify_factory "$TOKEN_FACTORY" src/TokenLaunchFactory.sol:TokenLaunchFactory \
    "$TF_ENC" "$TOKEN_LIBS" || note_failure "TokenLaunchFactory $TOKEN_FACTORY"

  # The launch hook is a singleton with its own creation transaction, so --guess-constructor-args
  # reads its two arguments straight off the chain. The fallback cannot: the owner in the creation
  # code is whoever deployed it, and by the time anyone verifies, ownership has usually moved on.
  if [ -n "$GRADUATION_HOOK" ]; then
    verify "$GRADUATION_HOOK" src/hook/LaunchHook.sol:LaunchHook --guess-constructor-args ||
      note_failure "LaunchHook $GRADUATION_HOOK"
  fi

  verify_from_immutables() {
    local addr="$1" contract="$2" sig="$3"; shift 3
    if verify "$addr" "$contract" --guess-constructor-args; then return 0; fi
    echo "guess failed for $contract $addr; rebuilding from immutables" >&2
    local vals=() getter
    for getter in "$@"; do vals+=("$(read_addr "$addr" "$getter")"); done
    local enc
    enc=$(cast abi-encode "$sig" "${vals[@]}") || return 1
    verify "$addr" "$contract" --constructor-args "$enc"
  }

  LCOUNT=$(tcall 'launchCount()(uint256)')
  for ((i = 0; i < LCOUNT; i++)); do
    # A here-string, not a process substitution: `tr` leaves no trailing newline, `read` then
    # reports EOF, and under `set -e` the script would exit at the first launch it found.
    #
    # The middle two addresses swapped meaning when the curve became a pool. A `Launch` is
    # {token, curve, locker, creator} on a pre-pool factory and {token, locker, hook, creator} on
    # this one, and both decode as four addresses, so the shape is probed rather than assumed:
    # only a locker answers `HOOK()`.
    read -r TOKEN SECOND THIRD _ <<<"$(
      cast call "$TOKEN_FACTORY" "allLaunches(uint256)(address,address,address,address)" "$i" \
        --rpc-url "$RPC_URL" | tr '\n' ' '
    )"
    if read_addr "$SECOND" 'HOOK()(address)' >/dev/null 2>&1; then
      CURVE=""
      LOCKER="$SECOND"
    else
      CURVE="$SECOND"
      LOCKER="$THIRD"
    fi
    echo "verifying launch $i: token=$TOKEN curve=${CURVE:-none} locker=$LOCKER"

    # AgentToken(string name, string symbol, address holder, uint256 supply, string logo,
    # string description, (string,string,string,string,string) socials). The factory was the
    # constructor holder, then LockerDeployer moved the full supply to the curve.
    #
    # The identity arguments arrived with the launch generation that carries a token's image,
    # blurb and links on chain. A token minted before that has a four-argument constructor, so
    # the older shape is tried when the newer one does not match: both are live on testnet.
    if ! verify "$TOKEN" src/AgentToken.sol:AgentToken --guess-constructor-args; then
      NAME=$(cast call "$TOKEN" 'name()(string)' --rpc-url "$RPC_URL")
      SYM=$(cast call "$TOKEN" 'symbol()(string)' --rpc-url "$RPC_URL")
      SUPPLY=$(read_addr "$TOKEN" 'totalSupply()(uint256)')
      ENC=""
      if LOGO=$(cast call "$TOKEN" 'logo()(string)' --rpc-url "$RPC_URL" 2>/dev/null); then
        DESC=$(cast call "$TOKEN" 'description()(string)' --rpc-url "$RPC_URL")
        # Five strings on five lines, in the order the token stores them: X first.
        SOCIALS=$(cast call "$TOKEN" \
          'socials()(string,string,string,string,string)' --rpc-url "$RPC_URL" | paste -sd, -)
        ENC=$(cast abi-encode \
          'c(string,string,address,uint256,string,string,(string,string,string,string,string))' \
          "$NAME" "$SYM" "$TOKEN_FACTORY" "$SUPPLY" "$LOGO" "$DESC" "($SOCIALS)") || ENC=""
      fi
      [ -n "$ENC" ] || ENC=$(cast abi-encode \
        'c(string,string,address,uint256)' "$NAME" "$SYM" "$TOKEN_FACTORY" "$SUPPLY")
      verify "$TOKEN" src/AgentToken.sol:AgentToken --constructor-args "$ENC" ||
        note_failure "AgentToken $TOKEN"
    fi

    # BondingCurve(CurveConfig c, address token, address quote, address factory, address treasury).
    # CurveConfig is a static struct, so the whole constructor encodes inline from immutables.
    #
    # Only a pre-pool launch has one, and its source is no longer in the tree: a launch is a pool
    # now and the contract was retired with the generation that created it. Put `src` back to the
    # network's `sourceCommit`, as the header says, and this branch verifies as it always did.
    if [ -n "$CURVE" ] && ! verify "$CURVE" src/BondingCurve.sol:BondingCurve --guess-constructor-args; then
      ENC=$(cast abi-encode \
        'c((uint256,uint256,uint256,uint256,uint256,uint96,uint24,int24),address,address,address,address)' \
        "($(read_addr "$CURVE" 'CURVE_SUPPLY()(uint256)'),$(read_addr "$CURVE" 'LP_TOKEN_SUPPLY()(uint256)'),$(read_addr "$CURVE" 'V_QUOTE_INIT()(uint256)'),$(read_addr "$CURVE" 'V_TOKEN_INIT()(uint256)'),$(read_addr "$CURVE" 'GRADUATION_QUOTE()(uint256)'),$(read_addr "$CURVE" 'TRADE_FEE_BPS()(uint96)'),$(read_addr "$CURVE" 'POOL_FEE()(uint24)'),$(read_addr "$CURVE" 'TICK_SPACING()(int24)'))" \
        "$(read_addr "$CURVE" 'TOKEN()(address)')" \
        "$(read_addr "$CURVE" 'QUOTE()(address)')" \
        "$(read_addr "$CURVE" 'FACTORY()(address)')" \
        "$(read_addr "$CURVE" 'TREASURY()(address)')") &&
        verify "$CURVE" src/BondingCurve.sol:BondingCurve --constructor-args "$ENC" ||
        note_failure "BondingCurve $CURVE"
    fi

    # LPLocker(IPoolManager, address curve, address factory, address treasury, address creator,
    # uint96 creatorFeeBps, uint64 unlockAt). Lockers deployed before pool fees were split with
    # the creator take five arguments and end at the treasury, so ask the deployed contract
    # which one it is instead of assuming the working tree's shape.
    # A v2 locker also carries the pull-escrow ledger. Its constructor shape is unchanged by it,
    # so this probe decides nothing about the encoding: it says which generation is on chain, so
    # a locker verified without an escrow is not mistaken for one that has it. `totalOwed` is the
    # read, because it is the one the escrow's `free(token)` is defined against.
    if read_addr "$LOCKER" 'totalOwed(address)(uint256)' "$(read_addr "$LOCKER" 'TREASURY()(address)')" >/dev/null 2>&1; then
      echo "locker $LOCKER carries the pull escrow" >&2
    else
      echo "locker $LOCKER predates the pull escrow; its fees were pushed, not credited" >&2
    fi

    if [ -z "$CURVE" ]; then
      # The pool generation. The locker is keyed to the singleton hook instead of a curve, and it
      # took over custody of the launch's own token and quote, so both are constructor arguments.
      verify_from_immutables "$LOCKER" src/LPLocker.sol:LPLocker \
        'c(address,address,address,address,address,address,address,uint96,uint64)' \
        'POOL_MANAGER()(address)' 'HOOK()(address)' 'FACTORY()(address)' 'TOKEN()(address)' \
        'QUOTE()(address)' 'TREASURY()(address)' 'CREATOR()(address)' \
        'CREATOR_FEE_BPS()(uint96)' 'UNLOCK_AT()(uint64)' || note_failure "LPLocker $LOCKER"
    elif read_addr "$LOCKER" 'CREATOR_FEE_BPS()(uint96)' >/dev/null 2>&1; then
      verify_from_immutables "$LOCKER" src/LPLocker.sol:LPLocker \
        'c(address,address,address,address,address,uint96,uint64)' \
        'POOL_MANAGER()(address)' 'CURVE()(address)' 'FACTORY()(address)' \
        'TREASURY()(address)' 'CREATOR()(address)' 'CREATOR_FEE_BPS()(uint96)' \
        'UNLOCK_AT()(uint64)' || note_failure "LPLocker $LOCKER"
    else
      echo "locker $LOCKER predates the creator fee split; using the five-argument shape" >&2
      verify_from_immutables "$LOCKER" src/LPLocker.sol:LPLocker \
        'c(address,address,address,address,uint64)' \
        'POOL_MANAGER()(address)' 'CURVE()(address)' 'FACTORY()(address)' \
        'TREASURY()(address)' 'UNLOCK_AT()(uint64)' || note_failure "LPLocker $LOCKER"
    fi
  done

  # Linked launches carry a Collection721 + AllocationVesting the NFT factory never listed.
  LINKED=$(cast logs --rpc-url "$RPC_URL" --from-block "$FROM_BLOCK" --address "$TOKEN_FACTORY" \
    'LinkedLaunchCreated(address,address,address,address,address)' --json 2>/dev/null || echo '[]')
  # Fed by redirect, not by a pipe: a piped `while` runs in a subshell and every note_failure
  # inside it would be lost, so the script could exit 0 with contracts left unverified.
  while IFS=$'\t' read -r data blk; do
    [ -z "${data:-}" ] && continue
    # Non-indexed data is abi.encode(curve, collection, vesting); take the address (last 40
    # hex) of the collection word (2nd, offset 64) and the vesting word (3rd, offset 128).
    #
    # Re-derived for v2 and unchanged: `LinkedLaunchCreated` gained no field, so its topic0 and
    # these two byte offsets are the same as they were. The launch's quote rides `LaunchCreated`
    # inside `p` (DQ2), and there is exactly one resolved quote for a linked launch's curve and
    # its collection, so nothing here has to learn about it.
    d="${data#0x}"
    COLL="0x${d:88:40}"
    VEST="0x${d:152:40}"
    echo "verifying linked collection=$COLL vesting=$VEST"

    # AllocationVesting(address token, address curve, uint64 vestDuration, uint64 vestCliff).
    verify_from_immutables "$VEST" src/AllocationVesting.sol:AllocationVesting \
      'c(address,address,uint64,uint64)' \
      'TOKEN()(address)' 'CURVE()(address)' 'VEST_DURATION()(uint64)' 'VEST_CLIFF()(uint64)' ||
      note_failure "AllocationVesting $VEST"

    # A linked collection is a Collection721 the token factory deployed. It has no
    # CollectionCreated log, so guess-first, then rebuild its dynamic params from getters.
    if ! verify "$COLL" src/Collection721.sol:Collection721 --guess-constructor-args; then
      NAME=$(cast call "$COLL" 'name()(string)' --rpc-url "$RPC_URL")
      SYM=$(cast call "$COLL" 'symbol()(string)' --rpc-url "$RPC_URL")
      ROY=$(cast call "$COLL" 'royaltyInfo(uint256,uint256)(address,uint256)' 0 10000 \
        --rpc-url "$RPC_URL" | sed -n '2p' | awk '{print $1}')
      # A launch with no start time is constructed with startTime 0 and stores the creation
      # block's timestamp, so the getter reads back a value the constructor never carried.
      START=$(read_addr "$COLL" 'START_TIME()(uint64)')
      if [ "$START" = "$(cast block "$blk" --field timestamp --rpc-url "$RPC_URL" | awk '{print $1}')" ]; then
        START=0
      fi
      ENC=$(cast abi-encode \
        'c((string,string,uint256,uint256,uint256,uint64,uint64,uint8,string,string,uint96),address,uint96,address,address,address)' \
        "($NAME,$SYM,$(read_addr "$COLL" 'PRICE_QUOTE()(uint256)'),$(read_addr "$COLL" 'MAX_SUPPLY()(uint256)'),$(read_addr "$COLL" 'PER_WALLET_CAP()(uint256)'),$START,$(read_addr "$COLL" 'END_TIME()(uint64)'),$(read_addr "$COLL" 'MODE()(uint8)'),$(cast call "$COLL" 'baseURI()(string)' --rpc-url "$RPC_URL"),$(cast call "$COLL" 'placeholderURI()(string)' --rpc-url "$RPC_URL"),$ROY)" \
        "$(read_addr "$COLL" 'CREATOR()(address)')" \
        "$(read_addr "$COLL" 'PROTOCOL_FEE_BPS()(uint96)')" \
        "$(read_addr "$COLL" 'QUOTE()(address)')" \
        "$(read_addr "$COLL" 'TREASURY()(address)')" \
        "$(cast call "$TOKEN_FACTORY" 'platformSigner()(address)' --block "$blk" \
          --rpc-url "$RPC_URL" | awk '{print $1}')") &&
        verify "$COLL" src/Collection721.sol:Collection721 --constructor-args "$ENC" ||
        note_failure "Collection721(linked) $COLL"
    fi
  done < <(echo "$LINKED" | jq -r '.[] | [.data, .blockNumber] | @tsv')
fi

if [ "${#FAILURES[@]}" -ne 0 ]; then
  echo "" >&2
  echo "verification finished with ${#FAILURES[@]} unverified contract(s):" >&2
  printf '  - %s\n' "${FAILURES[@]}" >&2
  echo "rebuild each from its deployment args and re-run forge verify-contract by hand." >&2
  exit 1
fi
echo "all deployed contracts verified"
