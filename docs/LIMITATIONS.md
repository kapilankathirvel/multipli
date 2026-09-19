# Limitations & Prepared Answers

## Known limitations
1. **One `spot` per ilk in the Vat.** True separate borrow/liquidation prices need a v2 Vat. We get asymmetric *behaviour* via `line` (borrowing) vs `hole` (liquidations).
2. **Pausing liquidations is risky if prolonged.** The guard needs high agreement and auto-expires (ADR-008).
3. **Oracle independence is imperfect.** Chainlink, Pyth, and RedStone share CEX venues. The median protects against *oracle* failure, not a real *market* dislocation.
4. **RWA DEX liquidity is thin.** The TWAP is low-weight sanity only.
5. **Demo sources are mocked** except Chainlink (ADR-003).
6. **Gas:** `SmartOSM.poke` (~100–150k) costs more than a legacy poke (~40k). Fine at one poke per hour.
7. **Parameters** (ε, score thresholds, gaps, guard duration) are reasoned defaults, not calibrated on historical data.
8. **Governance risk (V5)** needs Multipli to adopt a timelock; code can only recommend it.
9. **During total source failure** the Vat keeps the last good price. New debt is blocked, but existing vaults are valued at that price until sources return (a conscious trade vs the zero-price trap).
10. **Fork ≠ production.** An audit and governance approval are required before any mainnet use.

## Judge Q&A cheat-sheet
- **"Why not just make the OSM invalidate stale prices?"** Invalidation means `has=false`, so `spot=0` and every vault is liquidatable. That's why the deployed system never invalidates. Graduated trust is the fix.
- **"Why not raise the collateral ratio when risk rises?"** In Maker, `mat` is also the liquidation ratio, so it would liquidate users mid-incident. We restrict new debt instead (ADR-001).
- **"Your other oracles are mocked."** Yes, deliberately, for attack injection behind the production interface. The Chainlink feed is the real mainnet one on the fork.
- **"How is this different from Chainlink/Maker's own approach?"** Those are binary (valid/invalid, open/shut). We grade trust (0–100) and respond proportionally and asymmetrically.
- **"What if an attacker spams `sync()`?"** Downgrades are safe to spam. Upgrades need spaced healthy syncs (ADR-006).
- **"What if all sources are manipulated?"** Then it's a market-level attack. The jump quarantine + (roadmap) challenge window + mint-rate cap bound the damage: `MaxLoss ≤ rateCap × detectionTime`.
- **"Isn't pausing liquidations dangerous?"** It's time-boxed, needs high agreement, and only triggers when the live market is *above* the delayed price, i.e. the vaults are safer than the OSM thinks.
- **"Can it run on Base/Ink/Monad?"** Yes, it's chain-agnostic. On L2s add the sequencer-uptime check. Health can be broadcast via CCIP (roadmap).
- **"Who pays keepers?"** A bounty from a slice of stability fees (business model).
- **"What about the admin Safe?"** Our finding V5: no timelock on oracle config. We recommend Safe → 48h timelock plus a tighten-only guardian.
