# Pitch: Deck Outline, Business Model, Q&A

## Deck (8 slides, ≤ 3 min spoken)
1. **Title:** OracleGuard: graduated-trust oracles for rwaUSD. Team names, VIT Vellore.
2. **The flaw (with receipts):** the verified OSM snippet `if (ok) { … }`, "price age: unbounded", the "16.5h-old price captured" fact, and the zero-price trap. One line: *"Trust blindly or self-destruct."*
3. **Threat model:** V1–V13 table (highlight V1, V3, V4, V5).
4. **Live exploit on the real contracts:** S3 numbers ("$X minted against $Y").
5. **OracleGuard architecture:** the 3-layer diagram (same as Round 1) + score formula.
6. **Graduated response:** GREEN/YELLOW/RED + guard table. "Borrow at worst, liquidate at confirmed." "Repayments always work."
7. **Results:** S1–S4 before/after table, gas, "one spell, one-call rollback, no core changes".
8. **Roadmap + business model:** challenge window, PoR gate, CCIP multi-chain; licensing.

## Round 1 → Round 2 story (say it proactively)
"In Round 1 we proposed raising the collateral ratio in YELLOW. Reading the deployed contracts showed that `mat` is also the liquidation threshold, so that would have liquidated users mid-incident. Round 2 restricts only new debt. Our own design review caught that." (It shows rigor.)

## Business model
- **Customers:** RWA lending protocols and Maker-fork CDPs with mixed-hours, mixed-liquidity collateral.
- **Revenue:** integration license **$5K–$25K per protocol** (calibration + spell); per-query fee on the health API (`score()/status()` for integrators); keeper-incentive spread from stability fees (self-sustaining); risk monitoring/alerting SaaS.
- **Impact:** closes the stale-price exploit window. Capital efficiency: keep a 140% base ratio instead of padding a static buffer, tightening only when trust degrades. No single oracle failure halts lending across 100+ RWA assets. Worst-case oracle loss becomes bounded: `MaxLoss ≤ rateCap × detectionTime`.

## Claims to verify before submitting
- "Oracle attacks caused 13% of DeFi exploits in 2025": find a source (e.g. a 2025 exploit report) or soften it.
- "Multipli past $100M TVL": public reports cite ~$340M rwaUSD supply. Use the latest figure with its source.
- Avoid "first ever". Use "first graduated-trust oracle layer that drops into rwaUSD's deployed Maker-fork contracts without core changes."

## One-liners
- "The OSM's delay is a security window nobody acts on. OracleGuard acts on it."
- "Binary oracles have two modes: trust blindly or self-destruct. We added a dial."
- "Borrow at the worst plausible price. Liquidate only at a confirmed one."

Q&A: see `LIMITATIONS.md`.
