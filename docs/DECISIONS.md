# Architecture Decision Records

Format: context → decision → consequences. **Read this before changing a design choice.** Add a new ADR instead of editing an accepted one.

## ADR-001: Express risk through `Vat.line` / `Dog.hole`, never through `Spotter.mat`
- **Context:** Round 1 said YELLOW raises `mat` to 160–200%. In a Maker fork, `mat` defines `spot = price/mat`, which is used by both `Vat.frob` (borrow check) **and** `Dog.bark` (liquidation check).
- **Decision:** YELLOW/RED restrict *new debt* via the debt ceiling (`line`). The stale-low guard restricts *new liquidations* via `Dog.hole`.
- **Consequences:** raising `mat` 140%→180% would instantly make every vault between 140–180% liquidatable during an oracle incident, which is the opposite of "only new borrowing is restricted". A true separate borrow-CR needs a native v2 Vat (roadmap).

## ADR-002: Demo on an Ethereum mainnet fork, not Arbitrum
- **Context:** Round 1 listed Arbitrum One. rwaUSD's Vat/OSM live on Ethereum.
- **Decision:** fork Ethereum at block 26,011,000 and attack/fix the real contracts. The pitch states portability to L2s (with a sequencer-uptime check).
- **Consequences:** far more convincing; needs a mainnet RPC.

## ADR-003: Mock Pyth/RedStone/DEX sources behind a production interface
- **Context:** attack scenarios need controllable sources. Real pull-oracle integration on a fork is fiddly (fresh signed updates).
- **Decision:** Chainlink is real (the fork's actual feed). The others are `MockSource` implementing `IPriceSource`.
- **Consequences:** say so upfront in the demo. A real `PythSource` is a stretch item.

## ADR-004: Zero-price invariant; `SmartOSM.void()` disabled
- **Context:** `Spotter.poke` sets `spot = 0` when `has=false`, making every vault liquidatable.
- **Decision:** after `init`, `peek()` always returns `(cur, true)`. Staleness is exported via `status()/age()` and acted on through non-price levers. `void()` keeps its ABI but reverts.
- **Consequences:** during total source failure the Vat keeps the last good price, but RED blocks new debt. Global settlement (End) still reads a valid price.

## ADR-005: SmartOSM is a drop-in pip (same ABI as Maker OSM)
- **Decision:** swap via `Spotter.file(ilk,"pip",…)`. Clipper/End keep working because they read the pip through Spotter.
- **Consequences:** one-call rollback; no core changes; must kiss Spotter, Clipper, End.

## ADR-006: Downgrade immediately, upgrade with spaced hysteresis
- **Decision:** a worse state applies at once. Upgrading needs `kUp` healthy syncs at least `upgradeInterval` apart.
- **Consequences:** prevents flapping and same-block "sync spam" upgrades by an attacker.

## ADR-007: RED sets `line = current debt` (not 0)
- **Decision:** pin to current debt. Same effect for new mints; cleaner restore.
- **Consequences:** repay still works (the Vat only checks the ceiling when `dart > 0`).

## ADR-008: Liquidation guard is time-boxed
- **Context:** pausing liquidations for too long creates bad debt.
- **Decision:** the guard needs high agreement (`score ≥ greenScore`) and auto-expires after `guardMaxDuration` (6h default).

## ADR-009: Freshness weight uses the FRESHEST inlier, with a grace band
- **Context:** the Chainlink PAXG/USD round is ≈16.5h old at the fork block (a deviation-triggered feed that is quiet, which is normal). An oldest-age `Wf` gives score ≈34 → RED at t=0 and breaks "one stale source doesn't halt lending".
- **Decision:** `Wf` = 1 while the freshest inlier is ≤ maxAge/2 old, then linear decay. Source dropout is penalised by `Wq`, disagreement by `Wd`.
- **Consequences:** healthy system = GREEN. Total staleness still drives the score to 0.

## ADR-010: No wallet connect in the dashboard MVP
- **Decision:** viem test/public clients against anvil with impersonation. Saves ~2h.
