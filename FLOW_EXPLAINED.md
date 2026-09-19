# OracleGuard: the complete flow, end to end

> One document, one running example. We follow **a single gold price** from the moment four oracles report it, through aggregation, the confidence score, the delayed price, the risk decision, and all the way to what a borrower or a liquidator can do on the real rwaUSD contracts.
> Background (what rwaUSD / a vault / Maker words mean): `SOLUTION_EXPLAINED.md` Part 1. Code details: `IMPLEMENTATION_EXPLAINED.md`.

---

## 0. The big picture on one page

```
 ┌──────────────── LAYER 1: SOURCES ────────────────┐
 │ Chainlink PAXG/USD (real)   Pyth (sim)            │   each one answers: "price, when, ok?"
 │ RedStone (sim)              DEX TWAP (sim)        │
 └───────────────┬───────────────────────────────────┘
                 │ observe()  ×4
                 ▼
 ┌──────────── LAYER 2a: AGGREGATOR ─────────────────┐
 │ drop stale/broken → weighted median → drop         │   answers: "the price is X,
 │ outliers → band lo..hi → score 0-100               │   and I'm S% confident"
 └───────┬───────────────────────────────┬───────────┘
         │ read()  (once per hour)       │ read()  (every sync)
         ▼                               ▼
 ┌──── LAYER 2b: SMART OSM ────┐   ┌──── LAYER 2c: RISK CONTROLLER ──────────┐
 │ 1-hour delayed price         │──►│ compares LIVE price vs DELAYED price,   │
 │ cur (in use) / nxt (next)    │   │ score, staleness → GREEN/YELLOW/RED     │
 │ never 0, holds back          │   │ + liquidation guard                     │
 │ suspicious rises             │   └───────┬──────────────────────┬─────────┘
 └──────────┬──────────────────┘           │ setLine              │ setHole
            │ peek() (via Spotter.poke)    ▼                      ▼
            ▼                         LineExecutor           HoleExecutor
 ┌──────────── LAYER 3: MULTIPLI CORE (unchanged) ─────────────────────────────┐
 │ Spotter → Vat.spot (price ÷ 1.4)    Vat.line (debt ceiling)   Dog.hole (liq. limit)│
 │ Vat: borrow / repay / deposit       Dog + Clipper: liquidations                 │
 └─────────────────────────────────────────────────────────────────────────────────┘
                 ▲                                   ▲
            borrowers                          liquidators (keepers)
```
**Three questions drive everything:**
1. *What is the price?* (Aggregator)
2. *What price should the protocol act on right now?* (SmartOSM: the safe, 1-hour-delayed one)
3. *How much should we trust it, and what may users do?* (RiskController)

---

## 1. Before OracleGuard: the legacy flow (for contrast)
```
Chainlink ──► PriceFeedAdapter ──► OSM (1h delay) ──► Spotter ──► Vat.spot
               (0,false) if >24h     ignores "false"!
```
One feed, no confidence, no reaction logic. If the feed dies, the OSM keeps using the last price as **valid forever**. The only emergency button sets the price to 0, which liquidates everyone. OracleGuard replaces the middle of this chain and adds a reaction layer next to it.

---

## 2. Setup: what happens once (deploy + spell)

**Step A: Deploy** (`script/Deploy.s.sol` → `DeployLib.deploy`), any account:
1. Create the 4 sources:
   - `ChainlinkSource` wraps the real feed `0x9944…F8C3`;
   - 3 `MockSource`s (Pyth, RedStone, DEX) are primed to Chainlink's price, **$4,372.478**.
2. Create the `OracleGuardAggregator` and register the sources with **weights 2/2/2/1** and max ages **25h / 1h / 1h / 1h**.
3. Create `SmartOSM`, then `init($4,372.478)`. That's the legacy OSM's current price, read from its storage slot 3, so there's **no price jump** at the switch. Whitelist the Spotter, Clipper and End as readers.
4. Create `LineExecutor` (cap = today's ceiling, $1,000,000) and `HoleExecutor` (cap = today's liquidation limit, $400,000).
5. Create the `RiskController` and give it the PAXG config: GREEN ≥ 80, RED < 50, greenGap $250k/h, yellowGap $50k, ε 1.5%, guard ε 3%, guard max 6h, and so on.
6. Give the Admin Safe admin rights on everything; write `deployments/fork.json` (addresses for the dashboard).
7. *(Optional, K7)* `CALENDAR=` / `PYTH_SOURCE=` plug in Varun's market-hours calendar and real Pyth adapter.

**Step B: Spell** (`script/Spell.s.sol` → `DeployLib.spell`), executed **as the Admin Safe**, the only account allowed to change Multipli's core:
1. `Spotter.file("paxg","pip", SmartOSM)`: the Spotter now reads prices from SmartOSM instead of the legacy OSM.
2. `Vat.rely(LineExecutor)`: the executor may now change the PAXG debt ceiling (only within its cap).
3. `Dog.rely(HoleExecutor)`: the executor may now change the PAXG liquidation limit (only within its cap).
4. `Spotter.poke("paxg")` and `RiskController.sync("paxg")`: first price push and first health check.

**Result:** 🟢 GREEN, score 100, `Vat.line` = debt $43,029 + $250,000 = **$293,029**. Nothing else in Multipli changed. Rollback = point the pip back at the legacy OSM and revoke the two executors.

---

## 3. The recurring cycle: what happens every hour
```
 keeper (anyone) ──► SmartOSM.poke() ──► Aggregator.read() ──► 4 × Source.observe()
                          │
                          ├─► (maybe) shift cur ← nxt, nxt ← new price
                          └─► Spotter.poke() ──► Vat.spot updated
 keeper (anyone) ──► RiskController.sync() ──► Aggregator.read() + SmartOSM.status/price
                          ├─► LineExecutor.setLine() ──► Vat.line
                          └─► HoleExecutor.setHole() ──► Dog.hole
 users / liquidators ──► Vat.frob (borrow/repay) · Dog.bark (liquidate)   ← unchanged Maker code
```
Both `poke` and `sync` are **permissionless** (anyone can call them). In production a keeper bot does it (Chainlink Automation / Gelato); in the demo, our scripts or dashboard do. Now each stage in depth.

---

## 4. Stage 1: Sources: "what does each oracle say?"
Every source implements one function, `observe()`, returning an **Observation**:
```
{ price (USD per token, 18 decimals), conf, updatedAt (timestamp), ok (true/false) }
```
**Rule: a source never reverts.** Whatever goes wrong becomes `ok = false`, so one broken oracle can't crash the whole system.

### ChainlinkSource (the real one)
Chainlink answers `latestRoundData()` → `answer = 437247814339` with **8 decimals**.
- Convert to 18 decimals: 437247814339 × 10¹⁸ / 10⁸ = **4,372.47814339 × 10¹⁸** ($4,372.478).
- `ok = false` if:
  - the answer ≤ 0,
  - the timestamp is 0 or in the future,
  - the value is absurdly large (overflow guard),
  - or **it sits exactly on Chainlink's min/max circuit-breaker bound**. That's the LUNA-2022 failure mode, where the feed kept printing its floor while the real price collapsed.
- It does **not** judge staleness (the Aggregator does), so the dashboard can still show "Chainlink: $4,372, 18h old".

### MockSource (Pyth / RedStone / DEX stand-ins)
Holds a price someone sets with `setPrice(p)` (stamps "now", ok = true). In production these would be real adapters behind the **same interface**. Varun's real `PythSource` plugs in via `PYTH_SOURCE=`.

---

## 5. Stage 2: the Aggregator: "one price + how confident?"
`OracleGuardAggregator.read()` turns the 4 Observations into a **Reading**:
```
{ mid (the price), lo, hi (agreeing band), score 0-100, nFresh, nInliers, freshestAge, ok }
```

### Running example A: a normal hour
| Source | Price | Age | Weight | maxAge |
|---|---|---|---|---|
| Chainlink | $4,372.5 | 18h | 2 | 25h |
| Pyth | $4,372.0 | 1 min | 2 | 1h |
| RedStone | $4,373.0 | 1 min | 2 | 1h |
| DEX TWAP | $4,371.0 | 1 min | 1 | 1h |

**Step 1: freshness.** A source counts only if `ok` and age ≤ its maxAge. Chainlink is 18h old but its maxAge is 25h (it's a slow "update-on-move" feed), so ✅. All 4 are fresh.

**Step 2: sort by price and take the weighted median `m0`:**
```
DEX 4,371.0 (w1) → cumulative 1
Pyth 4,372.0 (w2) → cumulative 3
CL  4,372.5 (w2) → cumulative 5   ← first time cumulative ≥ half of total weight (7/2 = 3.5)
RS  4,373.0 (w2) → cumulative 7
m0 = $4,372.5
```
Why weighted *median*: the middle can't be dragged by one extreme value, and weights mean the more trustworthy sources count more.

**Step 3: throw out outliers (MAD test).**
- Deviations from m0: DEX 1.5, Pyth 0.5, CL 0, RS 0.5 → sorted [0, 0.5, 0.5, 1.5] → **MAD** (median of deviations) = 0.5.
- Floor: 0.1% of m0 = $4.37. The floor stops "everyone agrees perfectly" (MAD = 0) from flagging tiny differences.
- Threshold = 3 × max(0.5, 4.37) = **$13.12** → all 4 are within it → all **inliers**.

**Step 4: the band.** mid = weighted median of inliers = **$4,372.5**; lo = $4,371.0; hi = $4,373.0.

**Step 5: the confidence score** = 100 × Wq × Wd × Wf:
| Factor | Meaning | Calculation | Value |
|---|---|---|---|
| **Wq** coverage | share of total weight that is healthy and agreeing | 7/7 | 1.00 |
| **Wd** agreement | 1 − spread/2%, spread = (hi − lo)/mid | spread = 2/4,372.5 = 0.046% → 1 − 0.046/2 | 0.98 |
| **Wf** freshness | 1 while the *freshest* inlier is ≤ half its maxAge old, then linear to 0 | freshest is 1 min old (≤ 30 min) | 1.00 |
| **score** | | 100 × 1 × 0.98 × 1 | **98** |

`ok = true` because ≥ 2 inliers.

### Running example B: the DEX gets manipulated to 10× ($43,720)
- Sorted: Pyth 4,372.0 (cum 2) → CL 4,372.5 (cum 4 ≥ 3.5) → **m0 = $4,372.5**. The attacker's value is at the far end and can't reach the middle.
- Deviations [0, 0.5, 0.5, 39,347.5] → MAD 0.5 → threshold $13.12 → **DEX is an outlier**.
- mid **$4,372.5 (unchanged)**, Wq = 6/7 = 0.857, Wd ≈ 0.99 → **score 84 → still GREEN**. A thin-pool glitch shouldn't restrict users.

### How much each oracle "counts"
| Lost (stale / broken / outlier) | Wq | Score (others agree) |
|---|---|---|
| nothing | 7/7 | 100 |
| DEX only | 6/7 | ~85 → GREEN |
| any one of Chainlink / Pyth / RedStone | 5/7 | ~71 → YELLOW |
| one major + DEX | 4/7 | ~57 → YELLOW |
| two majors | 3/7 | ~42 → RED |
| fewer than 2 left | n/a | 0, ok = false → RED |

**Moving the price itself** takes ≥ half the weight (3.5 of 7), i.e. **two of the three major oracles lying in the same direction**. No single source can do it.

---

## 6. Stage 3: SmartOSM: "which price does the protocol act on now?"
The protocol does **not** use the live price directly. Like Maker's OSM, SmartOSM keeps two slots:
- **`cur`**: the price the Vat uses **right now**,
- **`nxt`**: the price that becomes `cur` **one hour from now**.

**Why the delay?** If someone manipulates prices, there's an hour before it affects liquidations: time for the system (and humans) to react.

### `poke()`: once per hour (`hop` = 3600s)
```
1. Has an hour passed since the last update?            no  → revert "OSM/not-passed"
2. Ask the Aggregator → Reading r
3. r.ok == false (no quorum / everything stale)?        yes → emit PokeSkipped, STOP.
      cur & nxt unchanged (the price is NEVER set to 0), age keeps growing → status STALE.
      The hour is not consumed: anyone can retry the moment sources recover.
4. Is r a big RISE (> 5% above nxt) with low confidence (score < 80),
   and nothing already held back?                       yes → QUARANTINE:
      cur ← nxt (the already-checked price still moves on), pending ← r.mid, STOP.
      A later hour that still shows the rise confirms it.
5. Otherwise ACCEPT:  cur ← nxt,  nxt ← r.mid,  lastGoodAt ← now
6. Call Spotter.poke() → the Vat's price updates in the same transaction
```
**Why only rises are held back (ADR-011):**
- A *wrongly high* collateral price lets people **borrow too much**, so rises need confirmation.
- A *drop* must pass fast, so **liquidations happen in time** during a real crash.
- A wrongly *low* price is handled by the guard (Stage 4).
- Our historical replay showed that holding back drops froze the price for 4 hours during Black Thursday, so we changed it.

### Timeline example (price moves from $4,372 to $4,460)
| Time | Live mid | After `poke()`: `cur` (Vat uses) | `nxt` |
|---|---|---|---|
| 10:00 | $4,372 | $4,372 | $4,372 |
| 11:00 | $4,460 (+2%, full agreement) | $4,372 | **$4,460** |
| 12:00 | $4,460 | **$4,460** | $4,460 |
The Vat sees a new price **one hour after** the market. That's the built-in delay.

### The Spotter → Vat step (Multipli's own code, unchanged)
```
Spotter.poke("paxg"):  (val, has) = SmartOSM.peek()          // (4,372.478, true), never (0, false)
                       spot = val / par / mat = 4,372.478 / 1 / 1.40 = 3,123.198
                       Vat.file("paxg", "spot", 3,123.198)
```
`spot` is the **borrowing power per PAXG**: 1 PAXG lets you owe at most $3,123.

### SmartOSM `status()`
| Status | Meaning |
|---|---|
| LIVE | fresh, normal |
| STALE | no accepted update for > 2h (sources dead) |
| QUARANTINED | a suspicious rise is being held back |
| STOPPED | the guardian paused it |
| UNINIT | not initialised |

---

## 7. Stage 4: RiskController: "how much do we trust it, and what's allowed?"
`sync("paxg")` compares **two** views: the **live** Reading (Aggregator, right now) and the **delayed** price (SmartOSM `cur`, what the Vat is using). The gap between them tells us which way the risk points.

### 7.1 Deciding the target state (checked top to bottom)
```
RED    if  !ok  or score < 50                      (no quorum / low confidence)
       or  SmartOSM status ≠ LIVE                  (stale, quarantined, stopped)
       or  live.lo < cur × (1 − 1.5%)              (market is clearly BELOW the price the Vat uses
                                                     → borrowing at cur = over-borrowing)
YELLOW if  score < 80  or  market closed (calendar)
GREEN  otherwise
```
**Hysteresis:** getting worse is **instant**. Getting better moves **one level at a time**, after **3 healthy checks at least 10 minutes apart**. Spamming `sync()` can't flip it back to GREEN.

### 7.2 Applying the decision: lever 1, the debt ceiling (`Vat.line`, via LineExecutor)
Current debt is $43,029.
| State | Rule | Example value | Effect on users |
|---|---|---|---|
| 🟢 GREEN | line = debt + $250k, refilled at most **once per hour** | $293,029 | borrow up to $250k of new debt per hour (**rate limit**: even an undetected bad price can't mint more than that per hour) |
| 🟡 YELLOW | on entry: line = debt + $50k, **never raised while YELLOW** | $93,029 | only $50k more in total until trust recovers |
| 🔴 RED | line = current debt | $43,029 | **no new borrowing at all**; repay lowers it further |

### 7.3 Lever 2, the liquidation guard (`Dog.hole`, via HoleExecutor)
```
guard ON  if  ok  and  score ≥ 80  and  live.hi × (1 − 3%) > cur
             ("everyone agrees the market is well ABOVE the price the Vat uses",
              i.e. the delayed price is unfairly LOW, e.g. a captured dip)
   → Dog.hole = 0  → no NEW liquidations (running auctions continue)
guard OFF when the condition clears, or after 6 hours at most
   → Dog.hole = $400,000 restored; after an expiry it can't re-arm until the condition clears once
```

### 7.4 The asymmetry, in one table
| Danger | Which direction | Our lever | What stays open |
|---|---|---|---|
| over-borrowing | the price the Vat uses is too **high** | RED / YELLOW: cap or freeze **borrowing** | liquidations, repay, deposits |
| unfair liquidation | the price the Vat uses is too **low** | guard: pause **new liquidations** | borrowing (per state), repay |

**Never touched:** the price itself (no zeroing), `Spotter.mat` (140%), fees, repayments.

---

## 8. Stage 5: the executors: bounded hands on the core
```
RiskController ──setLine(ilk, x)──► LineExecutor ──require(x ≤ cap)──► Vat.file(ilk, "line", x)
RiskController ──setHole(ilk, y)──► HoleExecutor ──require(y ≤ cap)──► Dog.file(ilk, "hole", y)
```
- They're the **only** new contracts with rights on Multipli's core, and each can change **one number**, never above the governance cap.
- Only the RiskController (and the Safe) can call them.
- Even a buggy controller can at most *lower* the ceiling or pause liquidations, never mint, never move a price.

---

## 9. Stage 6: the final step: what users and liquidators experience
All of this is **unchanged Maker code**; OracleGuard only changed the inputs (`spot`, `line`, `hole`).

### A borrower (`Vat.frob`)
When you borrow (`dart > 0`), the Vat checks:
```
1. total debt after the borrow ≤ Vat.line          else "Vat/ceiling-exceeded"   ← RiskController's lever
2. your collateral × spot ≥ your debt              else "Vat/not-safe"           ← SmartOSM's price
```
When you **repay** (`dart < 0`), check 1 is skipped entirely. That's why **repayment always works**, in every state.

*Example:* 10 PAXG deposited → borrowing power 10 × 3,123 = $31,231.
- GREEN: you can borrow up to $31,231, if the hourly budget has room.
- RED: any borrow reverts `Vat/ceiling-exceeded`, but you can still repay.

### A liquidator (`Dog.bark` → Clipper auction)
```
1. vault unsafe:  collateral × spot < debt              else "Dog/not-unsafe"             ← SmartOSM's price
2. room left:     Dog.hole > amount already in auction   else "Dog/liquidation-limit-hit"  ← guard lever
3. Clipper starts a Dutch auction at (SmartOSM price × 1.10), reading the price through the Spotter/pip
```
*Example:* a vault at 145% with a dip locked into `cur` looks unsafe, but the guard set hole = 0 → `Dog/liquidation-limit-hit` → the user keeps their gold. An hour later the price catches up and the vault is genuinely safe.

---

## 10. A full day, told as one story (every component's values)
Ceiling cap $1M, debt $43k, true gold price ≈ $4,372.
| Time | What happens in the world | Aggregator | SmartOSM | RiskController | Users |
|---|---|---|---|---|---|
| 09:00 | normal | mid $4,372, score 100 | LIVE, cur $4,372 | 🟢 GREEN, line $293k | borrow ≤ $250k/h |
| 11:00 | Chainlink stops updating (26h old) | Chainlink stale → Wq 5/7 → **71** | LIVE (others still fresh) | 🟡 **YELLOW**, line debt + $50k | borrow ≤ $50k total |
| 13:00 | attacker pushes Pyth to 10× too | Pyth outlier as well → only RedStone + DEX (3/7) → **42**, mid still ≈ $4,372 | cur unchanged | 🔴 **RED**, line = debt | borrowing frozen, repay OK |
| 15:00 | every source goes silent | ok = false, score 0 | poke skipped → **STALE**, price kept (never 0) | 🔴 RED | frozen, repay OK, **no mass liquidation** |
| 17:00 | sources return, all agree | score 100 | poke accepted → LIVE | still RED; needs 3 spaced healthy syncs | frozen |
| 17:30 | 3 healthy syncs done | 100 | LIVE | 🟡 YELLOW | $50k |
| 18:00 | 3 more | 100 | LIVE | 🟢 GREEN (refill) | $250k/h |
| 20:00 | real crash −15%, all sources agree | score 100, mid $3,716 | drop passes immediately (no quarantine): nxt $3,716, cur $3,716 an hour later | live < cur → 🔴 RED until cur catches up | liquidations **run** on unsafe vaults |
| 21:00 | a brief −15% dip was captured, but the market is back at $4,372 | score 100, mid $4,372 | cur = $3,716 (the dip) for one hour | live well above cur → 🛡️ **guard ON**, hole = 0 | healthy vaults **not** liquidated |
| 22:00 | delayed price catches up | 100 | cur $4,372 | guard OFF, hole $400k | normal |

*(The 20:00 and 21:00 rows are two alternative events, a real crash vs a brief dip, to show both directions.)*

---

## 11. Off-chain pieces around the flow
| Piece | Role | Talks to |
|---|---|---|
| **Keeper** (production: Chainlink Automation / Gelato; demo: scripts/dashboard) | calls `poke()` hourly and `sync()` after it; in the demo also refreshes the simulated sources | SmartOSM, RiskController, MockSources |
| **`deployments/fork.json`** | address book written by Deploy | read by the dashboard and the demo scripts |
| **Dashboard** (Jeffrey) | polls every 2s: `aggregator.read()/observations()`, `smartOsm.price()/status()`, `controller.status()`, `vat.ilks()`; shows sources, score (Wq × Wd × Wf), state, what each state changes, events; scenario buttons | all of the above, read-only + mock setters |
| **Validation study** (Varun, `research/`) | a Python copy of the formula for large-scale testing (Monte-Carlo, historical data) | offline |

---

## 12. What if something breaks? (failure flows)
| Failure | Where it's caught | What the flow does |
|---|---|---|
| one oracle reverts or returns garbage | Aggregator `try/catch`, price cap | ignored; score drops by its weight share |
| one oracle lies (spike/crash) | Aggregator MAD filter | outlier; price unchanged; score −(weight share) |
| one oracle goes stale | Aggregator freshness | excluded; YELLOW if it's a major one |
| all oracles stale | SmartOSM skip + STALE | last price kept (never 0), RED, repay works |
| Aggregator itself reverts | SmartOSM `try/catch` | `PokeSkipped(reason 2)`; ages → STALE → RED |
| sudden low-agreement rise | SmartOSM quarantine | held back one hour; RED while held |
| real crash, one oracle lagging | drop passes, Aggregator drops the laggard | the Vat follows the crash one hour later (design delay); RED on borrowing; liquidations run |
| dip captured by the delayed price | RiskController guard | new liquidations paused ≤ 6h |
| **2+ major oracles lie together** (Mango) | ❌ not detectable by consensus | bounded: ≤ $250k new debt per hour (rate limit), vs ≈$957k at once in legacy |
| nobody calls poke/sync | ages → STALE on the next sync | fails safe (RED) |
| Spotter.poke fails inside poke | `try/catch` | price still stored; anyone can call Spotter.poke |
| controller bug | executor caps | worst case: a lower ceiling or paused liquidations, never minting or moving the price |
| governance wants out | `Spell.rollback()` | back to the legacy OSM in one transaction |

---

## 13. Who can call what (permissions)
| Function | Who |
|---|---|
| `SmartOSM.poke`, `RiskController.sync`, `Spotter.poke` | **anyone** |
| `SmartOSM.peek/read` | whitelisted readers only: Spotter, Clipper, End |
| `SmartOSM.price/status/age`, `Aggregator.read`, `Controller.status` | anyone (views) |
| `LineExecutor.setLine`, `HoleExecutor.setHole` | RiskController (+ Admin Safe) |
| config (`addSource`, `setIlk`, `file`, `stop`, `change`) | Admin Safe / deployer (production: behind a timelock) |
| `Spotter.file` (the pip swap), `Vat.rely`, `Dog.rely` | Admin Safe only (Multipli governance) |
| `MockSource.setPrice` | deployer (demo only; real sources are updated by their networks) |

---

## 14. The whole flow in 10 lines (memorise this)
1. **Four oracles** report a price. Broken ones say "not ok" instead of crashing anything.
2. The **Aggregator** drops stale ones, takes a **weighted median** (no single oracle can move it), and rejects **outliers**.
3. It scores confidence **0–100 = coverage × agreement × freshness**.
4. **SmartOSM** stores that price with a **1-hour delay** (`nxt` → `cur`), **never outputs 0**, and holds back suspicious **rises**.
5. SmartOSM pushes `cur` to the **Spotter → Vat** (`spot = price ÷ 1.4`) in the same transaction.
6. The **RiskController** compares **live vs delayed** price, score and staleness → **GREEN / YELLOW / RED** (+ guard).
7. It acts only through **two bounded executors**: the **debt ceiling** (borrowing: $250k/h, $50k, $0) and the **liquidation limit** (the guard).
8. **Borrowers:** the Vat checks ceiling + collateral. **Repay always works** (the ceiling isn't checked on repay).
9. **Liquidators:** the Dog checks the vault is unsafe + there's room. The guard can pause **new** liquidations (≤ 6h) when the delayed price is unfairly low.
10. Installed by **one governance spell**, with **no changes to Multipli's code**, and **one-call rollback**.
