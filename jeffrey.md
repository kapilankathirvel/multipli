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

### J3. Scenario controls (≈1.5h), your own code, no keeper needed — ✅ done, verified live on a mainnet fork (Sep 19)
- [x] `src/scenarios.ts` using viem **test actions** against anvil (`increaseTime`, `mine`, `snapshot`, `revert`, `impersonateAccount`) + `IMockSource.setPrice` + `smartOsm.poke()` + `controller.sync(ilk)`
- [x] Buttons (`components/ScenarioBar.tsx`): Reset · S1 · S2 · S3 · S4 · Poke · Sync · Warp +1h, one `Runner` interface with a mock and a live implementation; busy state, and a status line that shows the revert reason when a tx fails
- [x] In mock mode the buttons drive the simulated world (`applyScript`), so it all styles and demos without a chain
- [x] ⚠️ Live mode: `setPrice` is sent from **anvil account #0** (`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`), impersonated so no private key lives in the repo. `poke()`/`sync()` are permissionless.
- [x] ⚠️ Live mode: sources are refreshed **inside** the poke helper — order is `waitForHop` (warp to `zzz + hop`, else `poke()` reverts `OSM/not-passed`) → `setPrice` → `poke`. Refreshing before the hop warp would re-stale the mocks (1h maxAge). "Warp +1h" = warp → refresh → poke → sync, and the mock world follows the same steps.
- [x] Reset takes its own `evm_snapshot` on mount (`fork.json` ships `snapshotId: "0x0"`) and re-snapshots after each revert, since anvil consumes snapshots.
- **Commit:** `feat(dashboard): scenario controls`

### J4. Legacy vs OracleGuard panel (≈1h) — ✅ done
- [x] Side-by-side `components/LegacyPanel.tsx`: Legacy OSM (price, **VALID** even when hours stale, age, "staleness check: none", 1 source) vs OracleGuard (score, state + 🛡️, OSM status/age, inliers counted)
- [x] S3 killer-moment banner: **"Legacy: 10 PAXG ($43,724) minted $312,319 → $268,595 bad debt"** vs "OracleGuard: blocked — the ×10 feed is an outlier". Fires automatically when the legacy price deviates > 50% from the OracleGuard median.
- [x] Bonus S1 banner (same numbers source, `docs/DEMO_SCRIPT.md` §D): stale-but-"VALID" legacy price → 31,231 rwaUSD minted vs OracleGuard RED. Fires when legacy age > 24h and state = RED.
- [x] Live mode now reads the legacy OSM's own `zzz` for its age (it was borrowing SmartOSM's age before, which understated it)
- **Commit:** `feat(dashboard): legacy vs OracleGuard comparison + S3 banner`

### J5. Pitch deck (≈1.5h) · `docs/PITCH.md`
- [ ] Fix the 3 claims first (`ACTION_ITEMS.md` → Pitch): cite or soften "13%", drop "first ever", TVL ≈$340M rwaUSD supply with a source
- [ ] 8 slides per `docs/PITCH.md`; diagram from `docs/ARCHITECTURE.md`; numbers from `docs/DEMO_SCRIPT.md` §D; risk charts from Varun's `research/out/` when available (placeholder until then)
- [ ] Round 1 → Round 2 line: the `mat` → debt-ceiling refinement (`docs/DECISIONS.md` ADR-001)
- [ ] **3 mentor-review slides** (content in `review.md`): (1) score definition + oracle contribution table (§R1.3), (2) validation: incident list + FP/FN table (placeholder until Varun's `research/RESULTS.md`), (3) risk reduction: §R4.1 bounds + §R4.2 fork numbers
- [ ] Add the `review.md` "Defence cheat-sheet" to the Q&A section of `docs/PITCH.md`
- **Commit:** `docs(pitch): final deck + fixed claims`

### J6. Go live + video (≈1h, after the integration checkpoint)
> ✅ Integration checkpoint passed (K7): Deploy + Spell work end-to-end on anvil and write `deployments/fork.json` with the keys your dashboard expects. Until Varun's demo-up lands, bring the fork up manually with the commands in `contracts/script/Deploy.s.sol` / `Spell.s.sol` headers (or `docs/TECH_STACK.md`), then copy `deployments/fork.json` to `dashboard/public/fork.json`.
- [x] `VITE_MODE=live` against a running fork → click through S1–S4 ✅ Sep 19: all 8 buttons pass on a mainnet fork, headless and in Chrome (`dashboard/DASHBOARD.md` §10)
- [ ] Record the 3-min video (`docs/DEMO_SCRIPT.md` §A) against the live fork; link it in README + deck
- **Commit:** `docs: demo video link`

## Budget ≈9h (incl. mentor review items).

---

## Progress log (newest first)

### Sep 19 — Foundry installed, live end-to-end verified, `DASHBOARD.md`
**Tooling:** Foundry **v1.5.1** (same as Kapilan) installed from the official `foundry-rs/foundry` release to `%USERPROFILE%\.foundry\bin`, added to the user PATH; zip SHA-256 checked against GitHub's recorded digest. solc 0.8.24 auto-downloaded on first build. No other chain tooling needed.

**Live run:** anvil fork of mainnet @ 26,011,000 (Tenderly archive RPC) → `Deploy.s.sol` → `Spell.s.sol` as the impersonated Admin Safe → verified `Spotter.pip` = SmartOSM, GREEN, score 100, line $293,029. Then every button, headless (the dashboard's own `data.ts` + `scenarios.ts` from Node) and clicked in Chrome against `pnpm dev --mode live`. Results match `docs/DEMO_SCRIPT.md` §D: S1 RED/STALE + S1 banner · S2 RED, score 71 · S3 YELLOW + legacy $43,724.78 + S3 banner · S4 GREEN + 🛡️, OSM cur $3,716.61 · Poke/Sync/Warp/Reset ✓. UI `Wq·Wd·Wf` = contract score in every state.

**Bugs the live run found (fixed, all in `dashboard/`):**
| Bug | Fix |
|---|---|
| viem caches `getBlockNumber()` ~4s → after a button, ages + event-log range used the previous block (S1 ages didn't move) | `getBlockNumber({ cacheTime: 0 })` in `src/data.ts` |
| S3 compromised a mock the legacy stack never reads → no legacy contrast, banner never fired | `src/scenarios.ts` also writes `Baseline_S3`'s end state (10× `cur`) into the legacy OSM via `anvil_setStorageAt`; Reset reverts it |
| event log printed raw WAD/RAD integers + bytes32 ilk | `formatEventArg()` in `src/data.ts` → `$`, state names |
| Chainlink maxAge shown as "1.0d" | whole hours ("25h") in `SourcesTable.tsx` |
| stale feeds labelled "outlier"; Wf said "0s old" with no inliers | "not checked" pill; "no inliers to measure" |
| buttons' accessible name was the tooltip | `aria-label` in `ScenarioBar.tsx` |

**Also:** `dashboard/DASHBOARD.md` (new, full guide) · `dashboard/.gitignore` ignores `public/fork.json` · README points to it. Deploy/Spell docs now use `--slow` (burst-sent txs got stuck "queued" in anvil's mempool on this fork).


### Sep 19 — J3 + J4 complete
**Built / changed** (all inside `dashboard/`):
| File | What |
|---|---|
| `src/scenarios.ts` | **new** — `Runner` interface with a mock and a live (viem test actions) implementation. Live primitives: `market()` (honest reference = the untouched Chainlink source), `setMocks()`, `warp()`, `waitForHop()`, `poke(prepare)`, `sync()`, `send()` (mines, waits, and throws on a reverted tx). Scenario steps follow `docs/DEMO_SCRIPT.md` §B. |
| `src/components/ScenarioBar.tsx` | **new** — 8 buttons + busy state + status line (shows the revert reason on failure); takes the Reset snapshot on mount in live mode. |
| `src/components/LegacyPanel.tsx` | **new** — J4 side-by-side + the S3 and S1 killer-moment banners. |
| `src/data.ts` | `loadFork`/`ForkShape` exported for the runner; legacy age now from the legacy OSM's own `zzz`; mock `warp1h` now warps → refreshes → pokes → syncs, matching the live runner step for step. |
| `src/abi/IMockSource.json`, `src/abi/IPriceSource.json` | copied from the frozen `abi/`. |
| `src/index.css`, `src/App.tsx` | styles + wiring for the scenario bar and the comparison panel. |

**Verified:** `tsc -b`, `oxlint`, `pnpm build`, `pnpm check:parity` (5/5) all clean · dev server serves the new modules · scripted run of every button through the mock world: S1 → score 0, RED, OSM STALE, **S1 banner** · S2 → Chainlink outlier, Wq 0.71, RED · S3 → legacy $43,723 vs guard $4,372, **S3 banner**, YELLOW · S4 → `cur` $3,716 with live $4,372 → GREEN + 🛡️ · Warp +1h → poke lands, OSM age back to 0.
**Not verified:** the live (anvil) path — Foundry isn't installed on this machine, so J6 is the first real run. The live steps were written against K5's `script/DeployLib.sol` + `SmartOSM.poke` source, not against a running chain.

**Next:** J5 pitch deck (`docs/PITCH.md`), then J6 go-live + video.

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
