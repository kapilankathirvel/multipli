"""
fetch_data.py – Data collection for the OracleGuard validation study (V4)
=========================================================================
Fetches:
  1. Chainlink PAXG/USD round history (archive RPC, real on-chain)
  2. PAXG-USD hourly prices (yfinance)
  3. Gold spot XAU/USD hourly prices (yfinance, ticker GC=F)
  4. Chainlink USDC/USD rounds around SVB depeg (Mar 10-13 2023)

All data written to research/data/  as .csv files.

Usage:
  python research/fetch_data.py

Requires:  pandas  numpy  yfinance  requests
Install:   pip install pandas numpy yfinance requests
"""

from __future__ import annotations

import json
import os
import struct
import sys
import time
from pathlib import Path

import pandas as pd
import requests

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE = Path(__file__).parent
DATA = BASE / "data"
DATA.mkdir(exist_ok=True)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
RPC_URL = os.environ.get(
    "ETH_RPC_URL", "https://mainnet.gateway.tenderly.co"
)
FORK_BLOCK = 26_011_000   # pin for determinism (CLAUDE.md)

# Chainlink proxy addresses (Constants.sol / CLAUDE.md)
CL_PAXG_USD  = "0x9944D86CEB9160aF5C5feB251FD671923323f8C3"
CL_USDC_USD  = "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6"

# Function selectors
SEL_LATEST_ROUND_DATA = "0xfeaf968c"   # latestRoundData()
SEL_GET_ROUND_DATA    = "0x9a6fc8f5"   # getRoundData(uint80)
SEL_DECIMALS          = "0x313ce567"   # decimals()

# ---------------------------------------------------------------------------
# Minimal JSON-RPC helpers (no web3 dependency)
# ---------------------------------------------------------------------------
_rpc_id = 0


def _rpc(method: str, params: list) -> dict:
    global _rpc_id
    _rpc_id += 1
    resp = requests.post(
        RPC_URL,
        json={"jsonrpc": "2.0", "id": _rpc_id, "method": method, "params": params},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"RPC error: {data['error']}")
    return data["result"]


def eth_call(to: str, data: str, block: str = "latest") -> str:
    return _rpc("eth_call", [{"to": to, "data": data}, block])


def _pad32(val: int) -> str:
    return hex(val)[2:].zfill(64)


def _decode_int(hex_str: str, offset: int = 0) -> int:
    b = bytes.fromhex(hex_str.replace("0x", ""))
    return int.from_bytes(b[offset * 32: (offset + 1) * 32], "big")


def _decode_signed_int(hex_str: str, offset: int = 0) -> int:
    b = bytes.fromhex(hex_str.replace("0x", ""))
    raw = b[offset * 32: (offset + 1) * 32]
    value = int.from_bytes(raw, "big")
    # treat as signed 256-bit
    if value >= (1 << 255):
        value -= 1 << 256
    return value


# ---------------------------------------------------------------------------
# Chainlink helpers
# ---------------------------------------------------------------------------
def cl_latest_round(proxy: str) -> dict:
    """Call latestRoundData() on a Chainlink aggregator proxy."""
    raw = eth_call(proxy, SEL_LATEST_ROUND_DATA)
    raw = raw.replace("0x", "")
    return {
        "roundId":         _decode_int(raw, 0),
        "answer":          _decode_signed_int(raw, 1),
        "startedAt":       _decode_int(raw, 2),
        "updatedAt":       _decode_int(raw, 3),
        "answeredInRound": _decode_int(raw, 4),
    }


def cl_round(proxy: str, round_id: int) -> dict | None:
    """Call getRoundData(roundId). Returns None on revert."""
    data = SEL_GET_ROUND_DATA + _pad32(round_id)
    try:
        raw = eth_call(proxy, data)
        raw = raw.replace("0x", "")
        if len(raw) < 5 * 64:
            return None
        return {
            "roundId":         _decode_int(raw, 0),
            "answer":          _decode_signed_int(raw, 1),
            "startedAt":       _decode_int(raw, 2),
            "updatedAt":       _decode_int(raw, 3),
            "answeredInRound": _decode_int(raw, 4),
        }
    except Exception:
        return None


def cl_decimals(proxy: str) -> int:
    raw = eth_call(proxy, SEL_DECIMALS)
    return _decode_int(raw.replace("0x", ""), 0)


def fetch_cl_rounds(
    proxy: str,
    label: str,
    max_rounds: int = 2000,
    start_round_id: int | None = None,
) -> pd.DataFrame:
    """
    Walk backwards from the latest round, collecting up to max_rounds entries.
    Returns a DataFrame with columns: roundId, answer_usd, updatedAt, ts_dt.
    """
    print(f"  Fetching Chainlink {label} rounds (up to {max_rounds})...")
    try:
        latest = cl_latest_round(proxy)
        decimals = cl_decimals(proxy)
    except Exception as e:
        print(f"  WARNING: Could not fetch {label}: {e}")
        return pd.DataFrame()

    latest_id = latest["roundId"]
    if start_round_id is not None:
        latest_id = start_round_id

    rows = []
    phase_id = (latest_id >> 64) & 0xFFFF
    agg_round = latest_id & 0xFFFFFFFFFFFFFFFF

    consecutive_fails = 0
    for rid in range(agg_round, max(0, agg_round - max_rounds), -1):
        full_round_id = (phase_id << 64) | rid
        r = cl_round(proxy, full_round_id)
        if r is None or r["answer"] <= 0 or r["updatedAt"] == 0:
            consecutive_fails += 1
            if consecutive_fails > 5:
                break
            continue
        consecutive_fails = 0
        rows.append({
            "roundId": r["roundId"],
            "answer_usd": r["answer"] / (10 ** decimals),
            "updatedAt": r["updatedAt"],
        })
        # Polite rate-limiting
        if len(rows) % 100 == 0:
            time.sleep(0.1)

    if not rows:
        return pd.DataFrame()

    df = pd.DataFrame(rows)
    df["ts_dt"] = pd.to_datetime(df["updatedAt"], unit="s", utc=True)
    df = df.sort_values("updatedAt").reset_index(drop=True)
    print(f"    Got {len(df)} rounds, {df['ts_dt'].min()} to {df['ts_dt'].max()}")
    return df


# ---------------------------------------------------------------------------
# yfinance helpers
# ---------------------------------------------------------------------------
def fetch_yfinance(ticker: str, start: str, end: str, interval: str = "1h") -> pd.DataFrame:
    """Fetch hourly OHLCV from yfinance. Returns DataFrame with columns: ts_dt, close."""
    try:
        import yfinance as yf
    except ImportError:
        print("  yfinance not installed. pip install yfinance")
        return pd.DataFrame()

    print(f"  Fetching {ticker} ({interval}) {start} -> {end} ...")
    try:
        df = yf.download(ticker, start=start, end=end, interval=interval, progress=False)
        if df.empty:
            print(f"  WARNING: no data for {ticker}")
            return pd.DataFrame()
        df = df[["Close"]].rename(columns={"Close": "close"})
        df.index = pd.to_datetime(df.index, utc=True)
        df.index.name = "ts_dt"
        df = df.reset_index()
        print(f"    Got {len(df)} rows")
        return df
    except Exception as e:
        print(f"  WARNING: yfinance error for {ticker}: {e}")
        return pd.DataFrame()


# ---------------------------------------------------------------------------
# Main data collection
# ---------------------------------------------------------------------------
def main():
    print("OracleGuard V4 Data Collection")
    print("=" * 50)

    # 1. Chainlink PAXG/USD rounds
    out = DATA / "cl_paxg_rounds.csv"
    if out.exists():
        print(f"  [SKIP] {out.name} already exists")
    else:
        df = fetch_cl_rounds(CL_PAXG_USD, "PAXG/USD", max_rounds=1500)
        if not df.empty:
            df.to_csv(out, index=False)
            print(f"  Saved {out.name} ({len(df)} rows)")
        else:
            print(f"  WARNING: No PAXG/USD data fetched")

    # 2. PAXG-USD hourly (yfinance)
    out = DATA / "paxg_hourly.csv"
    if out.exists():
        print(f"  [SKIP] {out.name} already exists")
    else:
        df = fetch_yfinance("PAXG-USD", "2021-01-01", "2026-09-19", "1h")
        if not df.empty:
            df.to_csv(out, index=False)
            print(f"  Saved {out.name} ({len(df)} rows)")

    # 3. Gold spot GC=F hourly (yfinance)
    out = DATA / "gold_hourly.csv"
    if out.exists():
        print(f"  [SKIP] {out.name} already exists")
    else:
        df = fetch_yfinance("GC=F", "2021-01-01", "2026-09-19", "1h")
        if not df.empty:
            df.to_csv(out, index=False)
            print(f"  Saved {out.name} ({len(df)} rows)")

    # 4. Chainlink USDC/USD around SVB (Mar 10-13 2023)
    out = DATA / "cl_usdc_svb.csv"
    if out.exists():
        print(f"  [SKIP] {out.name} already exists")
    else:
        df = fetch_cl_rounds(CL_USDC_USD, "USDC/USD (SVB)", max_rounds=500)
        if not df.empty:
            # Filter to SVB period + some context
            svb_start = pd.Timestamp("2023-03-09", tz="UTC")
            svb_end   = pd.Timestamp("2023-03-16", tz="UTC")
            df_svb = df[(df["ts_dt"] >= svb_start) & (df["ts_dt"] <= svb_end)]
            if df_svb.empty:
                df_svb = df   # save all if filter misses
            df_svb.to_csv(out, index=False)
            print(f"  Saved {out.name} ({len(df_svb)} rows, SVB period)")

    print("\nDone. Files written to research/data/")


if __name__ == "__main__":
    main()
