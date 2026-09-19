"""
metrics.py – Analysis & risk quantification for OracleGuard V4 validation study
================================================================================
Implements:
  1. Incident trace analysis (I1–I9): run each through og_model, classify FP/FN
  2. Bad debt comparison: legacy pipeline vs OracleGuard (review.md §R4)
  3. Unjust liquidation count (mint-side FN where collateral ratio matters)
  4. Threshold sweep summary
  5. Chart generation (saved to research/out/)

Usage:
  from metrics import run_incident_analysis, bad_debt_comparison, make_charts
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import List, Dict

import numpy as np
import pandas as pd

from og_model import (
    Observation,
    Reading,
    aggregate,
    GREEN,
    YELLOW,
    RED,
    STATE_NAMES,
    WEIGHTS as _WEIGHTS,
    MAX_AGES as _MAX_AGES,
)
from monte_carlo import classify, FAULT_TYPES

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE = Path(__file__).parent
INCIDENTS_DIR = BASE / "incidents"
OUT_DIR = BASE / "out"
OUT_DIR.mkdir(exist_ok=True)

WEIGHTS  = _WEIGHTS
MAX_AGES = _MAX_AGES

# Default parameters
GREEN_SCORE = 80
ORACLE_WRONG_PCT_GOLD = 2.0   # review.md §R2.4

# Bad-debt scenario constants (from CLAUDE.md / review.md §R4.1)
VAULT_DEBT_USD       = 1_000_000      # $1M reference vault
LEGACY_REMAINING_CAP = 956_971        # legacy remaining ceiling (1M - 43,029 debt)
OG_GREEN_GAP         = 250_000        # $250k per hour in GREEN
OG_YELLOW_GAP        =  50_000        # $50k total in YELLOW
HOURS_UNDETECTED_I6  = 4              # assume 4h for Mango-class correlated attack


# ---------------------------------------------------------------------------
# Incident loader
# ---------------------------------------------------------------------------
def load_incident(path: Path) -> pd.DataFrame:
    """Load an incident CSV, handling stale_flags as a string column."""
    df = pd.read_csv(path, comment="#")
    df.columns = df.columns.str.strip()
    return df


def incident_to_observations(
    row: pd.Series,
    now: int,
    stale_flags_str: str,
) -> List[Observation]:
    """
    Convert one incident CSV row into 4 Observation objects.
    stale_flags_str: 4-char string like "1000" (1=stale per source)
    Prices in the CSV are raw USD floats; convert to WAD.
    """
    sources = ["chainlink", "pyth", "redstone", "dex"]
    flags = str(stale_flags_str).zfill(4)
    obs = []
    for i, src in enumerate(sources):
        price_usd = float(row.get(src, row.get("truth", 0)))
        price_wad = int(price_usd * 1e18)
        stale = flags[i] == "1"
        updated_at = now - MAX_AGES[i] - 3_600 if stale else now
        obs.append(Observation(price=price_wad, updated_at=updated_at, ok=True))
    return obs


# ---------------------------------------------------------------------------
# Incident analysis
# ---------------------------------------------------------------------------
def run_incident_analysis(verbose: bool = True) -> pd.DataFrame:
    """
    Run all I1–I9 incident traces through the model, classify FP/FN,
    return a summary DataFrame.
    """
    incident_files = sorted(INCIDENTS_DIR.glob("I*.csv"))
    if not incident_files:
        print("  WARNING: No incident CSV files found in", INCIDENTS_DIR)
        return pd.DataFrame()

    rows = []
    now_base = 1_700_000_000

    for fpath in incident_files:
        label = fpath.stem
        df = load_incident(fpath)

        step_results = []
        for idx, row in df.iterrows():
            now = now_base + int(idx) * 3_600
            stale_flags = str(row.get("stale_flags", "0000")).zfill(4)
            obs = incident_to_observations(row, now, stale_flags)
            reading = aggregate(obs, WEIGHTS, MAX_AGES, now=now)
            truth_wad = int(float(row["truth"]) * 1e18)
            c = classify(reading, truth_wad, ORACLE_WRONG_PCT_GOLD, GREEN_SCORE)
            c["t"] = row["t"]
            c["truth"] = row["truth"]
            step_results.append(c)

        step_df = pd.DataFrame(step_results)
        n_fn      = step_df["fn"].sum()
        n_fp      = step_df["fp"].sum()
        n_cautious = step_df["cautious"].sum()
        n_total   = len(step_df)

        rows.append({
            "incident": label,
            "n_steps": n_total,
            "fn_steps": int(n_fn),
            "fp_steps": int(n_fp),
            "cautious_steps": int(n_cautious),
            "fn_rate_pct": round(n_fn / n_total * 100, 1) if n_total > 0 else 0,
            "fp_rate_pct": round(n_fp / n_total * 100, 1) if n_total > 0 else 0,
        })

        if verbose:
            print(
                f"  {label:30s}  steps={n_total}  FN={int(n_fn)}  FP={int(n_fp)}"
                f"  cautious={int(n_cautious)}"
            )

    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Bad debt comparison (review.md §R4.1 + §R4.3)
# ---------------------------------------------------------------------------
def bad_debt_comparison() -> pd.DataFrame:
    """
    Deterministic bounds + measured estimates from review.md §R4.1.
    Returns a table ready for the RESULTS.md report.
    """
    rows = [
        {
            "scenario": "Wrong price in GREEN (undetected, e.g. I6 Mango-class)",
            "legacy_max_exposure_usd": LEGACY_REMAINING_CAP,
            "og_max_exposure_usd": OG_GREEN_GAP,
            "reduction_pct": round((1 - OG_GREEN_GAP / LEGACY_REMAINING_CAP) * 100, 1),
            "notes": f"OracleGuard: <= ${OG_GREEN_GAP:,}/h greenGap rate limit",
        },
        {
            "scenario": "Degraded (YELLOW)",
            "legacy_max_exposure_usd": LEGACY_REMAINING_CAP,
            "og_max_exposure_usd": OG_YELLOW_GAP,
            "reduction_pct": round((1 - OG_YELLOW_GAP / LEGACY_REMAINING_CAP) * 100, 1),
            "notes": f"OracleGuard: <= ${OG_YELLOW_GAP:,} total, no refill",
        },
        {
            "scenario": "Detected (RED)",
            "legacy_max_exposure_usd": LEGACY_REMAINING_CAP,
            "og_max_exposure_usd": 0,
            "reduction_pct": 100.0,
            "notes": "OracleGuard: $0 new minting allowed",
        },
        {
            "scenario": "Stale feed (e.g. I5: 186h-old price still valid in legacy)",
            "legacy_max_exposure_usd": LEGACY_REMAINING_CAP,
            "og_max_exposure_usd": 0,
            "reduction_pct": 100.0,
            "notes": "OracleGuard: stale -> RED within one sync",
        },
        {
            "scenario": "S3 feed compromise (10 PAXG, legacy measured on fork)",
            "legacy_max_exposure_usd": 268_595,
            "og_max_exposure_usd": 0,
            "reduction_pct": 100.0,
            "notes": "$312,319 minted vs $43,724 collateral -> $268,595 bad debt (legacy). Target: $0 (K6).",
        },
        {
            "scenario": "Correlated manipulation (I6-class), 4h undetected",
            "legacy_max_exposure_usd": LEGACY_REMAINING_CAP,
            "og_max_exposure_usd": OG_GREEN_GAP * HOURS_UNDETECTED_I6,
            "reduction_pct": round(
                (1 - OG_GREEN_GAP * HOURS_UNDETECTED_I6 / LEGACY_REMAINING_CAP) * 100, 1
            ),
            "notes": f"MaxLoss = greenGap x {HOURS_UNDETECTED_I6}h = ${OG_GREEN_GAP * HOURS_UNDETECTED_I6:,}",
        },
    ]
    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Chart helpers (matplotlib)
# ---------------------------------------------------------------------------
def _import_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        return plt
    except ImportError:
        print("  matplotlib not installed; skipping charts. pip install matplotlib")
        return None


def make_charts(mc_df: pd.DataFrame, incident_df: pd.DataFrame, sweep_df: pd.DataFrame):
    """Generate and save all charts to research/out/."""
    plt = _import_matplotlib()
    if plt is None:
        return

    # 1. Confusion matrix heatmap: FN rate by fault_type x k
    _plot_confusion_matrix(plt, mc_df)

    # 2. Threshold sweep: FN vs FP for default fault mix
    _plot_threshold_sweep(plt, sweep_df)

    # 3. Bad debt comparison bar chart
    _plot_bad_debt(plt)

    # 4. Incident FP/FN summary bar chart
    if not incident_df.empty:
        _plot_incident_summary(plt, incident_df)

    print(f"  Charts saved to {OUT_DIR}/")


def _plot_confusion_matrix(plt, mc_df: pd.DataFrame):
    import matplotlib.pyplot as plt2
    import matplotlib.colors as mcolors

    if mc_df.empty:
        return

    pivot = mc_df.pivot_table(
        index="fault_type", columns="k", values="fn_rate_pct", aggfunc="mean"
    )
    fig, ax = plt2.subplots(figsize=(8, 5))
    im = ax.imshow(pivot.values, cmap="RdYlGn_r", vmin=0, vmax=50, aspect="auto")
    ax.set_xticks(range(len(pivot.columns)))
    ax.set_xticklabels([f"k={c}" for c in pivot.columns])
    ax.set_yticks(range(len(pivot.index)))
    ax.set_yticklabels(pivot.index)
    plt2.colorbar(im, ax=ax, label="FN rate (%)")
    ax.set_title("False-Negative Rate: Fault Type x Correlated Sources (k)")
    ax.set_xlabel("Sources Simultaneously Faulted (k)")
    ax.set_ylabel("Fault Type")
    for i in range(len(pivot.index)):
        for j in range(len(pivot.columns)):
            val = pivot.values[i, j]
            if not np.isnan(val):
                ax.text(j, i, f"{val:.1f}%", ha="center", va="center", fontsize=9,
                        color="white" if val > 25 else "black")
    plt2.tight_layout()
    plt2.savefig(OUT_DIR / "confusion_matrix.png", dpi=150)
    plt2.close()


def _plot_threshold_sweep(plt, sweep_df: pd.DataFrame):
    import matplotlib.pyplot as plt2

    if sweep_df.empty:
        return

    summary = sweep_df.groupby("label").agg(
        fn_rate=("fn_rate_pct", "mean"),
        fp_rate=("fp_rate_pct", "mean"),
    ).reset_index()

    fig, ax = plt2.subplots(figsize=(10, 5))
    ax.scatter(summary["fp_rate"], summary["fn_rate"], s=80, zorder=5)
    for _, row in summary.iterrows():
        ax.annotate(
            row["label"],
            (row["fp_rate"], row["fn_rate"]),
            fontsize=7, textcoords="offset points", xytext=(5, 3),
        )
    ax.set_xlabel("FP Rate (%) — unnecessary restriction")
    ax.set_ylabel("FN Rate (%) — dangerous miss")
    ax.set_title("Threshold Sweep: FP vs FN trade-off (lower-left = better)")
    ax.grid(True, alpha=0.3)
    plt2.tight_layout()
    plt2.savefig(OUT_DIR / "threshold_sweep.png", dpi=150)
    plt2.close()


def _plot_bad_debt(plt):
    import matplotlib.pyplot as plt2

    df = bad_debt_comparison()
    labels = [s[:40] for s in df["scenario"]]
    legacy = df["legacy_max_exposure_usd"] / 1000
    og = df["og_max_exposure_usd"] / 1000

    x = range(len(labels))
    fig, ax = plt2.subplots(figsize=(12, 6))
    width = 0.35
    ax.bar([i - width / 2 for i in x], legacy, width, label="Legacy rwaUSD", color="#e74c3c", alpha=0.85)
    ax.bar([i + width / 2 for i in x], og, width, label="OracleGuard", color="#2ecc71", alpha=0.85)
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, rotation=25, ha="right", fontsize=8)
    ax.set_ylabel("Max exposure ($k)")
    ax.set_title("Risk Reduction: Legacy vs OracleGuard (review.md §R4)")
    ax.legend()
    ax.grid(True, alpha=0.3, axis="y")
    plt2.tight_layout()
    plt2.savefig(OUT_DIR / "bad_debt_comparison.png", dpi=150)
    plt2.close()


def _plot_incident_summary(plt, incident_df: pd.DataFrame):
    import matplotlib.pyplot as plt2

    fig, ax = plt2.subplots(figsize=(12, 5))
    x = range(len(incident_df))
    ax.bar([i - 0.2 for i in x], incident_df["fn_steps"], 0.35,
           label="FN steps (dangerous)", color="#e74c3c", alpha=0.85)
    ax.bar([i + 0.2 for i in x], incident_df["fp_steps"], 0.35,
           label="FP steps (annoying)", color="#f39c12", alpha=0.85)
    ax.set_xticks(list(x))
    ax.set_xticklabels(incident_df["incident"], rotation=20, ha="right", fontsize=9)
    ax.set_ylabel("Steps")
    ax.set_title("FP/FN per Historical Incident (I1-I9)")
    ax.legend()
    ax.grid(True, alpha=0.3, axis="y")
    plt2.tight_layout()
    plt2.savefig(OUT_DIR / "incident_fp_fn.png", dpi=150)
    plt2.close()
