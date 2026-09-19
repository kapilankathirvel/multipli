# varun.md: Varun's tasks (≈25%: independent add-ons + demo tooling + risk research)

> **Role:** four self-contained pieces. **None of them needs Kapilan's or Jeffrey's code to be built or tested.** You build against the frozen interfaces; Kapilan plugs your work in at the integration checkpoint (~hour 20).
> **Start every Claude/Cursor session with:** "Read CLAUDE.md and varun.md, then do the next unchecked task in varun.md. Only edit files in Varun's ownership list."
> Tick boxes here as you go.

## Setup (≈20 min)
- [ ] `git clone https://github.com/kapilankathirvel/multipli.git && cd multipli`
- [ ] Foundry. Windows: download `foundry_stable_win32_amd64.zip` from https://github.com/foundry-rs/foundry/releases, unzip to `%USERPROFILE%\.foundry\bin`, add it to PATH. Mac/Linux: `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- [ ] `cd contracts && cp .env.example .env && forge test --match-path "test/fork/*" -vv`: the existing tests pass (setup OK)
- [ ] Python 3.11+ with `pip install pandas numpy matplotlib yfinance` (for V4)

## Ownership (only you edit these)
```
contracts/src/SessionCalendar.sol           contracts/test/unit/SessionCalendar.t.sol
contracts/src/sources/PythSource.sol        contracts/test/unit/PythSource.t.sol
scripts/**                                  research/**
```
Frozen interfaces you implement (don't edit; ask Kapilan): `ISessionCalendar`, `IPriceSource` in `contracts/src/interfaces/IPriceSource.sol`.

## Tasks (any order; all independent)

### V1. `SessionCalendar` (≈1.5h) · CONTRACTS_SPEC §5
- [ ] `contract SessionCalendar is ISessionCalendar`: `wards` auth, `weekMask[asset]` (168 bits, Monday 00:00 UTC = h0, `hourOfWeek = ((ts/3600)+72) % 168`), `holiday[asset][ts/1 days]`, `alwaysOpen[asset]`, `isOpen(asset, ts)`
- [ ] `nyseMask()` pure helper (Mon–Fri 14:00–21:00 UTC)
- [ ] Unit tests (no fork): Fri 20:59 open / 21:00 closed, Sat closed, Mon 14:00 open, holiday closed, alwaysOpen
- **Commit:** `feat(calendar): SessionCalendar with weekly mask + holidays`

### V2. `PythSource`, a real second oracle (≈2h)
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

### V4. Risk research for the deck (≈2.5h), fully off-chain
- [ ] `research/risk.ipynb` or `research/risk.py` → PNG charts in `research/out/` + `research/RISK_RESULTS.md`
- [ ] (a) **Delay-risk table:** σ (annualised) for gold (GC=F / PAXG-USD) and TSLA from yfinance → required buffer `z·σ·√L` for L = 1h, 2h, weekend, z=4 (matches ORACLE_DESIGN §7)
- [ ] (b) **Weekend-gap histogram** for TSLA/NVDA (Fri close → Mon open): P(|gap| > 5%, 10%). Justifies the SessionCalendar
- [ ] (c) **Stale-price loss simulation:** replay gold hourly returns, an oracle frozen for N hours vs a fresh one; how often a 140% vault is under-collateralised yet unliquidatable (legacy) → bad-debt $ per $1M of vaults
- [ ] (d) **Loss-bound chart:** `MaxLoss = rateCap × detectionTime` for a few caps
- **Commit:** `feat(research): risk analysis + charts for the deck`

## Budget ≈7.5h. Hand-off: tell Kapilan when V1/V2 are pushed (he wires them at K7), and send Jeffrey the V4 charts for the deck.
