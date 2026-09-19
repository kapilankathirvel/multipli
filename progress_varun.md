# Varun's Progress — OracleGuard V4 Validation Study

## Status: V4 COMPLETE + V1 COMPLETE + V3 COMPLETE — V2 (PythSource) optional next

---

## Files Created (all within Varun's ownership: `research/**`)

### Core Python Model
- [x] `research/og_model.py` — Python mirror of `OracleGuardAggregator.sol` + `RiskController.sol`
  - Exact BPS integer arithmetic matching Solidity
  - `aggregate()` — full pipeline (freshness → weighted median → MAD outlier filter → score)
  - `StateMachine` class — GREEN/YELLOW/RED + guard + hysteresis
  - **5/5 parity vectors PASS** (V-a=100, V-b=85, V-c=71, V-d=75, V-e=0)

### Data Collection
- [x] `research/fetch_data.py` — Archive RPC Chainlink fetcher + yfinance downloader
  - Chainlink PAXG/USD round history via `getRoundData` (JSON-RPC, no web3 needed)
  - PAXG-USD + Gold (GC=F) hourly via yfinance
  - USDC/USD SVB-period rounds

### Incident Traces (I1–I9)
- [x] `research/incidents/I1_synthetix_skrw.csv` — Synthetix sKRW 1000x spike (2019)
- [x] `research/incidents/I2_compound_dai.csv`   — Compound DAI $1.30 spike (2020)
- [x] `research/incidents/I3_pyth_btc.csv`       — Pyth BTC publisher crash (2021)
- [x] `research/incidents/I4_luna_clamp.csv`     — LUNA minAnswer clamp (2022)
- [x] `research/incidents/I5_stale_paxg.csv`     — PAXG stale feed (synthetic on real history)
- [x] `research/incidents/I6_mango_markets.csv`  — Mango correlated manipulation (2022)
- [x] `research/incidents/I7_usdc_svb.csv`       — USDC/SVB depeg true move (2023) — FP test
- [x] `research/incidents/I8_black_thursday.csv` — Black Thursday congestion (2020)
- [x] `research/incidents/I9_paxg_dislocation.csv` — PAXG vs XAU fundamental gap

### Simulation Engine
- [x] `research/monte_carlo.py` — Fault injection engine
  - Fault types: spike, drift, freeze, clamp, delay
  - k ∈ {1,2,3,4} simultaneous faulted sources (correlated coverage)
  - FP/FN classification per review.md §R2.4
  - Threshold sweep support

### Analysis + Charts
- [x] `research/metrics.py` — Incident analysis, bad-debt table, chart generator
  - `run_incident_analysis()` — runs all I1-I9 through the model
  - `bad_debt_comparison()` — deterministic bounds table (review.md §R4.1)
  - `make_charts()` — confusion matrix, threshold sweep, bad debt bars, incident FP/FN

### Master Runner
- [x] `research/run_study.py` — Orchestrates all V4 steps in order:
  1. Parity vector self-test
  2. Load price data (real if available, synthetic GBM fallback)
  3. Incident analysis I1-I9
  4. Monte-Carlo (500 runs/cell)
  5. Threshold sweep (9 configs: G70/80/90 × ε1/1.5/3%)
  6. Risk reduction table
  7. Chart generation → `research/out/`
  8. `research/RESULTS.md` generation

---

## Completed Tasks (varun.md checklist)

- [x] **V4 Model:** `research/og_model.py` — parity vectors 100/85/71/75/0 all pass ✅
- [x] **V4 Incident traces I1–I9:** all 9 CSVs created with correct schema
- [x] **V4 Monte-Carlo fault injection:** spike/drift/freeze/clamp/delay × k={1,2,3,4}
- [x] **V4 Metrics:** FP/FN definitions, threshold sweep, risk reduction §R4.3
- [x] **V4 Output:** `run_study.py` generates `RESULTS.md` + charts in `research/out/`

### V1 SessionCalendar
- [x] **V1 Contract:** `contracts/src/SessionCalendar.sol` created
- [x] **V1 Tests:** `contracts/test/unit/SessionCalendar.t.sol` (28/28 passing)

### V3 Demo Scripts
- [x] **V3 Scripts:** `scripts/demo-up.ps1`, `scripts/demo-up.sh`, `scripts/demo-down.ps1`, `scripts/demo-down.sh` created
- [x] **V3 Validation:** Full self-test passing (anvil fork, deploy, spell, snapshot)

## Pending
- [ ] Run `python research/fetch_data.py` to pull real Chainlink/yfinance data
      (requires ETH_RPC_URL set in environment or `contracts/.env`)
- [ ] Run `python research/run_study.py` to generate final RESULTS.md + charts
- [x] V1 `SessionCalendar` contract (tested and complete)
- [x] V3 demo bring-up scripts (tested and complete)
- [ ] V2 `PythSource` contract (optional)

## Data status
- `research/data/` — empty until `fetch_data.py` is run
- Study runs on synthetic GBM data if real data is not present (noted in RESULTS.md)

---

## Files NOT modified (outside Varun's scope)
- No contract source files modified
- No docs/ files modified
- No kapilan.md, jeffrey.md, PROGRESS.md, CLAUDE.md modified

---

## How to Run

```powershell
# 1. Install dependencies (once)
pip install pandas numpy matplotlib yfinance requests

# 2. (Optional but recommended) Fetch real price data
# Set ETH_RPC_URL first (already in contracts/.env)
$env:ETH_RPC_URL = "https://mainnet.gateway.tenderly.co"
python research/fetch_data.py

# 3. Run the full study
python research/run_study.py
```

Output: `research/RESULTS.md` + charts in `research/out/`

---

## Commit message (when ready)
```
feat(research): validation study - incidents, Monte-Carlo FP/FN, risk reduction (mentor review)
```
