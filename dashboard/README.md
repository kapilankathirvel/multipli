# Oracle War Room (`dashboard/`)

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
| 7 | **Event log** | `Init` / `Synced` lines; more appear as scenarios run. |
| 8 | top-right | pill reads **MOCK**. |

### Drive the scenarios (the buttons land in J3 — until then, from the browser console)

In `pnpm dev` a helper is exposed on `window`. Open DevTools (F12) → Console and type:

```js
og('s1')      // stale feed      og('s2')  // market -8%
og('s3')      // compromised     og('s4')  // captured wick
og('poke'); og('sync'); og('warp1h'); og('reset')
```

Each scenario produces:

| Script | Expected |
|---|---|
| `s1` stale feed | warp +25h, publishers stop → all 4 stale → **no quorum**, score **0**, `PokeSkipped NO_QUORUM`, OSM **STALE**, **RED**, borrowing frozen — while **Legacy still says "valid"** at 41.5h old. |
| `s2` market −8% | fast feeds drop, Chainlink lags → Chainlink becomes an **outlier** (✗, Wq 0.71) → **RED** via `live.lo < OSM − 1.5%`. Liquidations stay open. |
| `s3` compromised source | Chainlink ×10 ($43,727) → rejected as an outlier, mid unchanged, score ~70 → **YELLOW**. The legacy panel is the killer moment: it *takes* the ×10 price. |
| `s4` captured wick | all sources −15%, two pokes push the wick into `cur` ($3,716), market recovers to $4,372 → 🛡️ **guard ON** (`Dog.hole = 0`, max 6h) while the state stays GREEN. |
| `poke` / `sync` / `warp1h` | mirror `SmartOSM.poke()` (quorum → jump quarantine → `cur ← nxt`), the controller's `sync(ilk)`, and `evm_increaseTime(3600)`. Two warps without a poke → OSM age > 2h → **STALE → RED**. |

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

1. Run Varun's `scripts/demo-up.sh` (anvil + deploy + spell). That writes `deployments/fork.json`.
2. Copy it into the dashboard's static folder:

```powershell
copy ..\deployments\fork.json public\fork.json
```

3. Start the UI against anvil:

```bash
pnpm dev --mode live      # or put VITE_MODE=live in dashboard/.env (see .env.example)
```

Live mode reads: `aggregator.read()` / `observations()` / `sourceCount()` / `sourceAt(i)`,
`smartOsm.price()/status()/age()`, `controller.status(ilk)`, `vat.ilks(ilk)`, the legacy OSM's
slot 3, and decodes `Poke / PokeSkipped / Quarantined / StateChanged / GuardOn / GuardOff / Synced`.
Ages use **chain** time, so time warps don't break them.

Without a real `fork.json` it falls back to the placeholder addresses in `src/fork.example.json`
and shows a red error banner over the last mock snapshot — that is expected.

## Layout of the code

```
src/protocol.ts     score formula + state machine (mirrors the contracts; no React, no viem)
src/data.ts         types, mock simulation, live viem provider, formatting
src/useOracle.ts    React hook over the provider
src/components/*    one file per panel
scripts/parity.mjs  review.md §R1.4 parity vectors
```

## What's not here yet

J3 scenario buttons (Reset / S1–S4 / Poke / Sync / Warp) and J4's legacy-vs-OracleGuard panel.
The data layer is ready for both: `provider.applyScript('s1')` already drives the mock world.
