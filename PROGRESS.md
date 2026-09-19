# PROGRESS: OracleGuard

> Living task board. **Update after every task:** tick the box, set the status, add a session-log line.
> Owners: **K** = Kapilan (`kapilan.md`) · **V** = Varun (`varun.md`) · **J** = Jeffrey (`jeffrey.md`). Per-person task lists live in those files; Kapilan syncs them here.
> Mapping: M3–M8, H3 → **K** (kapilan.md K1–K8) · H1 calendar, PythSource, M9 demo-up, risk research → **V** (varun.md V1–V4) · M10 dashboard + scenario controls, H5, deck, video → **J** (jeffrey.md J1–J6). H4 keeper is cut (the dashboard runs scenarios itself; forge test logs are the CLI fallback).
> **Integration checkpoint:** ~hour 20 (kapilan.md K7), the only cross-person step.
> Status legend: ⬜ todo · 🟨 in progress · ✅ done · ⛔ blocked · ✂️ cut

**Hackathon clock:** start `__:__` Sep 19 · hard stop 30h later · current hour: `0`
**Next action:** kapilan.md K3 `SmartOSM`, then K4 RiskController.
**Run tests:** `cd contracts && forge test --match-path "test/fork/*" -vv`

---

## Phase 0: Setup (0.5h)
- ✅ Install Foundry 1.5.1 (native Windows, `%USERPROFILE%/.foundry/bin`), Node 20 present; pnpm deferred to Phase 4 · A
- ✅ Archive RPC: keyless `https://mainnet.gateway.tenderly.co` in `contracts/.env` (publicnode rejects archive reads) · A
- ✅ `git init` + `.gitignore` (no commits yet) · A

## Phase 1: Prove the bug on real contracts (hours 0–6) · A
- ✅ M1 Foundry scaffold, `src/interfaces/IMaker.sol`, `src/Constants.sol` · 1h
- ✅ M1 `Harness.t.sol`: all live params match ONCHAIN_FACTS · 0.5h
- ✅ M2 `Baseline_S1`: after 7 days (Chainlink round 186h old) the legacy OSM still says valid; 31,231 rwaUSD minted against it · 1.5h
- ✅ M2 `Baseline_S3`: feed swap → **$312,319 minted vs $43,724 collateral → $268,595 bad debt** · 1h
- ✅ M2 `Baseline_S4`: −15% wick captured (OSM $3,716 vs true $4,372) → a 145% vault is liquidated · 1h
- ✅ M3 `IPriceSource`, `ChainlinkSource`, `MockSource` + tests (K1) · K

## Phase 2: Core OracleGuard (hours 6–14) · A
- ✅ M4 `OracleGuardAggregator` + unit + fuzz + fork (K2) · K
- ⬜ M5 `SmartOSM` + tests (ABI compat with Spotter, stale, quarantine, void disabled) · 4h

## Phase 3: Controller + spell + fixes (hours 14–20) · A
- ✅ M6 `LineExecutor`, `HoleExecutor` (K1; verified on the real Vat/Dog) · K
- ⬜ M6 `RiskController` + tests (RED/YELLOW/GREEN, guard, hysteresis, repay-always) · 2.5h
- ⬜ M7 `Deploy.s.sol`, `Spell.s.sol` (+ rollback test) · 1h
- ⬜ M8 `OracleGuard_S1..S4` fork tests · 2h

## Phase 4: Demo plumbing + UI (hours 4–26) · B (starts on ABI stubs at hour 4)
- ⬜ M9 `scripts/demo-up.sh`: anvil fork + deploy + spell → `deployments/fork.json` · 1.5h
- ⬜ M10 Dashboard skeleton (Vite + React + viem + Tailwind) · 1h
- ⬜ M10 Panels: sources, gauge, state badge, line/debt, event log · 2.5h
- ⬜ M10 Scenario buttons S1–S4 (mock prices, `evm_increaseTime`, poke, sync) · 1.5h
- ⬜ H4 Keeper loop (optional) · 1h

## Phase 5: High-impact extras (only if the Hour-20 cut line was met)
- ⬜ H2 "$ killer moment" output
- ⬜ H3 Invariant tests
- ⬜ H1 SessionCalendar + tslax ilk + S5
- ⬜ H5 Legacy vs OracleGuard side-by-side

## Phase 6: Ship (hours 26–30) · A+B
- ⬜ README quickstart verified from a fresh clone
- ⬜ Deck (see `docs/PITCH.md`), verify stats cited
- ⬜ Record the 3-min demo video (fallback)
- ⬜ Final `forge test` run; tag the commit

---

## Blockers / risks
| Date/hour | Blocker | Owner | Resolution |
|---|---|---|---|
| | | | |

## Decisions made during build
(Add an ADR in `docs/DECISIONS.md` and link it here.)

## Session log
| When | Who | Did | Next |
|---|---|---|---|
| Sep 19 | Claude | Phase 1 research + verified on-chain facts + full docs set | Phase 0 setup |
| Sep 19 | Claude | **K2 done:** Aggregator (median/MAD/score), 21 tests; demo starts at score 100; 40/40 suite green | K3 SmartOSM |
| Sep 19 | Claude | **K1 done:** ChainlinkSource (fuzz found an overflow revert → guarded), MockSource, Auth, Line/Hole executors; 19/19 tests green | K2 Aggregator |
| Sep 19 | Claude | **Phase 0 + Phase 1 M1/M2 done.** Foundry installed, harness + 3 baseline exploits green on real contracts. Found the Vat getter `dai()` is renamed `rwaUSD()` in this fork | M3 sources → Phase 2 |
| Sep 19 | Claude | Spec review fixes: freshest-inlier score (ADR-009, demo starts GREEN), S3 math corrected (≈$312k per 10 PAXG), legacy `cur` = OSM storage slot 3 (verified), guard sets `hole=0` | Phase 0 → Baseline_S1 (Hour-6 gate) |
