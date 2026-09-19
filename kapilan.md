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
- [ ] `sources/ChainlinkSource.sol` (try/catch, clamp check, WAD) · `sources/MockSource.sol` (implements `IMockSource`)
- [ ] `executors/LineExecutor.sol`, `executors/HoleExecutor.sol` (implement `ILineExecutor`/`IHoleExecutor`, `AboveCap`)
- [ ] Tests: ChainlinkSource reads ≈$4,372 on the fork, never reverts; executors change the real Vat line / Dog hole after the Safe `rely`s them
- **Commit:** `feat(sources,executors): ChainlinkSource, MockSource, bounded Line/Hole executors`

### K2. `OracleGuardAggregator` (≈4h) · §2
- [ ] `read()` (fresh filter → weighted median → MAD → band → score with freshest-inlier Wf) + `observations()`, `sourceCount()`, `sourceAt()`
- [ ] Unit + fuzz tests; fork check: real Chainlink + 3 fresh mocks → score ≥ 80
- **Commit:** `feat(aggregator): weighted median, MAD outliers, confidence score 0-100`

### K3. `SmartOSM` (≈4h) · §3
- [ ] Maker OSM ABI + `init`, freshness, quarantine, atomic Spotter poke, `void()` disabled, `price()/status()/age()/lastReading()`
- [ ] Tests incl. Spotter/Clipper working with it as pip on the fork
- **Commit:** `feat(osm): SmartOSM drop-in with freshness, quarantine, zero-price invariant`

### K4. `RiskController` (≈2.5h) · §6
- [ ] GREEN/YELLOW/RED, spaced hysteresis, line via executor, guard via executor
- [ ] **Calendar is optional:** if `calendar == address(0)` treat the market as always open. That removes any dependency on Varun's SessionCalendar
- **Commit:** `feat(controller): GREEN/YELLOW/RED risk controller + liquidation guard`

### K5. `Deploy.s.sol` + `Spell.s.sol` (≈1h) · §7
- [ ] Deploy everything, write `deployments/fork.json` (frozen schema); spell as the Safe; rollback
- **Commit:** `feat(scripts): Deploy and Spell scripts (Safe-impersonated install + rollback)`

### K6. `OracleGuard.t.sol` fork tests (≈2h), the proof
- [ ] S1a/S1b, S2, S3, S4 + repay-always + rollback (mirror `Baseline.t.sol`)
- **Commit:** `test(fork): OracleGuard neutralises S1-S4 on real rwaUSD`

### K7. INTEGRATION CHECKPOINT (≈1h, hour ~20): the only cross-person step
- [ ] `git pull`. Wire Varun's `SessionCalendar` (and `PythSource` if ready) into `Deploy.s.sol` (one address each; if not ready, leave calendar = 0 / keep the mock)
- [ ] Run Varun's `scripts/demo-up.ps1` → `deployments/fork.json` → tell Jeffrey to switch the dashboard to `VITE_MODE=live`
- [ ] Full `forge test` green, sync `PROGRESS.md`
- **Commit:** `chore(integration): wire calendar/pyth, live demo fork`

### K8. Invariants (≈1.5h, only if time) · TESTING §5
- **Commit:** `test(invariant): spot>0, repay never blocked, line<=cap`

## Budget ≈18h. Critical path K1→K6. Cut K8 first if behind.
