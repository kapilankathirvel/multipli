# jeffrey.md: Jeffrey's tasks (≈25%: dashboard + deck + video)

> **Role:** everything the judges *see*. **You never wait for contracts:** you build against the frozen ABIs in `abi/` with a mock data mode, and switch to live at the integration checkpoint (~hour 20).
> **Start every Claude/Cursor session with:** "Read CLAUDE.md, jeffrey.md, docs/ARCHITECTURE.md §7 and docs/DEMO_SCRIPT.md, then do the next unchecked task in jeffrey.md. Only edit files in Jeffrey's ownership list."
> Tick boxes here as you go.

## Setup (≈15 min)
- [x] `git clone https://github.com/kapilankathirvel/multipli.git && cd multipli`
- [x] Node 20 + `npm i -g pnpm`. (Foundry is only needed for the final live demo; see varun.md Setup) — running Node 22.19 / npm 10.17; `dashboard/node_modules` installed

## Ownership (only you edit these)
```
dashboard/**      docs/PITCH.md      deck/**
```

## What you build against (frozen, already in the repo)
- **ABIs:** `abi/IOracleGuardAggregator.json`, `abi/ISmartOSM.json`, `abi/IRiskController.json`, `abi/IMockSource.json`, `abi/IVat.json`, `abi/IDog.json`, `abi/ISpotter.json`
- **Addresses:** `deployments/fork.example.json` (the real file `deployments/fork.json` has the same shape)
- **Views to call:** `aggregator.read()`, `aggregator.observations()`, `smartOsm.price()/status()/age()`, `controller.status(ilk)`, `vat.ilks(ilk)`. Events: `Poke, PokeSkipped, Quarantined, StateChanged, GuardOn, GuardOff, Synced`
- **Legacy OSM price** (for the comparison panel): `eth_getStorageAt(legacyOsm, slot 3)`, where the low 128 bits = price (WAD) and the high bits = has
- `ilk` as bytes32 = `0x7061786700000000000000000000000000000000000000000000000000000000` ("paxg")

## Tasks (in order, no external dependencies)

### J1. Scaffold + mock mode (≈1h) — ✅ done
- [x] `pnpm create vite dashboard --template react-ts`; add `viem recharts` + Tailwind
- [x] `src/data.ts`: one interface, two implementations: `mock` (animated fake data, scenario-scriptable) and `live` (viem `createPublicClient`, polling every 2s). Switch with `VITE_MODE=mock|live`
- [x] `src/protocol.ts`: the score formula + state machine in TS (mirrors `OracleGuardAggregator.sol` and `review.md` §R1.2/§R3). The mock **derives** score/state/line/guard from simulated feeds instead of hard-coding them, so every panel stays self-consistent and J3's buttons only have to move feeds.
- [x] `scripts/parity.mjs` + `pnpm check:parity`: reproduces all 5 `review.md` §R1.4 parity vectors (V-a…V-e) — proof the UI formula equals the contract's.
- **Commit:** `feat(dashboard): scaffold with mock/live data layer`

UI data shapes:
```ts
type Source   = { name: string; price: number; ageSec: number; fresh: boolean; inlier: boolean };
type Reading  = { mid: number; lo: number; hi: number; score: number; nInliers: number; ok: boolean };
type OsmState = { cur: number; nxt: number; ageSec: number; status: "UNINIT"|"LIVE"|"STALE"|"QUARANTINED"|"STOPPED" };
type Risk     = { state: "GREEN"|"YELLOW"|"RED"; guard: boolean; lineUsd: number; debtUsd: number };
type Legacy   = { price: number; valid: boolean; ageHours: number };
```

### J2. Panels (≈3h) — ✅ done
- [x] Sources table (fresh/stale + inlier/outlier pills) · Confidence gauge 0–100 with GREEN/YELLOW/RED bands + lo–mid–hi band
- [x] Big state badge + 🛡️ liquidation-guard flag (+ the trigger that put us in this state) · Vat panel (debt vs line headroom; "new borrowing: open / limited / frozen")
- [x] Event log (decoded events)
- [x] **Mentor review R1:** a "contribution" column in the sources table = weight share (live: from `aggregator.sourceCount()/sourceAt(i)`; mock: 2/2/2/1 per §R1.1) with a ✓/✗ for whether it currently counts toward confidence; the score is rendered as `⌊100 · Wq · Wd · Wf⌋` with the three factors computed in the UI (`src/protocol.ts:factorsOf`) plus a bar + one-line explanation each
- [x] **Mentor review R3:** `components/StateEffects.tsx` — "What this state changes" renders the `review.md` §R3 row for the current state (borrow ✅/⚠️/❌, repay ✅, liquidations ✅/⏸️, `Vat.line`, `Dog.hole`, "`Spotter.mat` never touched")
- **Commit:** `feat(dashboard): Oracle War Room panels`

### J3. Scenario controls (≈1.5h), your own code, no keeper needed
- [ ] `src/scenarios.ts` using viem **test actions** against anvil (`increaseTime`, `mine`, `snapshot`, `revert`, `impersonateAccount`) + `IMockSource.setPrice/setOk` + `smartOsm.poke()` + `controller.sync(ilk)`
- [ ] Buttons: Reset (revert to `snapshotId`) · S1 stale feed (warp 25h, set mocks stale) · S2 market −8% (mocks −8%) · S3 compromised source (one mock ×10) · S4 captured wick (all −15% → poke → recover) · Poke · Sync · Warp +1h. Exact steps: `docs/DEMO_SCRIPT.md` §B
- [ ] In mock mode the buttons drive the fake data, so you can build and style it all now
- [ ] ⚠️ Live mode: **refresh the three mock sources (`setPrice`) before every `poke()` and after every time warp.** They have a 1h max age; if they go stale the poke is skipped (found while testing K3). "Warp +1h" should = warp → setPrice(current market) → poke → sync
- **Commit:** `feat(dashboard): scenario controls`

### J4. Legacy vs OracleGuard panel (≈1h)
- [ ] Side-by-side: Legacy OSM (price, "VALID" even when stale, age) vs OracleGuard (score, state)
- [ ] S3 killer-moment banner: **"Legacy: 10 PAXG ($43,724) minted $312,319 → $268,595 bad debt"** vs "OracleGuard: blocked"
- **Commit:** `feat(dashboard): legacy vs OracleGuard comparison + S3 banner`

### J5. Pitch deck (≈1.5h) · `docs/PITCH.md`
- [ ] Fix the 3 claims first (`ACTION_ITEMS.md` → Pitch): cite or soften "13%", drop "first ever", TVL ≈$340M rwaUSD supply with a source
- [ ] 8 slides per `docs/PITCH.md`; diagram from `docs/ARCHITECTURE.md`; numbers from `docs/DEMO_SCRIPT.md` §D; risk charts from Varun's `research/out/` when available (placeholder until then)
- [ ] Round 1 → Round 2 line: the `mat` → debt-ceiling refinement (`docs/DECISIONS.md` ADR-001)
- [ ] **3 mentor-review slides** (content in `review.md`): (1) score definition + oracle contribution table (§R1.3), (2) validation: incident list + FP/FN table (placeholder until Varun's `research/RESULTS.md`), (3) risk reduction: §R4.1 bounds + §R4.2 fork numbers
- [ ] Add the `review.md` "Defence cheat-sheet" to the Q&A section of `docs/PITCH.md`
- **Commit:** `docs(pitch): final deck + fixed claims`

### J6. Go live + video (≈1h, after the integration checkpoint)
- [ ] `VITE_MODE=live` against Kapilan's running fork → click through S1–S4 → record the 3-min video (`docs/DEMO_SCRIPT.md` §A); link it in README + deck
- **Commit:** `docs: demo video link`

## Budget ≈9h (incl. mentor review items).

---

## Progress log (newest first)

### Sep 19 — J1 + J2 complete, verified
**Built / changed** (all inside `dashboard/`):
| File | What |
|---|---|
| `src/protocol.ts` | **new** — TS mirror of `OracleGuardAggregator.sol` (weighted median → MAD outliers → `Wq/Wd/Wf` → score) + the `review.md` §R3 controller rules (`deriveState`, `lineFor`, `effectsFor`). Single source of truth for the mock world *and* the UI factor breakdown. |
| `src/data.ts` | mock rewritten as a **simulation**: scenarios only move feeds (price / freshness / liveness), everything else is derived. `poke` mirrors `SmartOSM.poke` (quorum → jump quarantine → `cur ← nxt`), `sync` mirrors the controller. Live provider now reads `sourceCount()/sourceAt(i)` for weights + maxAge, names sources from `fork.json`, and uses **chain time** (not wall time) for ages. |
| `src/components/SourcesTable.tsx` | R1 contribution column: weight-share bar + % + ✓/✗ counted; per-feed `w2 · maxAge 25h` sub-label; header shows "3/4 counted · 71.4% of weight". |
| `src/components/ConfidenceGauge.tsx` | R1 `⌊100 · Wq · Wd · Wf⌋` line with live numbers + three factor bars (quorum / agreement / freshness) with explanations. |
| `src/components/StateEffects.tsx` | **new** — R3 "What this state changes" panel (borrow, repay, deposit, withdraw, new liquidations, running auctions, `Vat.line`, `Spotter.mat`) + the trigger sentence. |
| `src/components/StateBadge.tsx` | shows the trigger that produced the current state. |
| `src/index.css` | styles for the three new blocks. |
| `scripts/parity.mjs`, `package.json` | `pnpm check:parity` — the 5 `review.md` §R1.4 vectors. |
| `README.md` | full test instructions for J1/J2 (mock) + live mode. |

**Verified:** `pnpm check:parity` → 5/5 vectors (V-a 100, V-b 85, V-c 71, V-d 75, V-e 0) · `tsc -b` clean · `pnpm build` clean · scenario smoke run through the mock provider: idle GREEN 97–100 · S1 all-stale → no quorum → score 0 → RED + OSM STALE (legacy still "valid" at 41.5h) · S2 −8% with a lagging Chainlink → outlier, `Wq` 0.71, RED via `live.lo < OSM−1.5%` · S3 Chainlink ×10 → excluded, score 70 YELLOW while **legacy shows $43,727** · S4 wick captured (`cur` $3,716, live $4,372) → 🛡️ guard ON.

**Next:** J3 scenario controls (buttons already have `applyScript('reset'|'s1'…'warp1h')` wired into the mock; live mode needs the viem test actions).
