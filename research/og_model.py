"""
og_model.py – Python mirror of OracleGuardAggregator.sol + RiskController.sol
==============================================================================
Implements the score formula from review.md §R1.2 with integer arithmetic that
matches Solidity's uint256 math.  The parity vectors in §R1.4 must pass.

Weights: Chainlink=2, Pyth=2, RedStone=2, DEX TWAP=1  (total = 7)
Parameters (from CONTRACTS_SPEC / review.md):
  quorumMin   = 2   (need ≥ 2 inliers)
  dMaxBps     = 200 (2 % dispersion)
  madK        = 3
  madFloorBps = 10  (0.1 %)
  BPS         = 10_000

State machine thresholds (review.md §R3, RiskController defaults):
  greenScore  = 80
  yellowScore = 50
  epsBps      = 150   (1.5 %)  RED if live.lo < osm * (1 - 1.5%)
  epsLiqBps   = 300   (3 %)    GUARD if live.hi * (1-3%) > osm
  kUp         = 3              healthy syncs to upgrade one level
  upgradeInterval = 600        10 min between counted syncs
  guardMaxDuration = 21600     6 h guard auto-expiry
  refillInterval   = 3600      1 h GREEN rate-limit window

Usage:
  from og_model import aggregate, STATE_NAMES, StateMachine

  # Build observations
  obs = [
    {"price": 4372.478e18, "updatedAt": now, "ok": True},  # Chainlink
    {"price": 4372.478e18, "updatedAt": now, "ok": True},  # Pyth
    {"price": 4372.478e18, "updatedAt": now, "ok": True},  # RedStone
    {"price": 4372.478e18, "updatedAt": now, "ok": True},  # DEX
  ]
  weights = [2, 2, 2, 1]
  max_ages = [90000, 3600, 3600, 3600]   # seconds
  reading = aggregate(obs, weights, max_ages, now=now)
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import List, Optional

# ---------------------------------------------------------------------------
# Constants (mirrors Solidity constants)
# ---------------------------------------------------------------------------
BPS: int = 10_000        # 1e4 – basis-points denominator
MAX_PRICE: int = 10**36  # sanity cap from OracleGuardAggregator.sol

GREEN: int = 0
YELLOW: int = 1
RED: int = 2
STATE_NAMES = {GREEN: "GREEN", YELLOW: "YELLOW", RED: "RED"}

# Default aggregator parameters
DEFAULT_QUORUM_MIN: int = 2
DEFAULT_D_MAX_BPS: int = 200    # 2 %
DEFAULT_MAD_K: int = 3
DEFAULT_MAD_FLOOR_BPS: int = 10  # 0.1 %

# Default risk-controller thresholds
DEFAULT_GREEN_SCORE: int = 80
DEFAULT_YELLOW_SCORE: int = 50
DEFAULT_EPS_BPS: int = 150       # 1.5 %
DEFAULT_EPS_LIQ_BPS: int = 300   # 3 %
DEFAULT_K_UP: int = 3
DEFAULT_UPGRADE_INTERVAL: int = 600     # 10 min
DEFAULT_GUARD_MAX_DURATION: int = 21_600  # 6 h
DEFAULT_REFILL_INTERVAL: int = 3_600      # 1 h

# Public source config (used by metrics.py and monte_carlo.py)
WEIGHTS: list  = [2, 2, 2, 1]
MAX_AGES: list = [90_000, 3_600, 3_600, 3_600]  # Chainlink 25h, rest 1h


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class Observation:
    """Mirrors contracts/src/interfaces/IPriceSource.sol  Observation struct.
    price is in WAD (1e18 = $1.00).
    """
    price: int      # WAD
    updated_at: int  # unix timestamp (seconds)
    ok: bool


@dataclass
class Reading:
    """Mirrors IOracleGuard.sol  Reading struct."""
    mid: int = 0         # WAD weighted-median price of inliers
    lo: int = 0          # WAD lowest inlier
    hi: int = 0          # WAD highest inlier
    score: int = 0       # 0-100
    freshest_age: int = 0  # seconds
    n_fresh: int = 0
    n_inliers: int = 0
    ok: bool = False


# ---------------------------------------------------------------------------
# Math helpers  (exact mirrors of Solidity helpers)
# ---------------------------------------------------------------------------
def _abs_diff(a: int, b: int) -> int:
    return a - b if a > b else b - a


def _weighted_median(prices: List[int], weights: List[int]) -> int:
    """Weighted median: first price where cumulative weight >= total/2.
    prices and weights must be co-sorted by price ascending.
    Mirrors OracleGuardAggregator._weightedMedian.
    """
    total = sum(weights)
    cum = 0
    for p, w in zip(prices, weights):
        cum += w
        if cum * 2 >= total:
            return p
    return prices[-1]  # unreachable if inputs are valid


def _plain_median(values: List[int]) -> int:
    """Plain unweighted median (average of two middles for even n).
    Mirrors OracleGuardAggregator._median.
    """
    sv = sorted(values)
    n = len(sv)
    if n == 0:
        return 0
    mid = n // 2
    if n % 2 == 1:
        return sv[mid]
    return (sv[mid - 1] + sv[mid]) // 2   # integer division, same as Solidity


# ---------------------------------------------------------------------------
# Core aggregation  (mirrors OracleGuardAggregator._compute)
# ---------------------------------------------------------------------------
def aggregate(
    observations: List[Observation],
    weights: List[int],
    max_ages: List[int],
    now: int,
    quorum_min: int = DEFAULT_QUORUM_MIN,
    d_max_bps: int = DEFAULT_D_MAX_BPS,
    mad_k: int = DEFAULT_MAD_K,
    mad_floor_bps: int = DEFAULT_MAD_FLOOR_BPS,
) -> Reading:
    """
    Compute a Reading from raw observations.

    Parameters
    ----------
    observations : list of Observation (price in WAD, updated_at unix secs, ok bool)
    weights      : matching list of integer weights (e.g. [2,2,2,1])
    max_ages     : matching list of maxAge in seconds
    now          : current unix timestamp in seconds
    """
    r = Reading()
    n = len(observations)
    assert n == len(weights) == len(max_ages), "lengths must match"

    # Step 1: freshness filter
    fresh_idx = []
    for i, (obs, max_age) in enumerate(zip(observations, max_ages)):
        if _is_fresh(obs, now, max_age):
            fresh_idx.append(i)
    r.n_fresh = len(fresh_idx)
    if not fresh_idx:
        return r   # no fresh sources at all

    # Step 2: sort fresh by price
    fresh_idx.sort(key=lambda i: observations[i].price)

    # Step 3: MAD outlier filter → inliers
    fresh_prices = [observations[i].price for i in fresh_idx]
    fresh_weights = [weights[i] for i in fresh_idx]

    m0 = _weighted_median(fresh_prices, fresh_weights)
    devs = [_abs_diff(p, m0) for p in fresh_prices]
    mad = _plain_median(devs)
    floor_ = m0 * mad_floor_bps // BPS
    thr = mad_k * (mad if mad > floor_ else floor_)

    inlier_idx = [i for i in fresh_idx if _abs_diff(observations[i].price, m0) <= thr]
    inlier_weights = [weights[i] for i in inlier_idx]
    total_weight = sum(weights)
    inlier_weight = sum(inlier_weights)
    r.n_inliers = len(inlier_idx)

    # Step 4: final price (weighted median of inliers, sorted by price)
    inlier_idx.sort(key=lambda i: observations[i].price)
    inlier_prices = [observations[i].price for i in inlier_idx]
    inlier_weights_sorted = [weights[i] for i in inlier_idx]

    if not inlier_idx:
        return r

    r.mid = _weighted_median(inlier_prices, inlier_weights_sorted)
    r.lo = inlier_prices[0]
    r.hi = inlier_prices[-1]

    # Freshest inlier age + its maxAge
    freshest_age = None
    freshest_max_age = None
    for i in inlier_idx:
        age = now - observations[i].updated_at
        if freshest_age is None or age < freshest_age:
            freshest_age = age
            freshest_max_age = max_ages[i]
    r.freshest_age = freshest_age or 0

    # Step 5: ok + score
    r.ok = r.n_inliers >= quorum_min
    if r.ok:
        r.score = _score(
            r, inlier_weight, total_weight, freshest_max_age, d_max_bps
        )
    return r


def _is_fresh(obs: Observation, now: int, max_age: int) -> bool:
    """Mirrors OracleGuardAggregator._isFresh."""
    return (
        obs.ok
        and obs.price > 0
        and obs.price <= MAX_PRICE
        and obs.updated_at <= now
        and (now - obs.updated_at) <= max_age
    )


def _score(
    r: Reading,
    inlier_weight: int,
    total_weight: int,
    freshest_max_age: int,
    d_max_bps: int = DEFAULT_D_MAX_BPS,
) -> int:
    """
    score = floor(100 * Wq * Wd * Wf)  — all factors in BPS (0–10000).
    Mirrors OracleGuardAggregator._score exactly.
    """
    # Wq: weight-based quorum share (K2.1 change)
    wq = inlier_weight * BPS // total_weight

    # Wd: dispersion factor
    d_bps = (r.hi - r.lo) * BPS // r.mid if r.mid > 0 else BPS
    wd = 0 if d_bps >= d_max_bps else BPS - d_bps * BPS // d_max_bps

    # Wf: freshness factor (ADR-009: freshest inlier age vs maxAge/2)
    half = freshest_max_age // 2
    age = r.freshest_age
    if age <= half:
        wf = BPS
    else:
        decay = (age - half) * BPS // (half if half > 0 else 1)
        wf = BPS - min(BPS, decay)

    # score = floor(100 * wq * wd * wf / BPS^3)
    return 100 * wq * wd * wf // (BPS * BPS * BPS)


# ---------------------------------------------------------------------------
# State machine  (mirrors RiskController.sol)
# ---------------------------------------------------------------------------
@dataclass
class IlkConfig:
    green_score: int = DEFAULT_GREEN_SCORE
    yellow_score: int = DEFAULT_YELLOW_SCORE
    eps_bps: int = DEFAULT_EPS_BPS
    eps_liq_bps: int = DEFAULT_EPS_LIQ_BPS
    k_up: int = DEFAULT_K_UP
    upgrade_interval: int = DEFAULT_UPGRADE_INTERVAL
    guard_max_duration: int = DEFAULT_GUARD_MAX_DURATION
    refill_interval: int = DEFAULT_REFILL_INTERVAL
    line_cap: int = 1_000_000        # USD
    green_gap: int = 250_000         # USD per refill interval
    yellow_gap: int = 50_000         # USD
    hole_cap: int = 400_000          # USD


@dataclass
class IlkState:
    state: int = GREEN
    score: int = 0
    healthy_streak: int = 0
    last_healthy_count: int = 0
    last_refill: int = 0
    guard: bool = False
    guard_latched: bool = False
    guard_since: int = 0
    line: int = 0
    debt: int = 0


class StateMachine:
    """
    Simulates one sync() call on the RiskController.
    osm_live=True means OSM_LIVE (status==1).  osm_cur is the OSM current price in WAD.
    market_open defaults to True (no SessionCalendar in the Python model).
    """

    def __init__(self, cfg: Optional[IlkConfig] = None):
        self.cfg = cfg or IlkConfig()
        self.state = IlkState()

    def sync(
        self,
        reading: Reading,
        osm_cur: int,  # WAD
        now: int,
        osm_live: bool = True,
        market_open: bool = True,
    ) -> dict:
        """Run one sync step. Returns a dict of key outputs for logging."""
        cfg = self.cfg
        s = self.state
        prev_state = s.state

        # Determine target state
        target = self._target(reading, osm_cur, osm_live, market_open)

        # Apply hysteresis
        s.state = self._next_state(s, target, now)
        s.score = reading.score

        # Apply line (simplified: track line/debt in USD not RAD)
        self._apply_line(s, prev_state, now)

        # Apply guard
        self._apply_guard(s, reading, osm_cur, now)

        return {
            "state": s.state,
            "state_name": STATE_NAMES[s.state],
            "score": reading.score,
            "mid_usd": reading.mid / 1e18 if reading.mid else 0,
            "osm_cur_usd": osm_cur / 1e18 if osm_cur else 0,
            "guard": s.guard,
            "line": s.line,
            "debt": s.debt,
            "ok": reading.ok,
        }

    def _target(
        self,
        r: Reading,
        osm_cur: int,
        osm_live: bool,
        market_open: bool,
    ) -> int:
        cfg = self.cfg
        if not r.ok or r.score < cfg.yellow_score:
            return RED
        if not osm_live:
            return RED
        # market below delayed price: over-borrow risk
        if r.lo * 10_000 < osm_cur * (10_000 - cfg.eps_bps):
            return RED
        if r.score < cfg.green_score or not market_open:
            return YELLOW
        return GREEN

    def _next_state(self, s: IlkState, target: int, now: int) -> int:
        cfg = self.cfg
        if target >= s.state:
            # Same or worse: immediate downgrade, reset streak
            s.healthy_streak = 0
            return target
        # Better: check hysteresis
        if now >= s.last_healthy_count + cfg.upgrade_interval:
            s.healthy_streak += 1
            s.last_healthy_count = now
        if s.healthy_streak >= cfg.k_up:
            s.healthy_streak = 0
            return s.state - 1
        return s.state

    def _apply_line(self, s: IlkState, prev_state: int, now: int):
        cfg = self.cfg
        if s.state == RED:
            s.line = s.debt
        elif s.state == YELLOW:
            cap = min(s.debt + cfg.yellow_gap, cfg.line_cap)
            if prev_state != YELLOW:
                s.line = cap
            else:
                s.line = min(s.line, cap)
        else:  # GREEN
            if prev_state != GREEN or now >= s.last_refill + cfg.refill_interval:
                s.line = min(s.debt + cfg.green_gap, cfg.line_cap)
                s.last_refill = now

    def _apply_guard(self, s: IlkState, r: Reading, osm_cur: int, now: int):
        cfg = self.cfg
        # Guard condition: score>=greenScore AND live.hi*(1-epsLiq%) > osm
        cond = (
            r.ok
            and r.score >= cfg.green_score
            and r.hi * (10_000 - cfg.eps_liq_bps) > osm_cur * 10_000
        )
        if not cond:
            s.guard_latched = False
        if s.guard:
            expired = now > s.guard_since + cfg.guard_max_duration
            if not cond or expired:
                s.guard = False
                if expired and cond:
                    s.guard_latched = True
        elif cond and not s.guard_latched:
            s.guard = True
            s.guard_since = now


# ---------------------------------------------------------------------------
# Parity-vector self-test (review.md §R1.4)
# ---------------------------------------------------------------------------
_P = int(4_372.478 * 1e18)   # $4,372.478 in WAD
_NOW = 1_700_000_000          # arbitrary timestamp; all sources fresh
_WEIGHTS = [2, 2, 2, 1]
_MAX_AGES = [90_000, 3_600, 3_600, 3_600]   # Chainlink 25h, rest 1h


def _make_obs(price: int, ok: bool = True, stale: bool = False) -> Observation:
    updated = _NOW - 99_999 if stale else _NOW  # stale = older than any maxAge
    return Observation(price=price, updated_at=updated, ok=ok)


PARITY_VECTORS = {
    "V-a all agree": {
        "obs": [_make_obs(_P)] * 4,
        "expected_score": 100,
        "expected_mid": _P,
    },
    "V-b DEX×10": {
        "obs": [_make_obs(_P), _make_obs(_P), _make_obs(_P), _make_obs(_P * 10)],
        "expected_score": 85,
        "expected_mid": _P,
    },
    "V-c Chainlink stale": {
        "obs": [_make_obs(_P, stale=True), _make_obs(_P), _make_obs(_P), _make_obs(_P)],
        "expected_score": 71,
        "expected_mid": _P,
    },
    "V-d 0.5% split": {
        # Chainlink=P, Pyth=P, RedStone=1.005P, DEX=1.005P  →  mid=P, d=0.5%, Wd=0.75
        "obs": [
            _make_obs(_P),
            _make_obs(_P),
            _make_obs(int(_P * 1.005)),
            _make_obs(int(_P * 1.005)),
        ],
        "expected_score": 75,
        "expected_mid": _P,
    },
    "V-e 2 majors ×1.2": {
        # Chainlink=P, Pyth=1.2P, RedStone=1.2P, DEX=P  → 2 majors wrong majority
        # mid = 1.2P (majority wins), d ≥ 2% → score = 0, ok=False(quorum check)
        "obs": [
            _make_obs(_P),
            _make_obs(int(_P * 1.2)),
            _make_obs(int(_P * 1.2)),
            _make_obs(_P),
        ],
        "expected_score": 0,
        "expected_mid": None,   # mid is 1.2P but score=0 overrides
    },
}


def run_parity_tests(verbose: bool = True) -> bool:
    """Run all §R1.4 parity vectors. Returns True iff all pass."""
    all_pass = True
    if verbose:
        print("=" * 60)
        print("Parity vector self-test (review.md §R1.4)")
        print("=" * 60)

    for name, v in PARITY_VECTORS.items():
        r = aggregate(v["obs"], _WEIGHTS, _MAX_AGES, now=_NOW)
        got_score = r.score
        exp_score = v["expected_score"]
        passed = got_score == exp_score
        if not passed:
            all_pass = False
        if verbose:
            status = "PASS" if passed else "FAIL"
            mid_str = f"${r.mid/1e18:.3f}" if r.mid else "n/a"
            print(f"  {status}  {name:30s}  score={got_score:3d} (expect {exp_score})  mid={mid_str}")

    if verbose:
        result = "ALL PASS" if all_pass else "SOME FAILED"
        print(f"\n  Result: {result}")
        print("=" * 60)
    return all_pass


# ---------------------------------------------------------------------------
# Convenience: run parity tests when executed directly
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    ok = run_parity_tests(verbose=True)
    raise SystemExit(0 if ok else 1)
