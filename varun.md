# varun.md: Varun's tasks (≈25%: independent add-ons + demo tooling + risk research)

> **Role:** four self-contained pieces. **None of them needs Kapilan's or Jeffrey's code to be built or tested.** You build against the frozen interfaces; Kapilan plugs your work in at the integration checkpoint (~hour 20).
> **Start every Claude/Cursor session with:** "Read CLAUDE.md and varun.md, then do the next unchecked task in varun.md. Only edit files in Varun's ownership list."
> Tick boxes here as you go.

## Setup (≈20 min)
- [ ] `git clone https://github.com/kapilankathirvel/multipli.git && cd multipli`
- [ ] Foundry. Windows: download `foundry_stable_win32_amd64.zip` from https://github.com/foundry-rs/foundry/releases, unzip to `%USERPROFILE%\.foundry\bin`, add it to PATH. Mac/Linux: `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- [ ] `cd contracts && cp .env.example .env && forge test --match-path "test/fork/*" -vv`: the existing tests pass (setup OK)
- [ ] Python 3.11+ with `pip install pandas numpy matplotlib yfinance requests` (for V4)

## Ownership (only you edit these)
```
contracts/src/SessionCalendar.sol           contracts/test/unit/SessionCalendar.t.sol
contracts/src/sources/PythSource.sol        contracts/test/unit/PythSource.t.sol
scripts/**                                  research/**
```
Frozen interfaces you implement (don't edit; ask Kapilan): `ISessionCalendar`, `IPriceSource` in `contracts/src/interfaces/IPriceSource.sol`.

## Tasks: **do V4 FIRST** (it answers the mentor review, see `review.md`), then V1, V3; V2 is optional


### V1. `SessionCalendar` (≈1.5h) · CONTRACTS_SPEC §5
- [ ] `contract SessionCalendar is ISessionCalendar`: `wards` auth, `weekMask[asset]` (168 bits, Monday 00:00 UTC = h0, `hourOfWeek = ((ts/3600)+72) % 168`), `holiday[asset][ts/1 days]`, `alwaysOpen[asset]`, `isOpen(asset, ts)`
- [ ] `nyseMask()` pure helper (Mon–Fri 14:00–21:00 UTC)
- [ ] Unit tests (no fork): Fri 20:59 open / 21:00 closed, Sat closed, Mon 14:00 open, holiday closed, alwaysOpen
- **Commit:** `feat(calendar): SessionCalendar with weekly mask + holidays`

### V2. (OPTIONAL, only after V4/V1/V3) `PythSource`, a real second oracle (≈2h)
- [ ] `contract PythSource is IPriceSource`: wraps Pyth `getPriceUnsafe(bytes32 id)` → WAD price, WAD conf, `publishTime` as updatedAt; `ok=false` if `conf/price > maxConfBps` or price ≤ 0; **never reverts** (try/catch)
- [ ] Find the Pyth Ethereum mainnet contract address and the **PAXG/USD** (or XAU/USD) price-feed id from Pyth's docs; put them in the test
- [ ] Fork test (block 26011000): observe() returns a sane gold price (±10% of $4,372); a reverting Pyth → `ok=false`
- **Commit:** `feat(sources): PythSource (real Pyth mainnet adapter)`

### V3. Demo bring-up scripts (≈1.5h)
- [ ] `scripts/demo-up.ps1` (Windows) + `scripts/demo-up.sh`, written against the frozen conventions (`script/Deploy.s.sol`, `script/Spell.s.sol`, `deployments/fork.json`):
  1. start `anvil --fork-url $ETH_RPC_URL --fork-block-number 26011000 --auto-impersonate --chain-id 31337` in the background, wait until the RPC answers
  2. `forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key #0>`
  3. `cast rpc anvil_setBalance <AdminSafe> 0x56BC75E2D63100000` then `forge script script/Spell.s.sol --unlocked --sender <AdminSafe> --broadcast`
  4. `cast rpc evm_snapshot`, then write `snapshotId` into `deployments/fork.json`
  5. `scripts/demo-down.ps1`: stop anvil
- [ ] **Self-test without Kapilan's scripts:** steps 1, 3 (balance + impersonated call e.g. `cast call` Vat `wards(Safe)`), 4 and 5 must work. If `Deploy.s.sol` doesn't exist yet, print "skipping deploy" and continue
- **Commit:** `chore(demo): one-command anvil fork + deploy + spell scripts`

### V4. ⭐ Validation study for mentor review R2/R4 (≈4.5h, TOP PRIORITY), fully off-chain · spec: `review.md` §R1.2, §R2, §R4
Everything lives in `research/` (Python 3.11: pandas, numpy, matplotlib, yfinance, web3 or plain JSON-RPC).
- [ ] **Model:** `research/og_model.py`, a line-by-line Python mirror of the score formula in `review.md` §R1.2 (weight-based Wq, MAD, grace-band Wf, integer maths as in Solidity). **Unit-test it against the parity vectors in §R1.4** (100/85/71/75/0); it must match exactly. The state machine (GREEN/YELLOW/RED + guard + hysteresis) goes in the same file per §R3.
- [ ] **Data** (`research/data/`):
  - real Chainlink PAXG/USD round history via `getRoundData` (archive RPC `https://mainnet.gateway.tenderly.co`, proxy `0x9944D86CEB9160aF5C5feB251FD671923323f8C3`)
  - hourly gold (GC=F) + PAXG-USD from yfinance
  - Chainlink USDC/USD rounds around 10–13 Mar 2023 (SVB)
- [ ] **Incident traces I1–I9** (`research/incidents/*.csv`, columns `t, truth, chainlink, pyth, redstone, dex, stale_flags`) from §R2.3. Mark each as real or reconstructed and cite the post-mortem link in the CSV header.
- [ ] **Monte-Carlo fault injection** on the real gold/PAXG history: fault types spike / drift / freeze / clamp / delay × k ∈ {1,2,3,4} affected sources (k ≥ 2 = correlated)
- [ ] **Metrics** with the §R2.4 definitions: FN/FP per incident and per fault type × k; unjust-liquidation count; % of normal hours in YELLOW/RED (user cost); **threshold sweep** (GREEN cut 70/80/90, ε 1/1.5/3%)
- [ ] **Risk reduction (§R4.3):** bad debt per $1M of vault debt with the legacy pipeline (single Chainlink + 1h OSM, no staleness) vs OracleGuard
- [ ] Output `research/RESULTS.md` (tables, honest limitations incl. Mango-class FN) + charts in `research/out/` (confusion matrix, threshold sweep, loss comparison, weekend-gap histogram, σ√L buffer table)
- **Commit:** `feat(research): validation study - incidents, Monte-Carlo FP/FN, risk reduction (mentor review)`

## Budget ≈9h (V4 4.5h + V1 1.5h + V3 1.5h + V2 optional). Hand-off: send Jeffrey `research/RESULTS.md` + charts as soon as V4 lands (mentor slides); tell Kapilan when V1 is pushed (wired at K7).
