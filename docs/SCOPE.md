# Scope (30-hour build)

**Goal:** one end-to-end demo path. The real rwaUSD contracts on a mainnet fork are exploited, the spell installs OracleGuard, the same attacks fail, and a live dashboard shows it. Everything else is "designed, not built" and goes in the deck.

## Tier 1: MUST (critical path, ≈24h)

| ID | Deliverable | Acceptance criteria |
|---|---|---|
| M1 | Foundry scaffold + fork harness + Maker interfaces | `forge test --match-path test/fork/Harness.t.sol` reads `Vat.ilks("paxg")` at `FORK_BLOCK` and matches `ONCHAIN_FACTS.md` |
| M2 | **Baseline exploits on real contracts** | `Baseline_S1` (legacy OSM keeps `has=true` after 7 days of stale feed and a mint still succeeds), `Baseline_S3` (feed swap → drain up to `line`), `Baseline_S4` (captured wick → healthy vault barked). All pass *as exploits* |
| M3 | `IPriceSource`, `ChainlinkSource`, `MockSource` | Chainlink source returns the real fork price; never reverts (tested with `vm.mockCallRevert`) |
| M4 | `OracleGuardAggregator` | Unit + fuzz tests from CONTRACTS_SPEC §2 pass |
| M5 | `SmartOSM` | Drop-in: `Spotter.poke` works with it as pip; `peek` never `has=false` after init; quarantine + STALE behaviour tested; `void()` reverts |
| M6 | `RiskController` + `LineExecutor` + `HoleExecutor` | RED gives `Vat/ceiling-exceeded` on mint *and* repay succeeds; YELLOW caps mint at the gap; guard gives `Dog/liquidation-limit-hit`; hysteresis tested |
| M7 | `Deploy.s.sol` + `Spell.s.sol` | Spell runs on the fork as the impersonated Safe; rollback works |
| M8 | `OracleGuard_S1..S4` fork tests | Each baseline exploit is neutralised after the spell |
| M9 | Demo orchestration | One command starts anvil fork + deploy + spell and writes `deployments/fork.json` |
| M10 | Dashboard (minimum) | Sources table, score gauge, state badge, line/debt, S1–S4 buttons, event log |
| M11 | README + deck + demo video | See `PITCH.md`, `DEMO_SCRIPT.md` |

## Tier 2: HIGH IMPACT if time allows (≈4h)

| ID | Deliverable | Note |
|---|---|---|
| H1 | `SessionCalendar` + simulated **tslax** ilk + S5 | Create ilk on the fork via the Safe (`vat.init`, `vat.file`, `spotter.file`), deposit via `vat.slip`. **Fallback:** unit test only with the calendar forcing YELLOW |
| H2 | "$ killer moment" output in S3 | Console + UI: "minted $X against $Y collateral" |
| H3 | Invariant tests | `spot > 0`, repay never blocked, `line ≤ cap` |
| H4 | Node keeper loop | Otherwise the dashboard triggers poke/sync directly |
| H5 | Legacy vs OracleGuard side-by-side panel | Two forks, or snapshot/revert |

## Tier 3: DESIGNED ONLY (deck "roadmap" slide)
Verifiable challenge window · round-TWAP poke · real Pyth/RedStone adapters · Clipper `stopped` executor · PoR-gated minting · timelock hardening · mint-rate limiter · Python backtest · CCIP health broadcast · zkTLS NAV for T-bills · native v2 Vat.

## Explicitly OUT
Deploying to a public mainnet/testnet (fork only, optionally a Tenderly VNet) · modifying Multipli core · real governance proposals · tokenomics.

## Cut lines (check at these hours)

| Hour | Must be true | If not |
|---|---|---|
| 6 | M1, M2 (S1 at least), M3 | Drop Baseline_S4 to a unit test; keep going |
| 12 | M4, M5 | Drop H1 (TSLAx) entirely |
| 20 | M6, M7, M8 (S1–S3 minimum) | Drop H4/H5; dashboard = minimal read-only + CLI scenarios |
| 26 | M9, M10 | Freeze features. Record the demo video with CLI fallback |
| 28–30 | M11 | Only polish, deck, video. **No new code** |

## Definition of done (hackathon)
- `forge test` green (fork + unit), including the baseline-exploit tests.
- A fresh clone can follow the README to reach a running demo in < 10 min.
- A 3-minute video exists in case the live demo fails.
