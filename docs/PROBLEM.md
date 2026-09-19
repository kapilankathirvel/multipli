# Problem & Threat Model

## Problem statement (verbatim)
> **Rethinking Blockchain Oracles.** Blockchain protocols increasingly depend on external data such as asset prices, interest rates, FX rates, and real-world events. Existing oracle architectures can face issues including latency, manipulation, stale data, data-source failures, and insufficient data availability. Design and prototype a new oracle strategy or significantly improve the reliability, accuracy, or resilience of existing oracle systems. Extend your design to RWAUSD's OSM and adapter contracts, which currently perform the oracle role; propose a better-designed system that mitigates their attack vectors.

## What judges look for
1. A principled answer to the five failure classes (latency, manipulation, staleness, source failure, availability).
2. Evidence we understood the **deployed** OSM + adapter, a concrete threat list, and a **deployable** fix.

## Current pipeline (verified; addresses in `ONCHAIN_FACTS.md`)
```
Chainlink PAXG/USD → PriceFeedAdapter.peek() → OSM.poke()/peek() → Spotter.poke() → Vat.spot
                     (0,false) if >24h          if(ok){…} else nothing   has ? val/par/mat : 0
```
Core flaw: **binary oracle.** It either passes a price or sends zero, and zero liquidates everyone. So the OSM keeps serving stale prices with `has=true` indefinitely.

## Threat model
| # | Vector | Mechanism → impact | Sev | OracleGuard fix |
|---|---|---|---|---|
| V1 | Unbounded stale acceptance | OSM ignores the adapter's `false`; `peek` has no age check; no poke → no update. Max age unbounded | Critical | `age()/status()` → RED |
| V2 | Stale-high over-borrowing | Market falls, spot stays high → mint, walk away → bad debt | High | RED when `live.lo < cur·(1−ε)` |
| V3 | Stale-low unfair liquidation | Price stuck/captured low → healthy vaults barked, auctions start below market | High | Liquidation guard (`hole=0`) |
| V4 | Zero-price trap | `has=false` → `spot=0` → everyone liquidatable → no safe brake | High (design) | Zero-price invariant |
| V5 | Admin key, no timelock | 4/8 Safe can `setPriceFeed`/`change`; the only automated reaction (`OsmMom.stop`) freezes the current price | High (gov) | Multi-source median + quarantine; recommend timelock |
| V6 | Single source | One aggregator, no divergence check | Med-High | 4-source aggregator |
| V7 | Latent clamp | No min/max answer check (bounds ineffective today) | Low | `ChainlinkSource` bound check |
| V8 | Poke-timing cherry-pick | First poker picks the instant captured for 2h | Low-Med | Roadmap: round-TWAP |
| V9 | Public next price | `nxt` readable from storage | Low-Med | Accepted (inherent to delay designs) |
| V10 | Heartbeat/maxDelay mismatch | Captured price already ≈16.5h old; effective age ≈26h before a signal | Medium | Per-source `maxAge` + score freshness |
| V11 | One hop for all RWAs | Equity weekend gaps | Medium | SessionCalendar |
| V12 | Two-step propagation | OSM and Spotter poked separately | Low-Med | Atomic Spotter poke |
| V13 | Reserve/issuer risk | No PoR in pricing | Medium | Roadmap: PoR gate |

## Prior art
- **Multipli docs** describe a v2 oracle (PriceRouter, SignedFeedVerifier, statuses OK/STALE/DISPUTED/HALTED) that is **not deployed**.
- **`aso-sentinel`** (concurrent public work): the same stale bug; signed attestations + `line=0` breaker. One lever, one direction. We also fix the oracle itself, handle stale-low, and grade trust.
