# CLAUDE.md: OracleGuard (Multipli Hackathon 2026)

Read this file first in every session. Then open `PROGRESS.md` to see what's next.

## What we're building (one paragraph)
**OracleGuard** is a graduated-trust oracle layer for Multipli's **rwaUSD** (a Maker-fork CDP stablecoin). Today rwaUSD prices PAXG through Chainlink → `PriceFeedAdapter` → Maker `OSM` → `Spotter` → `Vat`. The OSM **silently ignores staleness** and serves old prices as valid forever. OracleGuard adds:
1. a multi-source **Aggregator + Confidence Score (0–100)**,
2. a drop-in **SmartOSM** (same ABI as the Maker OSM),
3. an **Adaptive Risk Controller** (GREEN/YELLOW/RED + liquidation guard) that acts through bounded executors on `Vat.line` and `Dog.hole`.

It is installed on a **mainnet fork** via one governance "spell" (impersonating the admin Safe). The demo shows exploits succeeding on the real contracts, then failing after the spell.

Hackathon: 30 hours, team of 3 (see below). **Critical path = Kapilan K1→K5 (contracts + fork tests).** Don't gold-plate.

## Team & ownership (3 people)
| Person | File | Owns |
|---|---|---|
| Kapilan (≈50%) | `kapilan.md` | The whole on-chain product: sources, executors, Aggregator, SmartOSM, RiskController, Deploy/Spell, fork tests, invariants, docs, PROGRESS.md |
| Varun (≈25%) | `varun.md` | Independent add-ons: SessionCalendar, PythSource, demo-up scripts (`scripts/`), risk research (`research/`) |
| Jeffrey (≈25%) | `jeffrey.md` | `dashboard/` (mock + live mode, scenario controls), pitch deck (`docs/PITCH.md`), demo video |

**Parallel-by-design:** nobody waits for anybody. Everyone builds against the **frozen interfaces**: `contracts/src/interfaces/IOracleGuard.sol`, `contracts/src/interfaces/IPriceSource.sol`, `abi/*.json`, `deployments/fork.example.json`. The only cross-person step is Kapilan's **integration checkpoint (K7, ~hour 20)**.
**Find out who you're working for** (ask if unclear), read their `<name>.md`, and **only edit files in that person's ownership list.** Never change a frozen interface without telling the whole team (and re-export `abi/`). Tick tasks in the person's own `<name>.md`. Only Kapilan's sessions edit `PROGRESS.md`.

## Doc map
| File | Use it for |
|---|---|
| `PROGRESS.md` | **Task board + session log. Update after every task.** |
| `review.md` | **Mentor review #1 + our answers (score definition, validation, state effects, risk reduction). Binding spec for K2.1/K4/K6b/V4.** |
| `ACTION_ITEMS.md` | **Human follow-ups/reminders. Append new ones at the end of EVERY prompt; tick them off when resolved.** |
| `docs/IMPLEMENTATION_PLAN.md` | Phase-by-phase how-to (files, steps, done-criteria) |
| `docs/SCOPE.md` | What's in/out, cut lines, acceptance criteria |
| `docs/ARCHITECTURE.md` | Components, data flow, state machine, score formula |
| `docs/CONTRACTS_SPEC.md` | **Exact contract APIs to implement** (signatures, storage, events, errors) |
| `docs/ONCHAIN_FACTS.md` | Verified mainnet addresses + parameters (source of truth for constants) |
| `docs/TESTING.md` | Fork setup, test matrix, invariants |
| `docs/DEMO_SCRIPT.md` | Scenario steps S1–S5 and the 3-minute demo flow |
| `docs/TECH_STACK.md` | Tools, versions, setup commands |
| `docs/DECISIONS.md` | Why we chose X over Y (read before "improving" a design choice) |
| `docs/PROBLEM.md` | Threat model V1–V13 |
| `docs/LIMITATIONS.md` | Known trade-offs + prepared answers |
| `docs/PITCH.md` | Deck outline, business model, judge Q&A |
| `docs/ORACLE_DESIGN.md` | Full master report (long; consult when the others aren't enough) |

## Non-negotiable rules (tests enforce these)
1. **Zero-price invariant:** after init, `SmartOSM.peek()` MUST return `has = true` and `val > 0`. Never propagate 0 or a revert into `Spotter.poke()`. (Zero price ⇒ `spot = 0` ⇒ every vault liquidatable.)
2. **Repayments always work.** Controller actions may only restrict *new* debt (`Vat.line`) or *new* liquidations (`Dog.hole`). Never block `frob` with `dart < 0`.
3. **Never change `Spotter.mat`** to express risk: in a Maker fork, `mat` is also the liquidation ratio (see `docs/DECISIONS.md` ADR-001).
4. **Bounded authority:** executors write exactly one parameter, within `[0, cap]`, and only callable by the Controller.
5. **Sources never revert:** every external call in a source adapter is wrapped in `try/catch` and returns `ok = false` on failure.
6. **Drop-in ABI:** `SmartOSM` keeps the Maker OSM external interface (`peek/peep/read/poke/kiss/diss/rely/deny/stop/start/change/step/void/pass/hop/zzz/src/bud/wards`).
7. Don't modify or redeploy Multipli core contracts. Interact with them via interfaces on the fork.

## Key constants (verified on-chain 2026-09-19; see docs/ONCHAIN_FACTS.md)
```
ILK            = "paxg"   (bytes32; NOT "PAXG-A")
VAT            = 0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C
SPOTTER        = 0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2
DOG            = 0x15a36d5cAf263160c2a49DDE6429C045Fb711dDD
CLIPPER_PAXG   = 0x62B7a353928142A18C07026A33F8089d1c7378F4
END            = 0x026782F431bfC233c67128af42a4e9De7f834BF5
LEGACY_OSM     = 0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a
PRICE_ADAPTER  = 0x82F5790Bd1c96790E4c3a3ebC8142bD4D6F8b1CD
CL_PAXG_USD    = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3   (8 decimals)
PAXG           = 0x45804880De22913dAFE09f4980848ECE6EcbAf78
PAXG_JOIN      = 0x3c9567C3b9c20E72858cD5714209EA7D7a8011fD
ADMIN_SAFE     = 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99   (ward on Vat/Spotter/Dog/Clipper/Join/OSM)
FORK_BLOCK     = 26011000  (pin for determinism; bump only deliberately)
mat = 1.40 | line = 1,000,000 | debt ≈ 43,029 | Line = 5,000,000 | hole = 400,000 | chop = 1.05 | buf = 1.10 | dust = 200 | hop = 3600 | adapter maxDelay = 86400
```

## Conventions
- Solidity `0.8.24`, Foundry. Maker core is 0.6.12, so talk to it only through minimal interfaces in `contracts/src/interfaces/`.
- Units follow Maker: WAD = 1e18, RAY = 1e27, RAD = 1e45. Name variables with their unit when ambiguous (`priceWad`, `lineRad`).
- Prices inside OracleGuard are **USD per token in WAD**.
- Custom errors (`error Stale();`) over revert strings in new code. Events on every state change.
- Maker-style `wards/rely/deny` auth on new contracts for consistency.
- Tests: `test/fork/*` (need `ETH_RPC_URL`), `test/unit/*`, `test/invariant/*`. Name baseline exploits `Baseline_S1_*` and fixes `OracleGuard_S1_*`.
- Keep contracts small and readable; judges will read them.

## Workflow for each session
1. Read `PROGRESS.md` → pick the top unchecked task in the current phase.
2. Check `docs/CONTRACTS_SPEC.md` / `docs/SCOPE.md` for its acceptance criteria.
3. Implement → run tests (`forge test`) → tick the box in `PROGRESS.md` + add a session-log line.
4. If a design question comes up, check `docs/DECISIONS.md` first. If you change a decision, add a new ADR.
5. If we're behind the time budget, apply the cut lines in `docs/SCOPE.md`. Don't silently expand scope.
6. **Git: NEVER commit or push.** The user commits manually. After each finished feature, print the exact commands from `docs/GIT_WORKFLOW.md` (run tests → `git add -A` → `git commit -m "<message from the table>"` → `git push`).
7. **End of every prompt:** any follow-up, reminder, "you need to…", or "before submitting…" item you tell the user goes into `ACTION_ITEMS.md` (Open section). Move items to Done (with date + how) once resolved.
