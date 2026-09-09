#!/usr/bin/env python3
"""Read the two indexers that answer without an account, for the terminal test's pool.

GMGN, Axiom and Axiom Pulse refuse unauthenticated requests, so they have to be checked by a
logged-in person. This covers only what a script can honestly answer, and prints one labelled
line per source with a UTC timestamp so successive runs can be pasted into the record.

    python3 script/tt/poll-terminals.py
"""

import json
import sys
import time
import urllib.error
import urllib.request

TOKEN = "0x002939da54ae7fb1C521371EfFA4662bb459f3ee"
POOL_ID = "0xaae1bd3d185c41df7d4af31c6d834a5b45592e40d8c0d6f0a7c70d138b08fa81"
# A Pons pool DexScreener is already known to index, as the control: if this stops answering the
# problem is the request, not the pool under test.
CONTROL_POOL = "0x8ec616767e6ce2c3a796394df8e1c3bce59f6d57a6f8cfc4b1842b66dd56ee49"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0 Safari/537.36"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, None
    except Exception as e:  # network, timeout, malformed body
        return None, {"error": str(e)}


def pair_line(p):
    return (
        f"chainId={p.get('chainId')} dexId={p.get('dexId')} labels={p.get('labels')} "
        f"pairAddress={p.get('pairAddress')} "
        f"base={(p.get('baseToken') or {}).get('symbol')} "
        f"quote={(p.get('quoteToken') or {}).get('symbol')} "
        f"priceUsd={p.get('priceUsd')} priceNative={p.get('priceNative')} "
        f"liqUsd={(p.get('liquidity') or {}).get('usd')} fdv={p.get('fdv')} "
        f"pairCreatedAt={p.get('pairCreatedAt')} txns24h={(p.get('txns') or {}).get('h24')}"
    )


def show(label, url, render):
    status, body = get(url)
    print(f"[{label}] HTTP {status}")
    print(f"  {url}")
    try:
        for line in render(body):
            print(f"  {line}")
    except Exception as exc:
        print(f"  could not read the body: {exc}: {json.dumps(body)[:400]}")
    print()


def ds_pairs(body):
    if not isinstance(body, dict):
        return [f"raw: {json.dumps(body)[:300]}"]
    pairs = body.get("pairs")
    if pairs is None:
        return [f'pairs: null   (whole body: {json.dumps(body)[:200]})']
    if not pairs:
        return ["pairs: [] (empty)"]
    return [pair_line(p) for p in pairs[:6]]


def ds_list(body):
    if isinstance(body, list):
        return [pair_line(p) for p in body[:6]] or ["[] (empty)"]
    return ds_pairs(body)


def gt_pool(body):
    if not isinstance(body, dict):
        return [f"raw: {json.dumps(body)[:300]}"]
    if "errors" in body:
        return [f"errors: {json.dumps(body['errors'])[:300]}"]
    data = body.get("data")
    if not data:
        return [f"no data: {json.dumps(body)[:300]}"]
    items = data if isinstance(data, list) else [data]
    out = []
    for d in items[:6]:
        a = d.get("attributes", {})
        rel = d.get("relationships", {})
        dex = ((rel.get("dex") or {}).get("data") or {}).get("id")
        out.append(
            f"id={d.get('id')} dex={dex} name={a.get('name')} "
            f"price_usd={a.get('base_token_price_usd')} "
            f"price_native={a.get('base_token_price_native_currency')} "
            f"reserve_usd={a.get('reserve_in_usd')} fdv={a.get('fdv_usd')} "
            f"created={a.get('pool_created_at')}"
        )
    return out


def main():
    print(f"=== terminal test indexer read, {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} ===\n")
    show("dexscreener token", f"https://api.dexscreener.com/latest/dex/tokens/{TOKEN}", ds_pairs)
    show("dexscreener pair", f"https://api.dexscreener.com/latest/dex/pairs/robinhood/{POOL_ID}", ds_pairs)
    show("dexscreener search TTEST", "https://api.dexscreener.com/latest/dex/search?q=TTEST", ds_pairs)
    show("dexscreener token-pairs v1", f"https://api.dexscreener.com/token-pairs/v1/robinhood/{TOKEN}", ds_list)
    show("dexscreener control (a live Pons pool)",
         f"https://api.dexscreener.com/latest/dex/pairs/robinhood/{CONTROL_POOL}", ds_pairs)
    show("geckoterminal pool", f"https://api.geckoterminal.com/api/v2/networks/robinhood/pools/{POOL_ID}", gt_pool)
    show("geckoterminal token", f"https://api.geckoterminal.com/api/v2/networks/robinhood/tokens/{TOKEN}", gt_pool)
    show("geckoterminal new_pools", "https://api.geckoterminal.com/api/v2/networks/robinhood/new_pools", gt_pool)
    show("geckoterminal control (a live Pons pool)",
         f"https://api.geckoterminal.com/api/v2/networks/robinhood/pools/{CONTROL_POOL}", gt_pool)


if __name__ == "__main__":
    sys.exit(main())
