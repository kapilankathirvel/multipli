# jeffrey.md: Jeffrey's tasks (≈25%: dashboard + deck + video)

> **Role:** everything the judges *see*. **You never wait for contracts:** you build against the frozen ABIs in `abi/` with a mock data mode, and switch to live at the integration checkpoint (~hour 20).
> **Start every Claude/Cursor session with:** "Read CLAUDE.md, jeffrey.md, docs/ARCHITECTURE.md §7 and docs/DEMO_SCRIPT.md, then do the next unchecked task in jeffrey.md. Only edit files in Jeffrey's ownership list."
> Tick boxes here as you go.

## Setup (≈15 min)
- [ ] `git clone https://github.com/kapilankathirvel/multipli.git && cd multipli`
- [ ] Node 20 + `npm i -g pnpm`. (Foundry is only needed for the final live demo; see varun.md Setup)

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

### J1. Scaffold + mock mode (≈1h)
- [ ] `pnpm create vite dashboard --template react-ts`; add `viem recharts` + Tailwind
- [ ] `src/data.ts`: one interface, two implementations: `mock` (animated fake data, scenario-scriptable) and `live` (viem `createPublicClient`, polling every 2s). Switch with `VITE_MODE=mock|live`
- **Commit:** `feat(dashboard): scaffold with mock/live data layer`

UI data shapes:
```ts
type Source   = { name: string; price: number; ageSec: number; fresh: boolean; inlier: boolean };
type Reading  = { mid: number; lo: number; hi: number; score: number; nInliers: number; ok: boolean };
type OsmState = { cur: number; nxt: number; ageSec: number; status: "UNINIT"|"LIVE"|"STALE"|"QUARANTINED"|"STOPPED" };
type Risk     = { state: "GREEN"|"YELLOW"|"RED"; guard: boolean; lineUsd: number; debtUsd: number };
type Legacy   = { price: number; valid: boolean; ageHours: number };
```

### J2. Panels (≈3h)
- [ ] Sources table (fresh/stale + inlier/outlier pills) · Confidence gauge 0–100 with GREEN/YELLOW/RED bands + lo–mid–hi band
- [ ] Big state badge + 🛡️ liquidation-guard flag · Vat panel (debt vs line headroom; "new borrowing: open / limited / frozen")
- [ ] Event log (decoded events)
- **Commit:** `feat(dashboard): Oracle War Room panels`

### J3. Scenario controls (≈1.5h), your own code, no keeper needed
- [ ] `src/scenarios.ts` using viem **test actions** against anvil (`increaseTime`, `mine`, `snapshot`, `revert`, `impersonateAccount`) + `IMockSource.setPrice/setOk` + `smartOsm.poke()` + `controller.sync(ilk)`
- [ ] Buttons: Reset (revert to `snapshotId`) · S1 stale feed (warp 25h, set mocks stale) · S2 market −8% (mocks −8%) · S3 compromised source (one mock ×10) · S4 captured wick (all −15% → poke → recover) · Poke · Sync · Warp +1h. Exact steps: `docs/DEMO_SCRIPT.md` §B
- [ ] In mock mode the buttons drive the fake data, so you can build and style it all now
- **Commit:** `feat(dashboard): scenario controls`

### J4. Legacy vs OracleGuard panel (≈1h)
- [ ] Side-by-side: Legacy OSM (price, "VALID" even when stale, age) vs OracleGuard (score, state)
- [ ] S3 killer-moment banner: **"Legacy: 10 PAXG ($43,724) minted $312,319 → $268,595 bad debt"** vs "OracleGuard: blocked"
- **Commit:** `feat(dashboard): legacy vs OracleGuard comparison + S3 banner`

### J5. Pitch deck (≈1.5h) · `docs/PITCH.md`
- [ ] Fix the 3 claims first (`ACTION_ITEMS.md` → Pitch): cite or soften "13%", drop "first ever", TVL ≈$340M rwaUSD supply with a source
- [ ] 8 slides per `docs/PITCH.md`; diagram from `docs/ARCHITECTURE.md`; numbers from `docs/DEMO_SCRIPT.md` §D; risk charts from Varun's `research/out/` when available (placeholder until then)
- **Commit:** `docs(pitch): final deck + fixed claims`

### J6. Go live + video (≈1h, after the integration checkpoint)
- [ ] `VITE_MODE=live` against Kapilan's running fork → click through S1–S4 → record the 3-min video (`docs/DEMO_SCRIPT.md` §A); link it in README + deck
- **Commit:** `docs: demo video link`

## Budget ≈8h.
