"""
monte_carlo.py – Fault-injection engine for OracleGuard V4 validation study
============================================================================
Implements the fault types and correlated-failure simulation described in
review.md §R2.5.

Fault types (injected into k of the 4 sources):
  spike   – sudden price jump (±5 to ±90 %)
  drift   – slow linear bias building over the window
  freeze  – stale (ok=True but updatedAt freezes → exceeds maxAge)
  clamp   – price clamped to a floor or ceiling (like LUNA minAnswer)
  delay   – updatedAt artificially lagged (simulates push oracle congestion)

k ∈ {1, 2, 3, 4} — k≥2 covers correlated failures.

Source ordering matches the aggregator: 0=Chainlink, 1=Pyth, 2=RedStone, 3=DEX TWAP
Weights: [2, 2, 2, 1]  maxAges: [90000, 3600, 3600, 3600]

Usage:
  from monte_carlo import inject_faults, run_monte_carlo

  results_df = run_monte_carlo(price_series, n_runs=1000, seed=42)
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import List, Optional, Dict

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
    DEFAULT_QUORUM_MIN,
    DEFAULT_D_MAX_BPS,
    DEFAULT_MAD_K,
    DEFAULT_MAD_FLOOR_BPS,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WEIGHTS   = [2, 2, 2, 1]
MAX_AGES  = [90_000, 3_600, 3_600, 3_600]  # Chainlink 25h, rest 1h
N_SOURCES = 4

# Thresholds to sweep (GREEN cut-off, epsilon %)
THRESHOLD_SWEEP = [
    {"green_score": 70, "eps_pct": 1.0,  "label": "G70-e1"},
    {"green_score": 70, "eps_pct": 1.5,  "label": "G70-e1.5"},
    {"green_score": 70, "eps_pct": 3.0,  "label": "G70-e3"},
    {"green_score": 80, "eps_pct": 1.0,  "label": "G80-e1"},
    {"green_score": 80, "eps_pct": 1.5,  "label": "G80-e1.5 (default)"},
    {"green_score": 80, "eps_pct": 3.0,  "label": "G80-e3"},
    {"green_score": 90, "eps_pct": 1.0,  "label": "G90-e1"},
    {"green_score": 90, "eps_pct": 1.5,  "label": "G90-e1.5"},
    {"green_score": 90, "eps_pct": 3.0,  "label": "G90-e3"},
]

FAULT_TYPES = ["spike", "drift", "freeze", "clamp", "delay"]


# ---------------------------------------------------------------------------
# Fault injection helpers
# ---------------------------------------------------------------------------
@dataclass
class FaultSpec:
    fault_type: str    # spike|drift|freeze|clamp|delay
    magnitude: float   # interpreted differently per type (see below)
    direction: int     # +1 or -1


def _apply_fault(
    obs: Observation,
    truth_price: float,
    fault: FaultSpec,
    step: int,
    window: int,
    now: int,
    max_age: int,
) -> Observation:
    """
    Apply a single fault to one observation.

    spike:  price += direction * magnitude * truth  (magnitude = fraction e.g. 0.30)
    drift:  price += direction * magnitude * truth * (step/window)
    freeze: updatedAt frozen at obs.updated_at - max_age - 1  (immediately stale)
    clamp:  price = max(truth * magnitude, price) if dir=-1 else min(truth * magnitude, price)
    delay:  updatedAt -= magnitude_seconds
    """
    p = float(obs.price)
    t = float(truth_price)

    if fault.fault_type == "spike":
        faulty_p = t * (1.0 + fault.direction * fault.magnitude)
        return Observation(price=max(0, int(faulty_p)), updated_at=obs.updated_at, ok=obs.ok)

    elif fault.fault_type == "drift":
        frac = step / max(window - 1, 1)
        faulty_p = t * (1.0 + fault.direction * fault.magnitude * frac)
        return Observation(price=max(0, int(faulty_p)), updated_at=obs.updated_at, ok=obs.ok)

    elif fault.fault_type == "freeze":
        # updatedAt is pushed into the past beyond maxAge
        stale_at = now - max_age - 3_600
        return Observation(price=obs.price, updated_at=stale_at, ok=obs.ok)

    elif fault.fault_type == "clamp":
        # magnitude = clamp level as fraction of truth
        clamp_level = int(t * fault.magnitude)
        if fault.direction == -1:
            # floor: price cannot go below clamp_level (like minAnswer)
            faulty_p = max(obs.price, clamp_level)
        else:
            # ceiling: price cannot go above clamp_level
            faulty_p = min(obs.price, clamp_level)
        return Observation(price=faulty_p, updated_at=obs.updated_at, ok=obs.ok)

    elif fault.fault_type == "delay":
        # magnitude = lag in seconds
        lag = int(fault.magnitude)
        return Observation(price=obs.price, updated_at=max(0, obs.updated_at - lag), ok=obs.ok)

    return obs


# ---------------------------------------------------------------------------
# Build observations from a truth price row
# ---------------------------------------------------------------------------
def truth_to_observations(
    truth_price: float,
    now: int,
    noise_pct: float = 0.001,
    rng: Optional[random.Random] = None,
) -> List[Observation]:
    """
    Convert a single truth price into 4 fresh observations with small independent noise.
    Used for the Monte-Carlo baseline (no faults).
    """
    if rng is None:
        rng = random.Random()
    obs = []
    for i in range(N_SOURCES):
        noise = 1.0 + rng.uniform(-noise_pct, noise_pct)
        price_wad = int(truth_price * noise * 1e18)
        obs.append(Observation(price=price_wad, updated_at=now, ok=True))
    return obs


# ---------------------------------------------------------------------------
# Single-run: inject k faults of a given type, return the Reading
# ---------------------------------------------------------------------------
def inject_faults(
    truth_price: float,
    now: int,
    fault_type: str,
    k: int,
    magnitude: float,
    direction: int = -1,
    step: int = 0,
    window: int = 1,
    noise_pct: float = 0.001,
    rng: Optional[random.Random] = None,
) -> tuple[Reading, List[int]]:
    """
    Build observations, inject faults into k randomly chosen sources, return Reading.

    Returns (reading, faulted_source_indices).
    """
    if rng is None:
        rng = random.Random()
    base_obs = truth_to_observations(truth_price, now, noise_pct=noise_pct, rng=rng)
    faulted_indices = rng.sample(range(N_SOURCES), min(k, N_SOURCES))
    fault = FaultSpec(fault_type=fault_type, magnitude=magnitude, direction=direction)

    final_obs = list(base_obs)
    for i in faulted_indices:
        final_obs[i] = _apply_fault(
            base_obs[i], int(truth_price * 1e18), fault, step, window, now, MAX_AGES[i]
        )

    reading = aggregate(final_obs, WEIGHTS, MAX_AGES, now=now)
    return reading, faulted_indices


# ---------------------------------------------------------------------------
# FP / FN classification
# ---------------------------------------------------------------------------
def classify(
    reading: Reading,
    truth_price_wad: int,
    oracle_wrong_pct: float = 2.0,   # review.md §R2.4: gold 2%, volatile 5%
    green_score: int = 80,
) -> dict:
    """
    Classify one reading as FP or FN on the MINT side (review.md §R2.4).

    oracle_wrong: |mid - truth| > oracle_wrong_pct %
    FN (dangerous): oracle wrong AND state = GREEN
    FP (annoying):  oracle right AND state = RED
    cautious:       oracle right AND state = YELLOW
    """
    if not reading.ok or reading.mid == 0:
        state = RED
        oracle_wrong = True   # no quorum = wrong by definition
    else:
        wrong_thr = truth_price_wad * oracle_wrong_pct / 100
        oracle_wrong = abs(reading.mid - truth_price_wad) > wrong_thr
        # Determine state from score
        if reading.score >= green_score:
            state = GREEN
        elif reading.score >= 50:
            state = YELLOW
        else:
            state = RED

    fn = oracle_wrong and state == GREEN
    fp = (not oracle_wrong) and state == RED
    cautious = (not oracle_wrong) and state == YELLOW

    return {
        "state": state,
        "state_name": STATE_NAMES[state],
        "oracle_wrong": oracle_wrong,
        "fn": fn,
        "fp": fp,
        "cautious": cautious,
        "score": reading.score,
        "mid_wad": reading.mid,
        "ok": reading.ok,
    }


# ---------------------------------------------------------------------------
# Full Monte-Carlo run
# ---------------------------------------------------------------------------
def run_monte_carlo(
    price_series: pd.Series,
    n_runs_per_cell: int = 500,
    seed: int = 42,
    green_score: int = 80,
    oracle_wrong_pct: float = 2.0,
    verbose: bool = True,
) -> pd.DataFrame:
    """
    For each (fault_type, k) cell, inject faults into n_runs_per_cell random
    time-steps and classify each result.

    price_series: pandas Series of truth prices (USD float), indexed by timestamp.
    Returns a DataFrame with per-cell statistics.
    """
    rng = random.Random(seed)
    prices = price_series.dropna().values
    timestamps = price_series.dropna().index

    if len(prices) == 0:
        raise ValueError("price_series is empty")

    rows = []
    total_cells = len(FAULT_TYPES) * 4
    done = 0

    for fault_type in FAULT_TYPES:
        for k in range(1, 5):  # k = 1,2,3,4
            fns, fps, cautions, total = 0, 0, 0, 0

            # Magnitude varies by fault type
            if fault_type == "spike":
                magnitudes = [0.05, 0.15, 0.30, 0.50, 0.90]
            elif fault_type == "drift":
                magnitudes = [0.02, 0.05, 0.10, 0.20]
            elif fault_type == "freeze":
                magnitudes = [0.0]   # magnitude unused for freeze
            elif fault_type == "clamp":
                magnitudes = [0.05, 0.10, 0.50]  # clamp floor as fraction of truth
            elif fault_type == "delay":
                magnitudes = [1_800, 3_600, 7_200, 14_400]  # lag in seconds
            else:
                magnitudes = [0.10]

            for _ in range(n_runs_per_cell):
                idx = rng.randint(0, len(prices) - 1)
                truth = prices[idx]
                now = 1_700_000_000 + idx * 3600   # synthetic timestamps

                # random magnitude
                mag = rng.choice(magnitudes)
                direction = rng.choice([-1, 1])

                reading, _ = inject_faults(
                    truth_price=truth,
                    now=now,
                    fault_type=fault_type,
                    k=k,
                    magnitude=mag,
                    direction=direction,
                    rng=rng,
                )
                truth_wad = int(truth * 1e18)
                c = classify(reading, truth_wad, oracle_wrong_pct, green_score)

                fns     += int(c["fn"])
                fps     += int(c["fp"])
                cautions += int(c["cautious"])
                total   += 1

            fn_rate  = fns     / total * 100
            fp_rate  = fps     / total * 100
            cau_rate = cautions / total * 100

            rows.append({
                "fault_type": fault_type,
                "k": k,
                "n_runs": total,
                "fn_count": fns,
                "fp_count": fps,
                "cautious_count": cautions,
                "fn_rate_pct": round(fn_rate, 2),
                "fp_rate_pct": round(fp_rate, 2),
                "cautious_rate_pct": round(cau_rate, 2),
            })

            done += 1
            if verbose:
                print(
                    f"  [{done:2d}/{total_cells}] {fault_type:6s} k={k}  "
                    f"FN={fn_rate:.1f}%  FP={fp_rate:.1f}%  cautious={cau_rate:.1f}%"
                )

    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Threshold sweep
# ---------------------------------------------------------------------------
def run_threshold_sweep(
    price_series: pd.Series,
    n_runs: int = 500,
    seed: int = 42,
    verbose: bool = True,
) -> pd.DataFrame:
    """Run Monte-Carlo across all threshold settings in THRESHOLD_SWEEP."""
    rows = []
    for cfg in THRESHOLD_SWEEP:
        if verbose:
            print(f"  Sweep: {cfg['label']}")
        # Run with k=1 spike faults as a representative single-source scenario
        df = run_monte_carlo(
            price_series,
            n_runs_per_cell=n_runs,
            seed=seed,
            green_score=cfg["green_score"],
            oracle_wrong_pct=cfg["eps_pct"],
            verbose=False,
        )
        df["label"] = cfg["label"]
        df["green_score"] = cfg["green_score"]
        df["eps_pct"] = cfg["eps_pct"]
        rows.append(df)

    return pd.concat(rows, ignore_index=True)


# ---------------------------------------------------------------------------
# CLI for quick test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys

    print("Quick Monte-Carlo smoke test (100 runs, synthetic prices)")
    np.random.seed(42)
    synthetic = pd.Series(
        np.random.normal(4372.0, 50, 500),
        index=range(500),
    )
    synthetic = synthetic.clip(1000)

    df = run_monte_carlo(synthetic, n_runs_per_cell=100, verbose=True)
    print("\nResults summary:")
    print(df[["fault_type", "k", "fn_rate_pct", "fp_rate_pct"]].to_string(index=False))
