# Implementation Plan: phase by phase

Companion to `PROGRESS.md` (checkboxes) and `docs/CONTRACTS_SPEC.md` (APIs). This file describes **how** each phase is built, which files it touches, and what "done" means.
Budget: 30h. Critical path: Phases 1–3 (contracts + fork tests).

---

## Phase 0: Setup (0.5h)
**Goal:** a toolchain that compiles and forks.
- Foundry (forge/anvil/cast): native Windows binaries in `%USERPROFILE%\.foundry\bin`.
- Node 20 (installed). pnpm via `npm i -g pnpm` (Phase 4 only).
- `git init` at the repo root. `.gitignore`: `.env`, `contracts/out`, `contracts/cache`, `broadcast/`, `node_modules/`.
- RPC: `contracts/.env` → `ETH_RPC_URL` (Alchemy/Infura, publicnode as fallback), `FORK_BLOCK=26011000`.

**Done when:** `forge --version` works and `forge build` compiles an empty project.

---

## Phase 1: Prove the bug on the real contracts (hours 0–6) ← **Hour-6 gate**
**Goal:** exploits pass *as exploits* against unmodified rwaUSD on a pinned mainnet fork.

**Files**
```
contracts/foundry.toml
contracts/.env.example
contracts/src/interfaces/{IVat,ISpotter,IDog,IPip,IGemJoin,IChainlinkFeed,IPriceSourceLike}.sol
contracts/src/Constants.sol            // addresses + ILK from ONCHAIN_FACTS
contracts/test/fork/ForkBase.sol       // fork setUp + helpers
contracts/test/fork/Harness.t.sol      // asserts live params
contracts/test/fork/Baseline.t.sol     // S1, S3, S4 exploits
contracts/test/mocks/EvilFeed.sol      // Chainlink-shaped feed returning an attacker price
```

**Steps**
1. `foundry.toml`: solc 0.8.24, `evm_version = "cancun"`, `rpc_endpoints.mainnet`, fuzz/invariant runs.
2. Interfaces exactly per CONTRACTS_SPEC §0. `Constants.sol` with checksummed addresses.
3. `ForkBase`:
   - `setUp`: `vm.createSelectFork(ETH_RPC_URL, FORK_BLOCK)`.
   - helpers `legacyCur()` (via `vm.load` slot 3), `pokeLegacy()` (warp to `zzz+hop`, `osm.poke`, `spotter.poke`), `openVault(who, paxg, daiWad)` (`deal` → join → frob), `ilkDebtRad()`, `priceWad()`.
4. `Harness.t.sol`: `mat == 1.4 RAY`, `line == 1_000_000 RAD`, pip == legacy OSM, Safe is a ward, legacy cur ≈ 4372e18.
5. `Baseline.t.sol`:
   - **S1 (stale forever):** open a vault. Warp 7 days; the Chainlink round is now >24h old, so `adapter.peek()` is `(0,false)`. `osm.poke()` succeeds but changes nothing. Legacy `peek` is still `has=true`; `spotter.poke` keeps the same spot; the attacker frobs more debt successfully. Log the price age.
   - **S3 (compromised feed):** the Safe calls `adapter.setPriceFeed(EvilFeed @ 10×)`. `pokeLegacy()` twice, so the price is 10× in `cur`. The attacker deposits 10 PAXG and mints max `ink*spot/rate`. Log "minted $X vs real collateral $Y".
   - **S4 (captured wick, stale-low):** a victim vault sits at ≈145% CR. `vm.mockCall` Chainlink at −15% (fresh timestamp) → `pokeLegacy` ×2 → cur is low → `vm.clearMockedCalls` (market recovered). `dog.bark(victim)` succeeds, liquidating a vault that is healthy at the true price.

**Done when:** `forge test --match-contract Baseline -vv` is green with readable logs.
**Risks:** PAXG `deal` + GemJoin quirks, so fall back to `vat.slip` as the Safe. Public RPC rate limits, so use an Alchemy key.

---

## Phase 2: Sources, Aggregator, SmartOSM (hours 6–14)
**Files:** `src/sources/{ChainlinkSource,MockSource}.sol`, `src/OracleGuardAggregator.sol`, `src/SmartOSM.sol`, `test/unit/{Aggregator,SmartOSM,Sources}.t.sol`.
**Steps**
1. `IPriceSource` + `Observation`. ChainlinkSource with `try/catch` + clamp check. MockSource with auth setters.
2. Aggregator: in-memory insertion sort (≤5), weighted median, MAD filter, band, score (freshest-inlier `Wf` with grace band, ADR-009).
3. SmartOSM: copy the Maker OSM ABI, then add `init`, freshness, quarantine, atomic `spotter.poke` in `try/catch`, and `void()` reverting.
4. Tests per CONTRACTS_SPEC §2/§3 + fuzz.

**Done when:** unit + fuzz green; at `FORK_BLOCK` with the real Chainlink + 3 fresh mocks the score is ≥ 80.
**Cut line (hour 12):** if not done, drop SessionCalendar/TSLAx (H1).

---

## Phase 3: Controller, executors, spell, fixes (hours 14–20)
**Files:** `src/executors/{LineExecutor,HoleExecutor}.sol`, `src/RiskController.sol`, `src/SessionCalendar.sol` (thin; PAXG alwaysOpen), `script/{Deploy,Spell}.s.sol`, `test/fork/OracleGuard.t.sol`, `test/unit/RiskController.t.sol`.
**Steps**
1. Executors: `cap` + one-param write, `AboveCap` error.
2. RiskController.sync: target state → hysteresis → line apply → guard (`hole=0`, expiry).
3. `Deploy.s.sol`: deploy everything, write `deployments/fork.json`. `Spell.s.sol`: run as the Safe; legacy price from `LEGACY_PRICE` env / `vm.load`.
4. `OracleGuard.t.sol`: in `setUp`, apply the spell in-test (prank the Safe); S1a/S1b, S2, S3, S4 mirror the baselines with the opposite expectations; repay-always test; rollback test.

**Done when:** `forge test` is fully green (baseline + OracleGuard).
**Cut line (hour 20):** if S1–S3 aren't green, drop the keeper and the side-by-side panel.

---

## Phase 4: Demo plumbing + dashboard (hours 4–26, person B in parallel)
**Files:** `scripts/demo-up.sh`, `keeper/src/{scenarios,keeper}.ts`, `dashboard/*`.
**Steps**
1. `demo-up.sh`: start anvil fork (`--fork-block-number 26011000 --auto-impersonate`), deploy, fund the Safe, spell, snapshot, write `deployments/fork.json`.
2. `keeper/scenarios.ts` (viem test client): `s1()..s4()` using `evm_increaseTime`, `evm_mine`, mock setters, `poke`, `sync`, `evm_snapshot/revert`.
3. Dashboard (Vite + React + viem + Tailwind + Recharts): polling reader (2s) + panels (sources, gauge, state, line/debt, events) + scenario buttons calling the same functions as keeper/scenarios.
4. B starts from ABI stubs at hour 4. Wire real ABIs from `contracts/out` once Phase 3 lands.

**Done when:** one command brings up the fork, and S1–S4 can be clicked with the state changing live.

---

## Phase 5: High-impact extras (only if the Hour-20 gate was met)
H2 $ killer-moment output (formatted logs + UI banner) · H3 invariants (`test/invariant/`) · H1 SessionCalendar + `tslax` ilk created on the fork by the Safe + S5 · H5 legacy vs OracleGuard side-by-side (snapshot/revert).

---

## Phase 6: Ship (hours 26–30), no new features
README quickstart tested from a fresh clone · deck from `docs/PITCH.md` (after clearing `ACTION_ITEMS.md` pitch items) · 3-min video (fallback) · final `forge test` · tag the commit.
