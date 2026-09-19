# Oracle War Room (`dashboard/`)

> **Full guide:** [`DASHBOARD.md`](DASHBOARD.md) — every panel, every button, why it exists, and the end-to-end run on a real mainnet fork.

React 19 + Vite + viem + Tailwind. Two modes:

- **Mainnet data (default):** real Chainlink / Pyth / RedStone / Uniswap-TWAP prices, the real
  rwaUSD `Vat`, `Spotter` and legacy OSM, read from Ethereum mainnet every 6s. OracleGuard isn't
  deployed on mainnet, so its logic (`src/protocol.ts`) runs in the page on top of those real inputs.
  Needs internet, no local chain.
- **Local fork:** an anvil fork with OracleGuard deployed + installed by the spell, polled every 2s.

## 1. Run it

```bash
cd dashboard
pnpm install
pnpm dev          # mainnet data -> http://localhost:5173
```

Top to bottom: scenario buttons (hover one to see what it does), status card (state, score, why,
guard, the price vaults are valued at), confidence score as a sum of points, price sources, borrowing
(debt / ceiling / room), legacy OSM vs OracleGuard, and a collapsed event log. Every panel is
explained in [`DASHBOARD.md` §4](DASHBOARD.md).

**Score:** `score = ⌊50·Wq + 30·Wd + 20·Wf⌋ − volatility penalty` (0 without quorum).
GREEN ≥ 80 · YELLOW 40–79 · RED < 40.

### Scenarios (both modes)

| Button | What happens |
|---|---|
| S1 stale feed | publishers stop, +26h → every source stale → no quorum → score 0, OSM STALE, **RED**; legacy still "VALID" (S1 banner) |
| S2 market −8% | fast feeds −8%, Chainlink lags → Chainlink is an outlier → **RED** via `live.lo < OSM − 1.5%`; liquidations stay open |
| S3 compromised | Chainlink ×10 → rejected as an outlier, price unchanged; legacy takes the ×10 price (S3 banner) |
| S4 captured wick | every feed −15% for two hops → the dip becomes `cur`, market recovers → 🛡️ guard ON (`Dog.hole = 0`) |
| Poke | `SmartOSM.poke()`: waits for the hourly hop, `nxt` → `cur`, the new median becomes `nxt` |
| Sync | `RiskController.sync(paxg)`: re-evaluates the state, sets the debt ceiling and the guard |
| Warp +1h | moves the clock one hour, then poke + sync |
| Reset | mainnet: clears every fault · fork: `evm_revert` to the snapshot taken on page load |

`og('s3')` etc. also work from the DevTools console.

## 2. Checks you can run

```bash
pnpm check:parity   # review.md §R1.4 vectors with the additive score: 100, 92, 85, 92, 70 + V-e quarantined
pnpm build          # tsc -b + vite build, must be clean
pnpm lint
```

The deployed `OracleGuardAggregator.sol` still multiplies (`100·Wq·Wd·Wf`) until it is ported;
`parity.mjs` prints both numbers per vector.

## 3. Fork mode

1. Bring up the fork and install OracleGuard — exact commands in [`DASHBOARD.md` §7.2](DASHBOARD.md) (anvil → `Deploy.s.sol --slow` → `Spell.s.sol --slow`), or Varun's `scripts/demo-up` once it lands. That writes `deployments/fork.json`.
2. Copy it into the dashboard's static folder:

```powershell
copy ..\deployments\fork.json public\fork.json
```

3. Start the UI against anvil:

```bash
pnpm dev --mode live      # VITE_MODE=fork; use the URL Vite prints (moves to :5174 if :5173 is busy)
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
and shows a red error banner — that is expected.

## Layout of the code

```
src/protocol.ts     additive score + state machine (no React, no viem)
src/mainnet.ts      real mainnet reads (feeds, Vat, Spotter, legacy OSM)
src/data.ts         types, mainnet provider (real inputs + modelled OracleGuard), fork provider, formatting
src/scenarios.ts    button runner: faults on the mainnet world / viem test actions against anvil
src/useOracle.ts    React hook over the provider
src/components/*    one file per panel
scripts/parity.mjs  review.md §R1.4 vectors (additive score)
```

## Status

J1–J4 done and **verified end to end on a real mainnet fork** (Sep 19): every button, headless and in
Chrome — results table in [`DASHBOARD.md` §10](DASHBOARD.md). Left: J5 (`docs/PITCH.md`) and J6 (the video).
