# Oracle War Room (`dashboard/`)

> **Full guide:** [`DASHBOARD.md`](DASHBOARD.md) — every panel, every button, why it exists, and the end-to-end run on a real mainnet fork.

React 19 + Vite + viem + Tailwind + Recharts. **Mock mode needs no chain** — it runs a small
simulation of the aggregator + controller (`src/protocol.ts`), so the panels show derived numbers,
not canned ones. Live mode polls Kapilan's anvil fork every 2s.

## 1. Run it (J1 + J2, mock — do this now)

```bash
cd dashboard
pnpm install     # already done on this machine
pnpm dev
```

Open **http://localhost:5173**.

### What you should see

| # | Panel | Check |
|---|---|---|
| 1 | **Sources** | 4 feeds (Chainlink / Pyth / RedStone / DEX TWAP), prices ticking every 2s, `fresh`/`inlier` pills green. Chainlink sits ~16.5h old on purpose (it's a deviation feed, `maxAge 25h`). |
| 2 | **Sources → Contribution** (review R1) | a weight-share bar per feed: **28.6 / 28.6 / 28.6 / 14.3 %** with a green ✓. Header reads `4/4 counted · 100.0% of weight`. |
| 3 | **Confidence** | gauge 0–100 (≈97–100 at idle), lo–mid–hi band, and the line `score = ⌊100 · Wq · Wd · Wf⌋ = ⌊100 · 1.00 · 0.98 · 1.00⌋ = 97` with three factor bars. |
| 4 | **Controller** | big **GREEN** badge, 🛡️ guard `OFF · liquidations open`, OSM `cur`/`nxt`, and the trigger sentence. |
| 5 | **Vat · paxg** | debt ≈ $43,029, line $293,029 (= debt + the $250k/h GREEN gap from review §R3), headroom bar, `new borrowing: open`. |
| 6 | **What this state changes** (review R3) | 8 rows: borrow `up to $250,000/h`, repay `always allowed`, new liquidations `open — Dog.hole = $400,000`, `Vat.line $293,029`, `Spotter.mat never touched (ADR-001)`. |
| 7 | **Legacy OSM vs OracleGuard** (J4) | side by side: legacy price with a red **VALID** badge and `staleness check: none`, vs OracleGuard's price, score, state and OSM status. Killer-moment banner appears under it during S1 and S3. |
| 8 | **Event log** | `Init` / `Synced` lines; more appear as scenarios run. |
| 9 | top-right | pill reads **MOCK**; the scenario buttons sit just below the header. |

### Drive the scenarios (J3)

The button row above the panels runs the scenarios in both modes (in mock mode it drives the
simulation; in live mode it drives anvil). `og('s1')` etc. also still work from the DevTools
console in `pnpm dev`.

Each scenario produces:

| Script | Expected |
|---|---|
| `s1` stale feed | warp +26h with nobody publishing → all 4 stale → **no quorum**, score **0**, `PokeSkipped NO_QUORUM`, OSM **STALE**, **RED**, borrowing frozen — while **Legacy still says "VALID"** at 41.5h old (→ S1 banner). |
| `s2` market −8% | fast feeds drop, Chainlink lags → Chainlink becomes an **outlier** (✗, Wq 0.71) → **RED** via `live.lo < OSM − 1.5%`. No poke: the OSM is supposed to lag. Liquidations stay open. |
| `s3` compromised source | one source ×10 ($43,723) → rejected as an outlier, mid unchanged, score ~70 → **YELLOW**. The legacy panel is the killer moment: it *takes* the ×10 price (→ S3 banner). |
| `s4` captured wick | all sources −15%, two pokes push the wick into `cur` ($3,716), market recovers to $4,372 → 🛡️ **guard ON** (`Dog.hole = 0`, max 6h) while the state stays GREEN. |
| `poke` / `sync` / `warp1h` | `poke` = wait for the hop → refresh the sources → `SmartOSM.poke()`; `sync` = `RiskController.sync(paxg)`; `warp1h` = `evm_increaseTime(3600)` → refresh → poke → sync. |
| `reset` | live: `evm_revert` to the snapshot taken on page load, then re-snapshot. Mock: reseeds the world. |

## 2. Checks you can run

```bash
cd dashboard
pnpm check:parity   # review.md §R1.4 vectors: V-a 100, V-b 85, V-c 71, V-d 75, V-e 0  -> all PASS
pnpm build          # tsc -b + vite build, must be clean
pnpm lint
```

`check:parity` is the important one: it proves the formula the dashboard displays is the same one
`OracleGuardAggregator.sol` implements (and the one Varun's Python model is checked against).

## 3. Live mode (after the integration checkpoint)

1. Bring up the fork and install OracleGuard — exact commands in [`DASHBOARD.md` §7.2](DASHBOARD.md) (anvil → `Deploy.s.sol --slow` → `Spell.s.sol --slow`), or Varun's `scripts/demo-up` once it lands. That writes `deployments/fork.json`.
2. Copy it into the dashboard's static folder:

```powershell
copy ..\deployments\fork.json public\fork.json
```

3. Start the UI against anvil:

```bash
pnpm dev --mode live      # use the URL Vite prints (moves to :5174 if :5173 is busy)
```

**Reads:** `aggregator.read()` / `observations()` / `sourceCount()` / `sourceAt(i)`,
`smartOsm.price()/status()/age()/zzz()/hop()/pass()`, `controller.status(ilk)`, `vat.ilks(ilk)`,
the legacy OSM's slot 3 + its `zzz`, and it decodes
`Poke / PokeSkipped / Quarantined / StateChanged / GuardOn / GuardOff / Synced`.
Ages use **chain** time, so time warps don't break them.

**Writes** (scenario buttons only): `MockSource.setPrice` on the three mock feeds — sent from
**anvil account #0** (`0xf39F…2266`, the deployer and therefore their ward), impersonated so no
private key sits in the repo — plus the permissionless `SmartOSM.poke()` and
`RiskController.sync(paxg)`, and the anvil test RPCs `evm_snapshot / evm_revert / evm_increaseTime /
evm_mine`. It never writes to OracleGuard's state or the live Maker core. Exception: S3 writes a
10× price into the **legacy OSM**'s storage (`anvil_setStorageAt`, slot 3) so the comparison panel has a
compromised legacy to compare against — after the spell nothing reads it ([`DASHBOARD.md` §5](DASHBOARD.md)).

Two ordering rules the runner enforces (learned in K3):
1. `poke()` reverts `OSM/not-passed` until `zzz + hop`, so it warps to the next hop first;
2. the mocks have a **1h maxAge**, so they are refreshed *after* that warp and immediately before
   the poke — refreshing earlier would re-stale them and the poke would be skipped.

Without a real `fork.json` it falls back to the placeholder addresses in `src/fork.example.json`
and shows a red error banner over the last mock snapshot — that is expected.

## Layout of the code

```
src/protocol.ts     score formula + state machine (mirrors the contracts; no React, no viem)
src/data.ts         types, mock simulation, live viem provider, formatting
src/scenarios.ts    J3 runner: mock scripts / viem test actions against anvil
src/useOracle.ts    React hook over the provider
src/components/*    one file per panel
scripts/parity.mjs  review.md §R1.4 parity vectors
```

## Status

J1–J4 done and **verified end to end on a real mainnet fork** (Sep 19): every button, headless and in
Chrome — results table in [`DASHBOARD.md` §10](DASHBOARD.md). Left: J5 (`docs/PITCH.md`) and J6 (the video).
