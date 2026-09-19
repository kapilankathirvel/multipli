# kapilan.md: Kapilan's tasks (≈50%: the entire on-chain product)

> **Role:** you own **everything on the on-chain critical path**: sources, executors, aggregator, SmartOSM, controller, scripts, fork tests. **You depend on nobody.** Teammates build against the frozen interfaces; you plug their extras in at one planned integration step (K7).
> **Start every Claude session with:** "Read CLAUDE.md, kapilan.md and docs/CONTRACTS_SPEC.md, then do the next unchecked task in kapilan.md."
> Tick boxes here. You also own `PROGRESS.md` (sync teammates' boxes into it at each checkpoint).

## Frozen interfaces you MUST implement exactly (the team depends on them)
- `contracts/src/interfaces/IOracleGuard.sol`: `IOracleGuardAggregator`, `ISmartOSM`, `IRiskController`, `IMockSource` (+ events). **Inherit them** (`contract SmartOSM is ISmartOSM`) so the compiler enforces it.
- `contracts/src/interfaces/IPriceSource.sol`: `IPriceSource`, `ILineExecutor`, `IHoleExecutor`, `ISessionCalendar`
- `deployments/fork.example.json`: `Deploy.s.sol` must write `deployments/fork.json` in this exact shape
- `abi/*.json`: exported from the interfaces. If you ever change an interface, re-export (`forge inspect <I> abi --json > abi/<I>.json`) and tell the team
- Script names/env the demo script relies on: `script/Deploy.s.sol`, `script/Spell.s.sol`, env `ETH_RPC_URL`, `FORK_BLOCK`, `LEGACY_PRICE` (optional)

## Ownership (only you edit these)
```
contracts/src/**            (except src/SessionCalendar.sol and src/sources/PythSource.sol, which are Varun's)
contracts/script/**
contracts/test/**           (except test/unit/{SessionCalendar,PythSource}.t.sol, which are Varun's)
abi/**  deployments/**  PROGRESS.md  CLAUDE.md  docs/* (except docs/PITCH.md = Jeffrey, research/ = Varun)
```

## Done (Phase 1)
- [x] Scaffold, `IMaker.sol`, `Constants.sol`, fork harness, baseline exploits S1/S3/S4
- [x] Frozen team interfaces: `IOracleGuard.sol`, `IPriceSource.sol`, `abi/`, `deployments/fork.example.json`

## Tasks (in order, no external dependencies)

### K1. Sources + executors (≈2h) · CONTRACTS_SPEC §1, §4
- [x] `sources/ChainlinkSource.sol` (try/catch, clamp check, overflow guard, WAD) · `sources/MockSource.sol` (implements `IMockSource`) · shared `utils/Auth.sol`
- [x] `executors/LineExecutor.sol`, `executors/HoleExecutor.sol` (implement `ILineExecutor`/`IHoleExecutor`, `AboveCap`)
- [x] Tests: `test/unit/Sources.t.sol` (10 incl. fuzz never-reverts) + `test/fork/SourcesExecutors.t.sol` (5: real feed $4,372; real Vat line freeze → `Vat/ceiling-exceeded`; real Dog hole=0; caps; auth). ✅ Sep 19
- **Commit:** `feat(sources,executors): ChainlinkSource, MockSource, bounded Line/Hole executors`

### K2. `OracleGuardAggregator` (≈4h) · §2
- [x] `read()` (fresh filter → weighted median → MAD → band → score with freshest-inlier Wf) + `observations()`, `sourceCount()`, `sourceAt()`; `MAX_PRICE` sanity bound; split into helpers (stack-too-deep, no via-ir)
- [x] `test/unit/Aggregator.t.sol` (17 incl. fuzz) + `test/fork/Aggregator.fork.t.sol` (4): **score 100 at fork block**, S1a Chainlink 7d stale → 75, S2 −8% → mid follows market ($4,022), `read()` ≈105k gas. ✅ Sep 19
- Demo weights: Chainlink 2 (maxAge 25h), Pyth 2, RedStone 2, DEX 1 (maxAge 1h)
- **Commit:** `feat(aggregator): weighted median, MAD outliers, confidence score 0-100`

### K2.1. Mentor review R1: weight-based confidence (≈0.5h) · see `review.md` §R1
- [ ] `Wq = min(1, Σ w_inliers / Σ w_all)` (replace the count-based `nExpected`; keep `quorumMin` as a count)
- [ ] Unit tests reproduce the **parity vectors in review.md §R1.4** exactly (100 / 85 / 71 / 75 / 0); update the existing tests' expected scores
- [ ] Update `docs/ARCHITECTURE.md` §5 and `docs/CONTRACTS_SPEC.md` §2 to the weight-based formula
- **Commit:** `feat(aggregator): weight-based confidence (mentor review R1)`

### K3. `SmartOSM` (≈4h) · §3
- [ ] Maker OSM ABI + `init`, freshness, quarantine, atomic Spotter poke, `void()` disabled, `price()/status()/age()/lastReading()`
- [ ] Tests incl. Spotter/Clipper working with it as pip on the fork
- **Commit:** `feat(osm): SmartOSM drop-in with freshness, quarantine, zero-price invariant`

### K4. `RiskController` (≈2.5h) · §6
- [ ] GREEN/YELLOW/RED, spaced hysteresis, line via executor, guard via executor
- [ ] **Mentor review R3/R4:** GREEN line = `min(debt + greenGap, lineCap)`, refilled at most once per `refillInterval` (1h), i.e. a **rate limit** so `MaxLoss ≤ greenGap × hours` even for undetected correlated failures. Exact state table: `review.md` §R3
- [ ] **Calendar is optional:** if `calendar == address(0)` treat the market as always open. That removes any dependency on Varun's SessionCalendar
- **Commit:** `feat(controller): GREEN/YELLOW/RED risk controller + liquidation guard`

### K5. `Deploy.s.sol` + `Spell.s.sol` (≈1h) · §7
- [ ] Deploy everything, write `deployments/fork.json` (frozen schema); spell as the Safe; rollback
- **Commit:** `feat(scripts): Deploy and Spell scripts (Safe-impersonated install + rollback)`

### K6. `OracleGuard.t.sol` fork tests (≈2h), the proof
- [ ] S1a/S1b, S2, S3, S4 + repay-always + rollback (mirror `Baseline.t.sol`)
- **Commit:** `test(fork): OracleGuard neutralises S1-S4 on real rwaUSD`

### K6b. Mentor review R2: incident replay on the real contracts (≈1.5h)
- [ ] `test/replay/Incidents.t.sol`: compressed inline traces (5–10 steps each) for I1–I8 from `review.md` §R2.3, fed through MockSources → SmartOSM → RiskController on the fork
- [ ] At each step, log truth vs mid, state, guard, and mint/liquidation outcome; classify TP/FP/FN/TN with the §R2.4 definitions; print a summary table
- [ ] Assertions: I1–I4 no FN; I7/I8 liquidations never blocked; I6 loss ≤ greenGap per hour (bounded, not detected)
- **Commit:** `test(replay): historical oracle incidents on real rwaUSD (mentor review R2)`

### K7. INTEGRATION CHECKPOINT (≈1h, hour ~20): the only cross-person step
- [ ] `git pull`. Wire Varun's `SessionCalendar` (and `PythSource` if ready) into `Deploy.s.sol` (one address each; if not ready, leave calendar = 0 / keep the mock)
- [ ] Run Varun's `scripts/demo-up.ps1` → `deployments/fork.json` → tell Jeffrey to switch the dashboard to `VITE_MODE=live`
- [ ] Full `forge test` green, sync `PROGRESS.md`
- **Commit:** `chore(integration): wire calendar/pyth, live demo fork`

### K8. Invariants (≈1.5h, only if time) · TESTING §5
- **Commit:** `test(invariant): spot>0, repay never blocked, line<=cap`

## Budget ≈20.5h (incl. mentor review items). Critical path K2.1→K3→K4→K5→K6→K6b. Cut K8 first if behind.
