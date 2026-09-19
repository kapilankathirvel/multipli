# OracleGuard

**Graduated-trust oracle layer for Multipli's rwaUSD.** Multipli Hackathon 2026 · "Rethinking Blockchain Oracles"
Team: R Varun · Kapilan · Jeffrey Winson (VIT Vellore)

## The problem
rwaUSD prices PAXG collateral through Chainlink → `PriceFeedAdapter` → Maker `OSM` → `Spotter` → `Vat`. When the feed goes stale, the OSM **silently keeps serving the old price as valid, with no time limit**. Its only emergency brake (`void`) sets the price to zero, which makes every vault liquidatable. The oracle is binary: *trust blindly or self-destruct.*

## The solution
1. **Multi-Oracle Aggregation + Confidence Score (0–100):** Chainlink, Pyth, RedStone, and a DEX TWAP combined with a weighted median and outlier rejection.
2. **SmartOSM:** a drop-in replacement for the Maker OSM that tracks freshness, quarantines suspicious jumps, and never feeds a zero price into the Vat.
3. **Adaptive Risk Controller:** GREEN / YELLOW / RED plus a liquidation guard, acting through bounded executors on the debt ceiling and liquidation limit. **Repayments always work; only new borrowing is restricted.**

It installs on the live protocol through **one governance spell** with no core changes and a one-call rollback.

## Repo
```
contracts/   Foundry: sources, aggregator, SmartOSM, controller, executors, fork tests
keeper/      Node + viem: poke/sync loop and scenario runner
dashboard/   React + Vite: the Oracle War Room
docs/        design, architecture, specs, scope, testing, demo, pitch
```

## Quickstart
```bash
cp contracts/.env.example contracts/.env        # set ETH_RPC_URL
cd contracts && forge test -vv                   # baseline exploits + OracleGuard fixes on a mainnet fork
../scripts/demo-up.sh                            # anvil fork + deploy + spell → deployments/fork.json
cd ../dashboard && pnpm i && pnpm dev            # open http://localhost:5173
```
(Setup details: `docs/TECH_STACK.md`.)

## Docs
- Design report: [`docs/ORACLE_DESIGN.md`](docs/ORACLE_DESIGN.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · Contract spec: [`docs/CONTRACTS_SPEC.md`](docs/CONTRACTS_SPEC.md)
- Threat model: [`docs/PROBLEM.md`](docs/PROBLEM.md) · Verified on-chain facts: [`docs/ONCHAIN_FACTS.md`](docs/ONCHAIN_FACTS.md)
- Scope: [`docs/SCOPE.md`](docs/SCOPE.md) · Testing: [`docs/TESTING.md`](docs/TESTING.md) · Demo: [`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md)
- Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md) · Limitations: [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) · Pitch: [`docs/PITCH.md`](docs/PITCH.md)
- Build progress: [`PROGRESS.md`](PROGRESS.md)

> Status: design complete, build in progress. Everything runs on a local mainnet fork; nothing touches the live protocol.
