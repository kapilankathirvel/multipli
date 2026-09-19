# Demo Script

## A. The 3-minute live demo

| Time | Show | Say |
|---|---|---|
| 0:00–0:20 | Title + the pipeline diagram | "rwaUSD prices collateral through Chainlink → an adapter → Maker's OSM → the Vat. We read every contract on mainnet." |
| 0:20–0:50 | Code snippet `if (ok) { … }` from the real OSM + the "16.5h-old price" fact | "When the feed goes stale, the OSM silently keeps the old price as valid **forever**, and its only brake, `void`, sets the price to zero and liquidates everyone. So nobody uses it." |
| 0:50–1:25 | **Baseline S3 on the real contracts (fork)** | "Here's the live protocol, forked. A compromised feed, two hops later: 10 PAXG worth $43.7k mints **≈$312k** of rwaUSD." (killer moment; use the numbers printed by the test) |
| 1:25–1:45 | Run the spell | "One governance transaction installs OracleGuard. Same ABI, no core changes, one-call rollback." |
| 1:45–2:30 | Dashboard: S3 again (outlier rejected), S1 (stale → YELLOW/RED, repay still works), S4 (liquidation guard) | "Graduated trust. One bad source is ignored. Stale data restricts only new borrowing, and a stale-*low* price can't liquidate healthy users." |
| 2:30–2:50 | Score formula + state table | "A confidence score from 4 networks drives GREEN/YELLOW/RED on levers Maker already has. We never touch the liquidation ratio, because in Maker that would liquidate users." |
| 2:50–3:00 | Roadmap + business model line | "Next: verifiable challenge window, PoR-gated minting, multi-chain. License model for RWA lenders." |

## B. Scenario runbook (dashboard buttons ↔ scripts)

Common prep: `scripts/demo-up.sh` (anvil fork + deploy + spell, writes `deployments/fork.json`). Take an `evm_snapshot` after setup and **revert to it before each scenario**.

### S1: Stale feed
1. `evm_increaseTime 7 days`, mine. Keep mocks fresh (S1a) *or* stale them too (S1b).
2. Legacy view: `LEGACY_OSM.peek()` (as Spotter) → `has=true`, age 7d.
3. `SmartOSM.poke()` → S1a: accepted, score ≈64; S1b: `PokeSkipped`, status STALE.
4. `controller.sync("paxg")` → S1a YELLOW / S1b RED.
5. Attacker `frob(+dart)` → S1b reverts `Vat/ceiling-exceeded`. Victim `frob(-dart)` → succeeds.

### S2: Market drop while OSM lags
1. Mocks `setPrice(p·0.92)`. Chainlink unchanged.
2. `sync` → RED (live.lo < cur·(1−1.5%)). Mint reverts, and liquidations stay enabled.

### S3: Feed compromise / manipulation (killer moment)
- **Baseline (legacy fork snapshot):** impersonate Safe → `adapter.setPriceFeed(EvilFeed 10×)` → warp hop → `osm.poke()` ×2 → `spotter.poke` → attacker deposits 10 PAXG (real value ≈$43.7k). With spot inflated 10×, the per-urn check allows `10 × 43,725 / 1.4` ≈ **$312k minted against $43.7k of real gold (7.1× over-mint, ≈$268k bad debt)**. To exhaust the whole remaining ceiling (≈$957k), the attacker needs only ≈31 PAXG (≈$135k). **Compute both numbers in the test from live `spot`/`mat` and print them. Don't hardcode.**
- **OracleGuard:** same compromise (the ChainlinkSource reads the evil feed) → aggregator marks it an outlier → median unchanged → `SmartOSM` promotes the honest median → mint beyond the true collateral value fails `Vat/not-safe`.

### S4: Captured wick / stale-low
1. Prepare a vault at ≈145% CR.
2. All sources −15% → `poke` (captured into `nxt`) → warp hop → `poke` → cur low.
3. Mocks recover to +0%. `sync` → guard ON (`hole = 0`).
4. Keeper `dog.bark(...)` → reverts `Dog/liquidation-limit-hit`. Baseline: bark succeeds and a healthy vault is liquidated.
5. Warp past `guardMaxDuration` or let sources converge → guard OFF.

### S5 (if H1 built): Weekend gap on simulated TSLAx
Friday 21:00 UTC → closed → YELLOW (headroom = gap budget). Monday open with a −12% gap → RED until kUp healthy syncs. Liquidations run.

## C. Fallbacks
1. Dashboard broken → run `forge test --match-contract Scenario -vv` with readable `console.log` output.
2. Fork RPC down → pre-recorded video (record it at hour ~27).
3. Anvil state lost → `scripts/demo-up.sh` is idempotent and takes < 1 min.

## D. Prepared numbers (fill in from test output)
- S3 drain: **$312,319** minted vs **$43,724** collateral → **$268,595 bad debt** (10 PAXG, from `Baseline_S3`)
- S1: legacy price age at mint **186 h** (Chainlink round), OSM still `has=true` at $4,372; 31,231 rwaUSD minted
- S4: OSM served **$3,716** while the true price was **$4,372** → a 145% vault was liquidated
- Gas: `SmartOSM.poke` `______` vs legacy `≈40k`
