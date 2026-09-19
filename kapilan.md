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
- [x] `Wq = Σ w_inliers / Σ w_all` (`nExpected` removed; `quorumMin` stays a count); new `totalWeight()` view
- [x] `AggregatorParityVectorsTest`: all 5 parity vectors (100 / 85 / 71 / 75 / 0) + the contribution table (71 / 57 / 42) match exactly
- [x] `docs/ARCHITECTURE.md` §5 and `docs/CONTRACTS_SPEC.md` §2 updated. ✅ Sep 19
- **Commit:** `feat(aggregator): weight-based confidence (mentor review R1)`

### K3. `SmartOSM` (≈4h) · §3
- [x] Maker OSM ABI + `init`, freshness, quarantine (re-confirm on a later hop), atomic Spotter poke, `void()` disabled, `price()/status()/age()/lastReading()`, `file()` for staleLimit/jumpLimitBps/jumpMinScore
- [x] `test/unit/SmartOSM.t.sol` (16 incl. fuzz "peek always valid, Spotter never sees 0") + `test/fork/SmartOSM.fork.t.sol` (5): **real Spotter/Vat/Dog/Clipper run on SmartOSM unchanged**; swap has no price jump; Vat spot updates atomically; all-stale → Vat spot stays > 0 and status STALE; a real −15% crash still liquidates via the real Clipper. `poke()` ≈247k gas (incl. aggregator + Spotter.poke). ✅ Sep 19
- **Commit:** `feat(osm): SmartOSM drop-in with freshness, quarantine, zero-price invariant`

### K4. `RiskController` (≈2.5h) · §6
- [x] GREEN/YELLOW/RED, spaced hysteresis (one level per kUp syncs ≥ upgradeInterval apart), line via executor, guard via executor
- [x] **Mentor review R3/R4:** GREEN rate-limited headroom (`debt + greenGap`, refill ≤ 1/h); YELLOW anchored on entry and never raised; RED `line = debt`; guard `hole = 0` with 6h expiry + latch
- [x] Calendar optional (`sessionAsset = 0` or no calendar = always open; a reverting calendar → YELLOW)
- [x] `test/unit/RiskController.t.sol` (15): rate limit, cap, YELLOW leak-bound, market closed, RED (stale / market below OSM / quarantine), repay lowers line, spam-proof upgrades, guard on/release/expiry+latch, no guard on a real crash, auth. ✅ Sep 19
- **Commit:** `feat(controller): GREEN/YELLOW/RED risk controller + liquidation guard`

### K5. `Deploy.s.sol` + `Spell.s.sol` (≈1h) · §7
- [x] `script/DeployLib.sol` (shared by scripts AND tests), `Deploy.s.sol` (writes `deployments/fork.json`, frozen schema), `Spell.s.sol` (run as Safe; `--sig "rollback()"`). **Smoke-tested on a live anvil fork:** pip → SmartOSM, GREEN, score 100, line = debt + $250k. ✅ Sep 19
- **Commit:** `feat(scripts): Deploy and Spell scripts (Safe-impersonated install + rollback)`

### K6. `OracleGuard.t.sol` fork tests (≈2h), the proof
- [x] `test/fork/OracleGuard.t.sol` (8): S1a YELLOW (mint capped at $50k), S1b RED (mint reverts, **repay works**, price never 0), S2 RED with liquidations on, S3a legacy feed swap has no effect, S3b compromised source → **$0 bad debt** (vs $268,595), S4 guard blocks unfair liquidation then releases, install + rollback. ✅ Sep 19
- **Commit:** `test(fork): OracleGuard neutralises S1-S4 on real rwaUSD`

### K6b. Mentor review R2: incident replay on the real contracts (≈1.5h)
- [x] `test/replay/Incidents.t.sol`: I1–I8 hourly traces through OracleGuard AND the legacy OSM on the fork; FP/FN/TP per §R2.4 + liquidation-lag + worst-case debt; `REPLAY_TRACE=true` prints the price path
- [x] Results in `review.md` §R2.4b: mint FN 21 → 2 (Mango only, ≤ $250k), liq FN 5 → 1, guard liq FP 0 in real moves, lag 14h → 5h
- [x] **Found and fixed a design flaw:** symmetric quarantine froze the price during real crashes → ADR-011 (asymmetric quarantine, pipeline keeps flowing) + 2 regression unit tests. 101/101 green. ✅ Sep 19
- **Commit:** `test(replay): historical oracle incidents on real rwaUSD (mentor review R2)`

### K7. INTEGRATION CHECKPOINT (≈1h, hour ~20): the only cross-person step
- [ ] `git pull`. Wire Varun's `SessionCalendar` (and `PythSource` if ready) into `Deploy.s.sol` (one address each; if not ready, leave calendar = 0 / keep the mock)
- [ ] Run Varun's `scripts/demo-up.ps1` → `deployments/fork.json` → tell Jeffrey to switch the dashboard to `VITE_MODE=live`
- [ ] Full `forge test` green, sync `PROGRESS.md`
- **Commit:** `chore(integration): wire calendar/pyth, live demo fork`

### K8. Invariants (≈1.5h, only if time) · TESTING §5
- **Commit:** `test(invariant): spot>0, repay never blocked, line<=cap`

## Budget ≈20.5h (incl. mentor review items). Critical path K2.1→K3→K4→K5→K6→K6b. Cut K8 first if behind.
