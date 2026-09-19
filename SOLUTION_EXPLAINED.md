# OracleGuard: the whole solution, explained from zero

> Read this top to bottom once (≈30 min). By the end you should be able to explain the problem, our solution, why every design choice was made, and what our weaknesses are, without looking at code.
> Companion: `IMPLEMENTATION_EXPLAINED.md` (what exactly is built, contract by contract).

---

## Part 1: The background you need (5 minutes)

### 1.1 What is rwaUSD?
- **Multipli** runs **rwaUSD**, a stablecoin (worth $1) that you **borrow** against collateral, like a loan against gold.
- You deposit a real-world asset (RWA) token, e.g. **PAXG** (1 PAXG = 1 troy ounce of physical gold held by Paxos, ≈ **$4,372** on our fork), and you can borrow rwaUSD against it.
- It's a **fork of MakerDAO** (the system behind DAI), so it uses Maker's contracts and Maker's vocabulary.

### 1.2 How borrowing works (a CDP / "vault")
- Deposit 10 PAXG (worth $43,724).
- The **liquidation ratio `mat` is 140%**: every $1 borrowed needs $1.40 of collateral. So you can borrow up to 43,724 / 1.4 ≈ **$31,231**.
- If gold falls and your collateral drops below 140% of your debt, you can be **liquidated**: the protocol seizes your collateral and auctions it to repay the debt, plus a 5% penalty.
- **The protocol only knows the gold price through an oracle.** If the oracle is wrong, everything built on it is wrong:
  - **Price too high** → people borrow more than their collateral is worth → **bad debt** (the protocol loses money, and rwaUSD is under-backed).
  - **Price too low** → healthy users are **wrongly liquidated** (they lose their gold).

### 1.3 Maker vocabulary (you WILL hear these words)
| Word | Meaning (plain English) |
|---|---|
| **Vat** | The core ledger. Stores every vault, every debt, and the price each collateral type is valued at. |
| **ilk** | A collateral type. Ours is `"paxg"`. |
| **urn** | One user's vault. |
| **ink / art** | Collateral amount in a vault / (normalised) debt in a vault. |
| **spot** | The collateral price the Vat uses, *already divided by `mat`*: spot = price / 1.4 ≈ $3,123. A vault is safe while `ink × spot ≥ debt`. |
| **line** | **Debt ceiling** for the collateral type: the max total rwaUSD that can exist against PAXG ($1,000,000 today). |
| **Spotter** | Reads the price from the oracle ("pip") and writes `spot` into the Vat. |
| **pip** | Whatever contract the Spotter reads the price from. Today: the OSM. |
| **OSM** (Oracle Security Module) | A Maker contract that **delays prices by 1 hour**. It holds `cur` (price in use now) and `nxt` (price that becomes current next hour). The delay gives humans time to react if a price is manipulated. |
| **Dog / Clipper** | Dog decides a vault is unsafe and starts a liquidation; Clipper runs the auction. **hole** = the limit on how much can be in liquidation at once. |
| **wards / rely / deny** | Admin rights (Maker's `onlyOwner`). |
| **bud / kiss** | The OSM's whitelist of contracts allowed to read the price. |
| **spell** | A governance transaction that changes the system. |

### 1.4 How rwaUSD gets its gold price TODAY (verified on-chain by us)
```
Chainlink PAXG/USD feed  →  PriceFeedAdapter  →  OSM (1h delay)  →  Spotter  →  Vat
```
1. **Chainlink** publishes the PAXG price on-chain (it updates when the price moves enough, or about once per day).
2. **PriceFeedAdapter** (Multipli's custom contract) reads Chainlink. If the Chainlink price is **older than 24h**, it says "invalid" (returns `false`).
3. **OSM** asks the adapter for a price once per hour and stores it as `nxt`; the old `nxt` becomes `cur`.
4. **Spotter** reads `cur` from the OSM and writes `spot` into the Vat.

---

## Part 2: The problem (what is actually broken)

### 2.1 The problem statement, in one sentence
"Oracles can be late, manipulated, stale, or fail. Design a better oracle, and specifically fix rwaUSD's OSM + adapter, which have attack vectors."

### 2.2 What we found by reading the real contracts (this is our strongest material)
**Bug 1: the OSM silently ignores "stale".** The adapter correctly reports "invalid" when Chainlink is >24h old. But the OSM's code is:
```solidity
(wut, ok) = src.peek();
if (ok) { cur = nxt; nxt = wut; ... }   // if NOT ok → do nothing at all
```
So when the feed is stale, **the OSM keeps serving the last price as VALID, forever**. There is no age check anywhere downstream, and the Vat has no idea how old its price is.

**Bug 2: the zero-price trap (why nobody fixed Bug 1).** The only way to mark the OSM price invalid is `void()`, which sets the price to 0. The Spotter then sets `spot = 0` → **every vault in the system becomes liquidatable at once**. So the emergency brake is a self-destruct button, and nobody will ever press it.
> **Our one-line framing:** *"The legacy oracle has two modes: trust blindly, or self-destruct."*

**Bug 3: one admin, no timelock.** A 4-of-8 multisig (Gnosis Safe) can swap the price feed instantly. The only delay is the OSM's 1 hour, and the only automated reaction deployed (`OsmMom.stop()`) *freezes the current price*. That makes staleness worse, not better.

**Bug 4: single source.** One Chainlink feed. No second opinion, no sanity check.

**Bug 5: stale-LOW is ignored by everyone.** A brief price dip captured by the OSM stays "true" for an hour after the market recovers. Healthy vaults get liquidated at the wrong price.

Also: the "fresh" price was already **16.5 hours old** when the OSM took it (a slow feed), and tokenized stocks (the next collateral types) trade on weekends while their real market is closed.

Full list of 13 vectors: `docs/PROBLEM.md`.

### 2.3 We PROVED the attacks on the real protocol (Phase 1)
We forked Ethereum mainnet (an exact local copy of the real chain at block 26,011,000) and attacked the **real deployed rwaUSD contracts**:
| Attack | What happened on the real contracts |
|---|---|
| **S1: feed goes silent for 7 days** | OSM still says "valid" on a **186-hour-old** price; 31,231 rwaUSD minted against it |
| **S3: compromised price feed (10×)** | 10 PAXG (worth **$43,724**) borrowed **$312,319** → **$268,595 of bad debt** |
| **S4: a −15% dip captured, market recovers** | A **healthy** vault (145% collateralised at the real price) was **liquidated**, and 10 PAXG was seized |

---

## Part 3: Our solution, OracleGuard

### 3.1 The idea in one paragraph
Instead of an oracle that can only say *"here is a price"* or *"price is zero"*, OracleGuard gives a **graded answer**: a price **plus a 0–100 confidence score** built from several independent oracles. The protocol then responds **proportionally**:
- full confidence → normal operation,
- medium → limit new borrowing,
- low → freeze new borrowing,
- and a special guard stops *unfair* liquidations.

It **never sets the price to zero** and **never blocks repayments**. It installs on the live protocol with **one governance transaction, no changes to the core contracts, and one-call rollback**.

### 3.2 The three layers (same as our Round 1 diagram)
```
LAYER 1: SOURCES            LAYER 2: ORACLEGUARD                              LAYER 3: MULTIPLI CORE (unchanged)
Chainlink (real)  ┐
Pyth      (sim)   ├──► Aggregator ──► SmartOSM (drop-in pip) ──────────► Spotter ──► Vat
RedStone  (sim)   │    median+score      1h delay, never 0, holds                    ▲
DEX TWAP  (sim)   ┘         │            back suspicious jumps                       │ debt ceiling (line)
                            └──────────► RiskController ──► LineExecutor ────────────┘
                                         GREEN/YELLOW/RED ─► HoleExecutor ──► Dog (liquidation limit)
```

**Layer 1: sources.** Four independent price providers, each wrapped so it **can never crash the system** (errors become "not ok"). In the demo, Chainlink is the real mainnet feed. Pyth, RedStone, and the DEX TWAP are *simulated* so we can inject attacks (explained in Part 6).

**Layer 2a: the Aggregator (the brain).** Combines the sources into one price plus a confidence score:
1. Drop sources that are stale or broken.
2. Take the **weighted median** (the middle value, so one liar can't move it).
3. Throw out **outliers**: anything far from the median (using MAD, the median absolute deviation).
4. Score = **coverage × agreement × freshness**:
   - **Wq (coverage):** the share of weight still healthy. Chainlink, Pyth, RedStone = 2 each, DEX = 1, total 7.
   - **Wd (agreement):** how tightly the healthy sources agree (2% spread → 0).
   - **Wf (freshness):** how recent the freshest healthy source is.

**Layer 2b: SmartOSM (the safe delay).** A drop-in replacement for Maker's OSM. It keeps the exact same interface, so the real Spotter, Clipper, and End work with it unchanged. Differences:
- Knows how old its price is (`age()`, `status()` = LIVE / STALE / QUARANTINED). **Staleness is no longer silent.**
- **Never outputs zero** (zero-price invariant) and `void()` is disabled, so no self-destruct button.
- A **big price RISE without broad agreement is quarantined**: it must be confirmed an hour later before it's used (inflated collateral is what enables over-borrowing). **Price drops are never held back**, so liquidations stay timely in a crash; unfair low prices are handled by the guard. We learned this from our own incident replay (Part 5).
- Updates the Vat in the same transaction (no separate Spotter step).

**Layer 2c: RiskController (the reflexes).** Turns health into action, using only two knobs:
| State | When | What changes |
|---|---|---|
| 🟢 **GREEN** | score ≥ 80, nothing wrong | Borrowing allowed, but at most **$250k of new debt per hour** (rate limit) |
| 🟡 **YELLOW** | score 50–79 (e.g. one oracle down), or market closed | New borrowing capped at **$50k in total** while YELLOW |
| 🔴 **RED** | score < 50, all stale, suspicious jump, or market clearly below the delayed price | **No new borrowing at all** |
| 🛡️ **Guard** | market clearly *above* the delayed price with full agreement (a stale-low price) | **No new liquidations**, auto-expires within 6h |
| Always | | **Repay works. Deposits work. Liquidations work in RED.** |

The knobs are touched through **executors**: tiny contracts that can change exactly one setting each, never above a governance cap.
- **LineExecutor** changes only `Vat.line`, the debt ceiling.
- **HoleExecutor** changes only `Dog.hole`, the liquidation limit.

### 3.3 Installing it: the "spell"
The Admin Safe runs one transaction that:
1. points the Spotter at SmartOSM (`Spotter.file("paxg","pip",SmartOSM)`), and
2. authorises the two executors.

That's the **entire change to the Multipli core**. Rollback = point it back at the old OSM.

### 3.4 Results: the same attacks, after the spell (real contracts, fork tests)
| Attack | Legacy rwaUSD | With OracleGuard |
|---|---|---|
| S1 one source stale 7 days | borrow on a 186h-old price | 🟡 YELLOW, new debt capped at $50k |
| S1 all sources stale | same | 🔴 RED: minting reverts, **repay works**, price never 0 |
| S2 market −8% while OSM lags | borrow at the stale-high price | 🔴 RED instantly, liquidations stay on |
| S3 compromised feed | **$268,595 bad debt** | **$0 bad debt** (outlier ignored; max borrow $31,231 < $43,724 collateral) |
| S4 captured dip | healthy vault liquidated | 🛡️ liquidation blocked, released an hour later, vault safe |

---

## Part 4: WHY we designed it this way (the decisions judges will probe)

1. **Why a graded score instead of "valid / invalid"?** Because "invalid" in a Maker system means price = 0, which means mass liquidation. Grading lets us react *without touching the price*.
2. **Why never touch the price when things look bad?** Changing the price is the most dangerous action a lending protocol can take. We act on **quantities**: how much can be borrowed, how much can be liquidated. **Zero-price invariant:** SmartOSM always returns a valid, non-zero price.
3. **Why restrict new borrowing but never repayment?** Borrowing *increases* risk; repaying *reduces* it. We only ever block risk-increasing actions.
4. **Why "borrow at the worst plausible price, liquidate only at a confirmed price" (asymmetry)?**
   - A wrong **high** price hurts through *borrowing*, so RED blocks borrowing and keeps liquidations running.
   - A wrong **low** price hurts through *liquidations*, so the guard blocks liquidations.
   - Each failure direction gets its own lever.
5. **Why not raise the collateral ratio (`mat`) when risk rises? (We did this in Round 1!)** In Maker, `mat` is **also the liquidation ratio**. Raising it from 140% to 180% mid-incident instantly makes every vault between 140–180% liquidatable. We caught this by reading the code and switched to the debt ceiling. *Say this proactively: it shows rigor.*
6. **Why a weighted median + outlier filter?**
   - The median can't be moved by one liar.
   - With weights 2/2/2/1, **no single oracle can move the price**. It takes 2 of the 3 major networks lying in the same direction.
   - The DEX gets weight 1 because thin on-chain RWA pools are cheap to manipulate.
7. **Why keep the 1-hour delay?** It is still valuable against manipulation for liquidations. We made the delay *safe* (bounded staleness, no zero) and made *borrowing* react to the live price instead.
8. **Why a rate limit even in GREEN?** Nobody can detect every failure (see limitations). The rate limit guarantees **worst case ≤ $250k per hour** even for an undetected failure. Legacy worst case: the whole remaining ceiling, ≈$957k, at once.
9. **Why can the guard only pause liquidations for 6h max?** Pausing liquidations for too long creates bad debt. It's time-boxed and needs broad agreement.
10. **Why does upgrading (RED → GREEN) require several spaced checks, while downgrading is instant?** So an attacker can't spam `sync()` to flip the system back to GREEN. Being cautious fast and relaxing slowly is standard safety practice.
11. **Why drop-in instead of a new system?** Judges (Multipli engineers) value *deployable today*: one spell, no core changes, rollback in one call.
12. **Why "freshest source" for the freshness score?** Chainlink's gold feed is often ~16–18h old *by design* (it only updates on price moves). If freshness used the *oldest* source, the healthy system would score 34 = RED. The freshest-source rule means one quiet feed doesn't punish the system; losing sources is already penalised by coverage.

---

## Part 5: How we answered the mentor review
The mentor asked for four things (full answers: `review.md`):
1. **Define the score and each oracle's contribution.**
   - The formula is above.
   - Each oracle contributes its weight share: Chainlink / Pyth / RedStone 28.6% each, DEX 14.3%.
   - Losing one major oracle → 71 (YELLOW). Losing only the DEX → 85 (GREEN). Losing two majors → 42 (RED).
   - Five worked examples ("parity vectors") are verified in the actual contract.
2. **Test against real historical failures, including correlated ones, with false positives and negatives.**
   - 9 incidents: Synthetix sKRW, Compound DAI, Pyth BTC, LUNA clamp, stale feeds, **Mango** (all oracles wrong together), **USDC/SVB depeg** and **Black Thursday** (all oracles *correctly* moving together), and a PAXG-vs-gold dislocation.
   - Plus Monte-Carlo fault injection on real gold history.
   - **On-chain replay done (K6b):** over 55 simulated hours on the real contracts, over-borrowing hours went **21 → 2** (both Mango, capped at $250k), unfair-liquidation hours **5 → 1**, and the guard never blocked liquidations in a real move.
   - **The replay caught a real flaw.** Quarantine froze the price during real crashes (Black Thursday: 4h). We fixed it (only rises are quarantined): 4h → 0h. *Tell this story: it proves the testing is real.*
   - Varun's Python study (Monte-Carlo, threshold sweep) is still in progress.
3. **What each state changes.** The exact table in Part 3.2, now implemented and tested.
4. **Quantify the risk reduction.**
   - Bounds: $957k → $250k per hour (GREEN) / $50k (YELLOW) / $0 (RED).
   - Measured: $268,595 → $0, and 1 unfair liquidation → 0.

---

## Part 6: Trade-offs and limitations (be honest; judges respect it)

| # | Limitation | Why it exists | What we do about it / what to say |
|---|---|---|---|
| L1 | **Correlated failures can't be detected by consensus.** If 2 of 3 major oracles are wrong in the same direction (Mango-style), the median follows them. | True of *every* median oracle, including Chainlink's own network. | We **bound** the damage instead: hourly borrowing cap ($250k/h), 1h delay, quarantine of low-agreement jumps. Corrupting 2 independent networks on the global gold market is extremely expensive. Future: an independent "fundamental" source (gold spot × ounces per token). |
| L2 | **3 of 4 sources are simulated in the demo** | Attack scenarios need controllable sources. Real Pyth/RedStone updates need fresh signed data, which is hard on a fork. | Chainlink is the real mainnet feed. The others sit behind the same interface a real adapter would use. Varun's PythSource is optional work. Say this upfront. |
| L3 | **Gas:** SmartOSM update ≈247k gas vs ≈40k legacy | 4 sources + median + score + Vat update | Once per hour ≈ a few dollars. Negligible vs the debt protected. |
| L4 | **The Vat has one price for both borrowing and liquidation** | Maker core design; we don't change core contracts | We get asymmetric *behaviour* through two levers (ceiling vs liquidation limit). A future v2 Vat could take separate prices. |
| L5 | **Pausing liquidations is risky if prolonged** | The guard protects users from unfair liquidations | Only fires with broad agreement that the market is *above* the delayed price (i.e. vaults are safer than they look). Max 6h. Won't re-arm until the condition clears. |
| L6 | **Parameters (thresholds, gaps, weights) are reasoned, not yet calibrated** | Hackathon time | Varun's validation study sweeps thresholds (70/80/90, ε 1/1.5/3%) and reports FP/FN. |
| L7 | **Admin-key risk (4-of-8 Safe, no timelock) is governance, not code** | We can't force Multipli's governance | Recommend Safe → 48h timelock plus a guardian that can only tighten. |
| L8 | **Keepers must poke/sync** | Like the legacy OSM, someone must call update functions | Both are permissionless. Production: Chainlink Automation / Gelato plus a small bounty. If nobody pokes, the price ages → STALE → RED (fails safe). |
| L9 | **During total oracle failure, existing vaults keep the last good price** | Better than price = 0 (mass liquidation) | New borrowing is frozen (RED) until sources return. A conscious trade-off. |
| L10 | **Only PAXG today; tokenized stocks need a market-hours calendar** | Scope | SessionCalendar (Varun) makes closed markets YELLOW. Weekend-gap math is in the research. |
| L11 | **Fork demo ≠ production** | Hackathon | Needs an audit plus Multipli governance approval. |
| L12 | **Thin-liquidity DEX data is manipulable** | RWA tokens trade little on-chain | Weight 1 (14%), rejected as an outlier if off, and it can never move the median alone. |

**The honest summary:** "We can't *detect* every oracle failure (nobody can), but we make every failure **visible, bounded, and non-catastrophic**, where today it is invisible, unbounded, and potentially catastrophic."

---

## Part 7: What's done, what's left (as of now)
| Item | Owner | Status |
|---|---|---|
| Research + verified on-chain facts + threat model | Kapilan | ✅ |
| Baseline exploits on real contracts (S1, S3, S4) | Kapilan | ✅ |
| Sources, executors, Aggregator (+ weight-based score), SmartOSM, RiskController | Kapilan | ✅ |
| Deploy / Spell scripts (tested on a live anvil fork) + OracleGuard fork tests | Kapilan | ✅ (91 tests green) |
| Historical incident replay on-chain (K6b): found and fixed the quarantine flaw | Kapilan | ✅ (101 tests) |
| Integration (K7), invariants (K8) | Kapilan | ⬜ next |
| Validation study (FP/FN, Monte-Carlo), SessionCalendar, demo scripts, PythSource | Varun | in progress |
| Dashboard, deck, video | Jeffrey | in progress |

---

## Part 8: The 2-minute pitch (memorise the flow, not the words)
1. **Hook (15s):** "rwaUSD prices gold through an oracle that has exactly two modes: trust blindly, or self-destruct. We proved it on the real contracts."
2. **Problem (25s):** "When the feed goes stale, the OSM keeps the old price as valid forever. We minted on a 186-hour-old price. A compromised feed turned $43,724 of gold into $312,319 of debt. And a brief dip liquidated a healthy vault. The only emergency brake sets the price to zero, which liquidates everyone."
3. **Solution (40s):** "OracleGuard: four independent sources, a median that no single oracle can move, and a 0–100 confidence score. A drop-in SmartOSM that knows how old its price is and can never output zero. A controller that responds in grades: GREEN rate-limits borrowing, YELLOW caps it, RED freezes it, and a guard stops unfair liquidations. Repayments always work."
4. **Proof (25s):** "Same attacks, same real contracts, after one governance transaction: $268k of bad debt becomes zero, the unfair liquidation is blocked, and stale data freezes borrowing instead of being trusted. Rollback is one call."
5. **Honesty + close (15s):** "Correlated failures can't be detected by any median oracle, so we bound them to $250k per hour instead of ≈$957k at once. We validated against 9 historical incidents. Graduated trust instead of binary trust."

---

## Part 9: Tough questions and answers (practise these)

**Q: Why not just make the OSM reject stale prices?**
A: Rejecting means `has = false` → Spotter sets spot = 0 → every vault is liquidatable. That's why nobody did it. Rejecting is only safe if the reaction happens somewhere other than the price, which is exactly what our controller does.

**Q: What if Chainlink AND Pyth are both wrong?**
A: Then the median follows them. No median-based oracle can detect a majority lying together. We bound the damage (≤ $250k/h in GREEN; the jump quarantine catches sudden low-agreement moves; big disagreements drop the score to 0 → RED), and corrupting two independent networks on the global gold market is extremely expensive. We quantify it in the validation study.

**Q: Won't RED stop liquidations during a crash and create bad debt?**
A: No. RED **only** blocks new borrowing. Liquidations stay on (tested: S2). Only the guard pauses liquidations, and only when the market is *above* the delayed price.

**Q: Your other oracles are fake.**
A: They're simulated on purpose so we can inject attacks, behind the exact interface a production adapter implements. The Chainlink feed is the real mainnet one. The logic being tested is the aggregation, which is real.

**Q: Why should Multipli trust a new contract with power over the Vat?**
A: The executors can change exactly one number each (debt ceiling / liquidation limit), never above a governance cap, and only when called by the controller. The Safe can revoke them in one call. That's the same pattern Maker itself uses (DssAutoLine, ClipperMom).

**Q: How is the score calculated?**
A: 100 × coverage × agreement × freshness. Coverage = weight share of healthy, agreeing sources (Chainlink/Pyth/RedStone 2 each, DEX 1). Agreement falls to 0 at a 2% spread. Freshness uses the freshest source, with a grace period of half its max age.

**Q: Why 80 / 50 thresholds?**
A: With our weights, losing only the DEX (least reliable) still gives 85 → GREEN, losing any major oracle gives 71 → YELLOW, and losing two majors gives 42 → RED. The thresholds sit between those cases. The validation study sweeps them.

**Q: What does it cost users?**
A: In normal conditions nothing: GREEN allows $250k of new debt per hour, and the whole ilk today has $43k of debt. The study measures how often normal days go YELLOW/RED (the false-positive cost).

**Q: Isn't the $250k/h cap too restrictive for growth?**
A: It's a parameter. Governance sets it relative to liquidity; it only caps the *rate*, not total borrowing (the $1M ceiling still applies).

**Q: What if nobody calls poke/sync?**
A: The price ages → SmartOSM reports STALE → the next sync sets RED. The system fails safe. In production: Chainlink Automation/Gelato plus a bounty.

**Q: Why not use Chainlink Data Streams / an existing product?**
A: Any single provider is still a single point of failure; the rwaUSD problem is also in the OSM and the reaction logic, not only the feed. OracleGuard can include Data Streams as one more source.

**Q: What happens at the moment of the swap?**
A: SmartOSM is primed with the legacy OSM's current price, so there's no price jump (tested). Rollback restores the legacy pip and the original ceiling.

**Q: How is this different from aso-sentinel / Multipli's own v2 docs?**
A: Those cover one lever (freeze borrowing) and one direction (stale-high). We fix the oracle itself (SmartOSM), add the stale-low direction (guard), grade responses, rate-limit even when healthy, and prove it on the real contracts.

**Q: What would you do with more time?**
A:
- A verifiable challenge window: anyone can void a bad queued price with signed data from other oracles.
- Proof-of-Reserve gating.
- A fundamental gold anchor source.
- Timelocked governance.
- Market-hours rules for stocks.
- An audit.

---

## Part 10: Glossary of our own terms
| Term | Meaning |
|---|---|
| **Aggregator** | Combines sources → price (mid), band (lo/hi), score, ok |
| **mid / lo / hi** | Median price / lowest and highest *agreeing* source |
| **inlier / outlier** | A source close to / far from the median (MAD test) |
| **score** | 0–100 confidence = 100 × Wq × Wd × Wf |
| **SmartOSM** | Our drop-in OSM: delayed price, freshness, quarantine, never 0 |
| **quarantine** | Holding back a big low-agreement jump until it's confirmed an hour later |
| **RiskController** | Maps score/health → GREEN/YELLOW/RED/guard → levers |
| **executor** | A contract allowed to change exactly one Maker parameter, within a cap |
| **greenGap / yellowGap** | $250k per hour / $50k total of new borrowing allowed |
| **guard** | Pause on new liquidations when the delayed price is unfairly low |
| **spell** | The governance transaction that installs OracleGuard |
| **fork** | A local exact copy of Ethereum mainnet at a fixed block, used to test against the real contracts |
| **zero-price invariant** | SmartOSM never reports price 0 or "invalid" after setup |
