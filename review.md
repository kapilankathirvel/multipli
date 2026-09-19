# Mentor Review #1: response & action plan

## The review (verbatim)
> "Define how the 0–100 confidence score is calculated and how much each oracle contributes. Test it against real historical oracle failures, including correlated failures where multiple sources are simultaneously wrong, and report false positives/negatives. Clearly specify what GREEN/YELLOW/RED actually changes in the protocol and quantify the resulting risk reduction."

It contains **four asks**. Each gets a precise answer, a deliverable, an owner, and a defence for Q&A.

| # | Ask | Deliverable | Owner | Status |
|---|---|---|---|---|
| R1 | Define the score + each oracle's contribution | §R1 below + weight-based `Wq` in the contract (K2.1) + contribution column in the UI | Kapilan (contract), Jeffrey (UI) | 🟨 contract ✅ (parity vectors pass), UI pending |
| R2 | Test against real historical failures incl. correlated ones; report FP/FN | Python validation study (Varun V4) + Solidity incident replay on the real contracts (Kapilan K6b) → `research/RESULTS.md` | Varun, Kapilan | 🟨 on-chain replay ✅ (§R2.4b: mint FN 21 → 2, liq FN 5 → 1), Python study pending |
| R3 | Specify exactly what GREEN/YELLOW/RED changes | §R3 below (parameter-level table) + UI panel | Kapilan (spec+contract), Jeffrey (UI) | 🟨 spec ✅ + contract ✅ (`RiskController`, 15 tests), UI pending |
| R4 | Quantify the risk reduction | §R4: deterministic bounds now, measured numbers from R2 | Varun (numbers), Jeffrey (slide) | 🟨 bounds done, measurement pending |

---

## R1. How the confidence score is calculated, and how much each oracle contributes

### R1.1 Inputs
Each source *i* reports `(price_i, updatedAt_i, ok_i)` and has a governance-set **weight wᵢ** and **maxAgeᵢ**.

| Source | Type | Weight | Share of total | maxAge | Why this weight |
|---|---|---|---|---|---|
| Chainlink PAXG/USD | push, DON of independent nodes | 2 | 28.6% | 25h (deviation feed, quiet ≠ broken) | high manipulation cost, but slow (≈24h heartbeat) |
| Pyth PAXG or XAU/USD | pull, first-party publishers + confidence interval | 2 | 28.6% | 1h | fast, independent publisher set |
| RedStone PAXG/USD | hybrid, signed packages | 2 | 28.6% | 1h | independent network and delivery path |
| Uniswap v3 TWAP | on-chain market | 1 | 14.3% | 1h | cheapest to manipulate (thin RWA liquidity) → lowest weight |

### R1.2 Formula (implemented in `OracleGuardAggregator.sol`)
```
1. fresh_i   = ok_i ∧ 0 < price_i ≤ 1e36 ∧ (now − updatedAt_i) ≤ maxAge_i
2. m0        = weighted median of fresh prices
3. MAD       = median |price_i − m0|
   inlier_i  = |price_i − m0| ≤ 3 · max(MAD, 0.1% · m0)
4. mid       = weighted median of inliers        ← the price OracleGuard uses
   lo, hi    = min, max inlier;  d = (hi − lo) / mid
5. Wq = min(1, Σ w_inliers / Σ w_all)            ← CHANGE (K2.1): weight-based, was a count
   Wd = max(0, 1 − d / 2%)
   Wf = 1 if freshest inlier age ≤ maxAge/2, else linear → 0
   score = ⌊100 · Wq · Wd · Wf⌋
6. ok = (#inliers ≥ 2); if ¬ok → score = 0
```
**Why the K2.1 change:** with a count-based `Wq`, every oracle carried 25% of confidence regardless of quality. That's inconsistent with the price weights and was exactly the mentor's point. Now **each oracle contributes to confidence in proportion to its weight**, the same as it does to the price.

### R1.3 Each oracle's contribution: two precise meanings
1. **To confidence (Wq):** losing oracle *i* (stale, down, or rejected as an outlier) removes `wᵢ/Σw` from Wq:

| Oracle lost | Wq | Score (others agree, fresh) | State |
|---|---|---|---|
| none | 7/7 | **100** | GREEN |
| DEX TWAP | 6/7 | **85** | GREEN (a thin-pool glitch shouldn't restrict users) |
| Chainlink *or* Pyth *or* RedStone | 5/7 | **71** | YELLOW |
| one major + DEX | 4/7 | **57** | YELLOW |
| two majors | 3/7 | **42** | RED |
| all but one | n/a | **0** (quorum < 2) | RED |

2. **To the price (weighted median):** an oracle moves the price only if it is **pivotal**. The breakdown point is ½ of the weight (3.5 of 7):
   - **No single oracle can move the price.** DEX alone (1/7) and any one major (2/7) are both below ½.
   - DEX + one major (3/7) still cannot.
   - Moving it requires **2 of the 3 major networks wrong in the same direction** (≥ 4/7). That is exactly the correlated-failure case tested in R2.

### R1.4 Worked parity vectors (the Python model in R2 must reproduce these exactly)
| Vector | Chainlink | Pyth | RedStone | DEX | Expected mid | Expected score |
|---|---|---|---|---|---|---|
| V-a all agree | P | P | P | P | P | 100 |
| V-b DEX ×10 | P | P | P | 10P | P | 85 |
| V-c Chainlink stale | stale | P | P | P | P | 71 |
| V-d 0.5% split | P | P | 1.005P | 1.005P | P | 75 (Wd = 0.75) |
| V-e 2 majors ×1.2 | P | 1.2P | 1.2P | P | 1.2P (the wrong majority wins the median) | 0 (d = 16.7% ≥ 2%, so RED) |
(P = $4,372.478, all fresh unless stated; weights 2/2/2/1.)

---

## R2. Validation against real historical oracle failures (incl. correlated), with FP/FN

### R2.1 Two complementary tests
1. **Python validation study (Varun, `research/`)** mirrors the Solidity formula exactly (parity vectors R1.4) and runs at scale: real price history + historical incident traces + Monte-Carlo fault injection. It produces the FP/FN tables.
2. **Solidity incident replay (Kapilan, `contracts/test/replay/Incidents.t.sol`)** replays compressed versions of the same incidents through **the actual deployed-on-fork contracts** (Aggregator + SmartOSM + RiskController + real Vat/Dog). It proves the contracts behave like the model and prints each incident's decisions.

### R2.2 Data (real, and labelled as such)
| Dataset | Source | Real / reconstructed |
|---|---|---|
| Chainlink PAXG/USD full round history | `getRoundData` over the proxy's aggregators via archive RPC | **real on-chain** |
| Gold spot XAU/USD hourly + PAXG/USD hourly | yfinance (GC=F, PAXG-USD) / Pyth Benchmarks API | real market data |
| Chainlink USDC/USD (SVB depeg, Mar 2023) | `getRoundData` on mainnet | **real on-chain** |
| Compound DAI (Coinbase-signed price 1.30, Nov 2020) | Compound Open Oracle posted prices / post-mortem | real on-chain values + post-mortem |
| Chainlink LUNA/USD minAnswer clamp (May 2022) | aggregator rounds + Venus/Blizz post-mortems | real on-chain + post-mortem |
| Mango Markets MNGO (Oct 2022) | post-mortem price path (FTX/Pyth/Switchboard) | reconstructed from post-mortems |
| Synthetix sKRW (Jun 2019), Pyth BTC publisher error (Sep 2021) | post-mortems | reconstructed |
| Black Thursday ETH (Mar 2020) | market data + Maker post-mortem | real market + reconstructed oracle lag |

### R2.3 Incident catalogue: failure classes, including correlated
| # | Incident | Class | Sources wrong at once | What a *correct* system does |
|---|---|---|---|---|
| I1 | Synthetix sKRW 1000× (2019) | single-source spike | 1 | ignore the outlier, stay GREEN or YELLOW |
| I2 | Compound DAI $1.30 via Coinbase (2020) | single-source spike, $89M liquidated | 1 | ignore; **no liquidations** |
| I3 | Pyth BTC publisher error (2021) | single-source crash | 1 | ignore |
| I4 | LUNA minAnswer clamp (2022) | single-source clamp during a real crash | 1 (+ real crash) | reject the clamped source; **follow the real crash** |
| I5 | Stale-feed outage (PAXG heartbeat gap, synthetic on real history) | staleness | 1…all | YELLOW (1 stale) → RED (all stale) |
| I6 | **Mango Markets (2022)** | **correlated manipulation:** all oracles tracked a manipulated spot market | **all** | cannot be detected by consensus → loss must be **bounded** (see R2.5) |
| I7 | **USDC/SVB depeg (2023)** | **correlated but TRUE** market move | all move together, correctly | **must NOT block liquidations** (FP test) |
| I8 | **Black Thursday (2020)** | correlated congestion: push oracles lag while the market crashes 43% | several stale + real crash | RED on mint, **liquidations continue** |
| I9 | PAXG-specific dislocation vs gold (synthetic from real PAXG-XAU basis) | correlated: all PAXG feeds agree, token deviates from underlying | all PAXG feeds | caught only with a fundamental anchor (XAU×ratio): production item |

### R2.4 Ground truth, FP and FN (definitions fixed up-front, so results can't be gamed)
- **Truth price** at each step = reference market (gold spot × PAXG ratio; for incidents, the post-mortem "real" price).
- **Oracle is wrong** if |OracleGuard mid − truth| > **2%** (gold) / 5% (volatile assets).
- **Mint side:** the system *restricts* if state ∈ {YELLOW, RED}.
  - **FN (dangerous):** oracle wrong AND state = GREEN (full borrowing against a wrong price).
  - **FP (annoying):** oracle right AND state = RED (borrowing frozen without need). YELLOW-while-right is reported separately as "cautious".
- **Liquidation side:** guard on/off.
  - **FN:** healthy-at-truth vault liquidatable because of a wrong price AND guard off.
  - **FP (dangerous):** guard on while vaults are truly unsafe (it delays needed liquidations; bounded by the 6h expiry).
- Reported per incident **and** as rates over the Monte-Carlo run, plus a **threshold sweep** (GREEN cut 70/80/90, ε 1/1.5/3%) so we show why the chosen thresholds sit where they do.

### R2.4b ✅ RESULTS: on-chain incident replay on the real rwaUSD contracts (K6b, `contracts/test/replay/Incidents.t.sol`)
55 hourly steps across 8 incidents, each replayed through OracleGuard (Aggregator → SmartOSM → RiskController → real Vat/Dog) **and** the legacy OSM side by side. Incident shapes are reconstructed from post-mortems and scaled onto PAXG. In single-source incidents the fault sits on Chainlink, the legacy protocol's only feed.

| Incident | OG mint FN | Legacy mint FN | OG liq FN | Legacy liq FN | OG liq FP | OG "RED while fine" (user cost) | Extra liquidation lag h (OG / legacy) | Max new debt at a wrong price (OG / legacy) |
|---|---|---|---|---|---|---|---|---|
| I1 sKRW 1000× (1 feed) | **0** | 2 | 0 | 0 | 0 | 0 (4 h YELLOW) | 0 / 2 | $0 / $956,970 |
| I2 Compound DAI −23% (1 feed) | **0** | 0 | **0** | 1 | 0 | 0 (3 h YELLOW) | 0 / 0 | $0 / $0 |
| I3 Pyth BTC −90% (1 feed) | **0** | 0 | **0** | 1 | 0 | 0 (3 h YELLOW) | 0 / 0 | $0 / $0 |
| I4 LUNA clamp in a real crash | **0** | 6 | 0 | 0 | 0 | 1 | **0 / 3** | $0 / $956,970 |
| I5 stale outage (1 → all) | **0** | 4 | 0 | 0 | 0 | 1 | 2 / 3 (no data exists) | $0 / $956,970 |
| I6 **Mango: all oracles manipulated** | 2 ⚠️ | 3 | 0 | 0 | 2 ⚠️ | 0 | 3 / 3 | **$250,000** / $956,970 |
| I7 USDC/SVB true −12% move | **0** | 2 | 0 | 2 | **0** | 2 | 0 / 0 | $0 / $956,970 |
| I8 Black Thursday −43%, 1 oracle lags | **0** | 4 | 1 | 1 | **0** | 3 | **0 / 3** | $0 / $956,970 |
| **Total (55 steps)** | **2** | **21** | **1** | **5** | **2** | **7** | **5 / 14** | **≤ $250k/h / $956,970** |

**Reading the table:**
- **Over-borrowing risk (mint FN):** 21 steps under legacy → **2** under OracleGuard, and both are Mango, the correlated-manipulation limit we declared up front. Even there the exposure is capped at the hourly $250k budget vs ≈$957k.
- **Unfair liquidations (liq FN):** 5 → 1. The remaining one is I8's rebound hour: one oracle still lags, so agreement is too low to arm the guard. We keep the guard deliberately conservative (it needs ≥ 80) to avoid the opposite error.
- **Guard wrongly pausing needed liquidations (liq FP):** 0 in real moves (I4, I7, I8). **2 in Mango**, because a correlated manipulation fools the guard as well (known limit; the guard auto-expires in ≤ 6h).
- **Cost to users:** 7 hourly steps of RED while the price was fine, all right after real crashes (hysteresis: relax slowly). Single-source faults only cost YELLOW hours (borrowing capped, not frozen).
- **Liquidation lag beyond the designed 1h delay:** 14 → 5. The remainder is I5 (no source has data; nobody can follow the market) and I6 (manipulated sources).

**The replay found a real weakness, which we fixed (ADR-011).** The first run showed that in I4 (LUNA) and I8 (Black Thursday), SmartOSM quarantined *every* hour of a real crash because one oracle lagged. The Vat kept the pre-crash price for 4 hours, so liquidations couldn't fire. Fix:
1. quarantine only **upward** low-agreement jumps (downward moves pass; unfairly low prices are the guard's job);
2. confirm a held-back rise if a later hop still shows it;
3. while a value is held back, the already-vetted `nxt` still advances into `cur`.

Result: I8 extra lag **4h → 0h**, I4 → 0h. Regression tests pin this.

### R2.5 Monte-Carlo fault injection (on real PAXG/XAU history)
Faults injected into k of the 4 sources, with k ∈ {1,2,3,4} to cover **correlated** cases: spike (±5…90%), drift (slow bias), freeze (stale), clamp, delay. Output: a FP/FN matrix by fault type × k, and bad debt with vs without OracleGuard.

### R2.6 What we will honestly report (and why it's still a strong answer)
- **Single-source failures (I1–I5):** expected FN ≈ 0 by construction (below the breakdown point). The study measures it.
- **Correlated *wrong* sources (I6, k ≥ 2 majors):** consensus **cannot** detect it. No median-based oracle can, and that includes Chainlink's own DON. We say so. Our answer is **bounded loss** instead of detection:
  1. the OSM delay (1h) + jump quarantine (a big low-agreement jump needs re-confirmation),
  2. **rate-limited headroom** (new, K4): even in GREEN, new debt per hour ≤ `greenGap`, so `MaxLoss ≤ greenGap × hours-undetected`,
  3. cost of corruption: moving 2 of 3 independent networks for a globally traded asset (gold) costs far more than moving one thin pool (Mango's MNGO was illiquid; PAXG tracks a ~$15T gold market),
  4. roadmap: a fundamental anchor (XAU × troy-oz ratio) as an *uncorrelated* source (catches I9).
- **Correlated *true* moves (I7, I8):** the key FP test. The design is asymmetric: RED freezes minting but **never blocks liquidations**, and the guard needs the live price *above* the OSM. So a real crash still liquidates on time.

---

## R3. Exactly what GREEN / YELLOW / RED change in the protocol

Only two protocol parameters are ever touched, each through a bounded executor: **`Vat.ilks[paxg].line`** (debt ceiling) and **`Dog.ilks[paxg].hole`** (liquidation limit). `Spotter.mat`, the price path, fees, and repayments are **never** touched.

| | 🟢 GREEN | 🟡 YELLOW | 🔴 RED | 🛡️ Guard (independent flag) |
|---|---|---|---|---|
| **Trigger** | score ≥ 80 ∧ live.lo ≥ OSM·(1−1.5%) ∧ market open | 50 ≤ score < 80 ∨ market closed ∨ OSM age > ½ staleLimit | score < 50 ∨ OSM STALE/QUARANTINED ∨ live.lo < OSM·(1−1.5%) | score ≥ 80 ∧ live.hi·(1−3%) > OSM price |
| **`Vat.line`** | `min(debt + greenGap, lineCap)`, refilled at most once per hour (**rate limit**, new in K4) | `min(debt + yellowGap, lineCap)` | `= debt` | unchanged |
| **`Dog.hole`** | 400,000 (governance value) | 400,000 | 400,000 | **0** (no *new* liquidations), auto-restored after ≤ 6h |
| Open vault / deposit collateral | ✅ | ✅ | ✅ | ✅ |
| **Borrow new rwaUSD** | ✅ up to greenGap/h | ⚠️ up to yellowGap total | ❌ `Vat/ceiling-exceeded` | n/a |
| Withdraw collateral (stays safe) | ✅ | ✅ | ✅ | ✅ |
| **Repay** | ✅ | ✅ | ✅ | ✅ |
| **Liquidation of unsafe vaults** | ✅ | ✅ | ✅ (a real crash must liquidate) | ⏸️ paused, max 6h |
| Running auctions | ✅ | ✅ | ✅ | ✅ (only *new* ones paused) |

Proposed PAXG parameters: `lineCap` 1,000,000 · `greenGap` 250,000/h · `yellowGap` 50,000 · ε 1.5% · ε_guard 3% · guard max 6h · upgrade needs 3 healthy syncs ≥ 10 min apart. Downgrades are instant.

---

## R4. Quantified risk reduction

### R4.1 Deterministic bounds (hold regardless of the backtest)
**Max new rwaUSD that can be minted against a wrong price, per hour:**
| | Legacy rwaUSD (measured on the fork) | OracleGuard |
|---|---|---|
| Wrong price in GREEN (undetected, e.g. I6) | **≈ $956,971** (whole remaining ceiling: 1,000,000 − 43,029 debt) | **≤ $250,000/h** (greenGap) |
| Degraded (YELLOW) | same ≈ $956,971 | **≤ $50,000 total** |
| Detected (RED) | same ≈ $956,971; the legacy system has no RED state | **$0** |
| Stale feed | exposure unbounded **in time** (S1: 186h-old price still valid) | stale → RED within one sync |

### R4.2 Measured on the real contracts (fork tests)
| Scenario | Legacy | OracleGuard (K6) |
|---|---|---|
| S3 feed compromise, 10 PAXG | **$268,595 bad debt** ($312,319 minted vs $43,724 collateral) | ✅ **$0 bad debt**: legacy feed swap has no effect; a compromised Chainlink is an outlier → max draw $31,231 < $43,724 collateral |
| S4 captured wick | healthy 145% vault liquidated: 10 PAXG seized, 5% penalty ≈ $2.2k + auction discount | ✅ **0 unjust liquidations**: guard → `Dog/liquidation-limit-hit`, released after one hop, vault safe |
| S1 stale 7 days | 31,231 rwaUSD minted on a 186h-old price | ✅ one source stale → YELLOW, new debt capped at $50k; all stale → RED, mint reverts, **repay works**, price never 0 |
| S2 market −8% while the OSM lags | mint at the stale-high price | ✅ RED immediately; liquidations stay ON |

### R4.3 From the validation study (R2)
**On-chain replay (Kapilan, K6b), final:** see §R2.4b. Over-borrowing hours 21 → 2, unfair-liquidation hours 5 → 1, worst-case new debt at a wrong price $956,970 → ≤ $250,000/h.
**Python study (Varun, `research/RESULTS.md`), first run:** parity vectors pass. Monte-Carlo (500 runs/cell): single-source faults (k = 1) have 0% FN for every fault type; majority faults (k ≥ 3 spikes/clamps) are the declared correlated-failure limit. ⚠️ Pending fixes before quoting numbers (see `varun.md` review feedback): real data instead of synthetic GBM, the threshold-sweep wiring, and the 4h-exposure row.
*(Original placeholder, kept for reference:)*
Expected bad debt per $1M of vault debt per year (legacy vs OracleGuard), FN/FP rates per incident class, unjust-liquidation count, and time spent in YELLOW/RED on normal days (the cost to users). → `research/RESULTS.md`

---

## Defence cheat-sheet (for the mentor / judges)
- **"How is the score computed?"** Three multiplicative factors: agreement-weighted coverage × tightness × freshness. Each oracle's contribution equals its weight share (28.6 / 28.6 / 28.6 / 14.3%). No single oracle can move the price; it takes 2 of the 3 major networks.
- **"What if several oracles are wrong together?"** Consensus can't detect that, for any median oracle including Chainlink itself. We make it *bounded* (≤ greenGap per hour, OSM delay, quarantine) and *expensive* (≥ 2 independent networks on a global market). The study quantifies residual FN honestly (Mango-class).
- **"Won't you block liquidations in a real crash?"** No. RED never blocks liquidations. The guard only fires when the live price is *above* the delayed price, i.e. vaults are safer than the OSM thinks, and it expires in 6h. Tested on the USDC-depeg and Black-Thursday replays (I7, I8).
- **"What's the cost to users?"** Measured as % of normal hours in YELLOW/RED (FP rate) in the study.

## Impact on the team split (already applied to the .md files)
- **Kapilan:** + K2.1 (weight-based Wq, 0.5h) · K4 gains rate-limited GREEN headroom (+0.5h) · new K6b incident replay on the fork (1.5h).
- **Varun:** V4 is now the **validation study** (the core of this review, ≈4.5h) and moves to **first priority**. V2 PythSource drops to optional.
- **Jeffrey:** + contribution column + "what this state changes" panel in the dashboard (J2), + 3 slides (score definition, validation FP/FN, risk reduction) in J5.
- **Still no cross-dependencies:** Varun's Python mirrors the formula in R1.2 and checks itself against the parity vectors in R1.4 (no contract needed). Kapilan's replay uses its own inline traces. Jeffrey uses placeholders until `research/RESULTS.md` lands.
