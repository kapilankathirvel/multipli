# How to run OracleGuard yourself (Windows, step by step)

> Everything below is copy-paste for **PowerShell**, and **every command in Part B was run and verified on Sep 19**. Start at Step 1 and go in order.
> Time: setup ≈ 15 min (once) · tests ≈ 2 min · live demo ≈ 10 min · dashboard ≈ 5 min.

**What you'll be able to run:**
| Part | What it shows | Needs |
|---|---|---|
| **A. Test suite** (138 tests) | the attacks on the real rwaUSD, our fixes, the incident replays, the random-action safety tests | Foundry |
| **B. Live demo on a local copy of Ethereum** | deploy OracleGuard, install it with the governance spell, then attack it and watch GREEN → YELLOW → RED | Foundry |
| **C. Dashboard** (Jeffrey's "Oracle War Room") | all of it visually, with scenario buttons | Node + pnpm |
| **D. Validation study** (Varun's Python) | FP/FN tables and charts | Python |

---

## Step 1: One-time setup

### 1.1 Check your tools
Open a **new** PowerShell window and run:
```powershell
git --version        # any version
forge --version      # should print "forge Version: 1.5.1-stable"
anvil --version
cast --version
node --version       # v20 or newer (you have v22)
python --version     # 3.11+ (only needed for Part D)
```
**If `forge` is "not recognized":** Foundry is installed at `%USERPROFILE%\.foundry\bin` but this terminal doesn't know about it yet. Close all terminals (and Cursor), reopen, and try again. Still missing? Run this, then open a new terminal:
```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ";$env:USERPROFILE\.foundry\bin", 'User')
```

### 1.2 Get the latest code
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli"
git pull --rebase origin main
```
(If git complains about uncommitted changes, commit them first. See `docs/GIT_WORKFLOW.md`.)

### 1.3 The RPC setting (already done on your machine)
The tests copy Ethereum as it was at block 26,011,000, so they need a node that serves **old** data (an "archive" node). Check that `contracts\.env` contains:
```
ETH_RPC_URL=https://mainnet.gateway.tenderly.co
FORK_BLOCK=26011000
```
If the file is missing: `copy contracts\.env.example contracts\.env`
(Also works: `https://eth.drpc.org`. Does **not** work: `publicnode`, because it has no archive data.)

### 1.4 Only for the dashboard (Part C): install pnpm
```powershell
npm install -g pnpm
pnpm --version
```

### 1.5 Only for the research study (Part D)
```powershell
pip install pandas numpy matplotlib yfinance requests
```

---

## PART A: Run the tests (the proof)

```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli\contracts"
forge test
```
**Expected:** `Ran 16 test suites ... 138 tests passed, 0 failed`. The first run takes a few minutes: it downloads the compiler and caches the Ethereum data it needs. Later runs take seconds.

### A.1 Watch the attacks succeed on today's rwaUSD
```powershell
forge test --match-contract BaselineTest -vv
```
`-vv` prints the logs. You'll see:
- **S1:** "Chainlink round age (hours): 186 … rwaUSD minted against it: 31231"
- **S3:** "Real collateral value ($): 43724 … rwaUSD minted ($): 312319 … Bad debt created ($): 268595"
- **S4:** "True price ($): 4372 · OSM price used ($): 3716 · Victim CR at true price (%): 145": a healthy vault liquidated

### A.2 Watch the same attacks fail with OracleGuard installed
```powershell
forge test --match-contract OracleGuardTest -vv
```
You'll see S1a (YELLOW, capped at $50k), S1b (RED, repay works), S2, S3a, S3b ("bad debt: $0"), S4 ("healthy 145% vault NOT liquidated"), install and rollback.

### A.3 The mentor's validation: 8 historical incidents replayed
```powershell
forge test --match-contract IncidentReplayTest -vv
```
Each incident prints false negatives/positives for OracleGuard vs legacy, the liquidation lag, and the worst-case debt. To see the hour-by-hour price path (truth vs the price the Vat used vs the state):
```powershell
$env:REPLAY_TRACE="true"; forge test --match-test "I8" -vv; Remove-Item Env:REPLAY_TRACE
```

### A.4 Other useful groups
```powershell
forge test --match-contract HarnessTest -vv              # our facts match real mainnet
forge test --match-contract AggregatorParityVectorsTest   # review.md score examples: 100/85/71/75/0
forge test --match-contract SmartOSMForkTest -vv          # SmartOSM works with the REAL Spotter/Vat/Dog/Clipper
forge test --match-contract OracleGuardInvariantTest      # 6 safety promises x 3,200 random actions each
forge test --match-path "test/unit/*"                     # fast logic tests (no internet needed)
forge test --gas-report --match-contract SmartOSMForkTest # gas costs
```

---

## PART B: The live demo on a local copy of Ethereum
You'll use **two PowerShell windows**: Terminal 1 runs the local blockchain, Terminal 2 sends commands to it.

### B.1 Terminal 1: start the local blockchain (leave it running)
```powershell
anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26011000 --chain-id 31337 --auto-impersonate
```
Wait for `Listening on 127.0.0.1:8545`. This is a private copy of Ethereum with the real rwaUSD contracts in it. `--auto-impersonate` lets us act as rwaUSD's Admin Safe without its keys (only possible on a local copy).

### B.2 Terminal 2: deploy OracleGuard, then install it with the governance spell
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli\contracts"
$R  = "http://127.0.0.1:8545"
$K0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"   # anvil's public test key #0 (local only)
$SAFE = "0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99"                       # rwaUSD's real Admin Safe
$ILK  = "0x7061786700000000000000000000000000000000000000000000000000000000" # "paxg"

# 1) Deploy all OracleGuard contracts (does NOT touch rwaUSD yet). Writes ..\deployments\fork.json
forge script script/Deploy.s.sol --rpc-url $R --broadcast --slow --private-key $K0

# 2) Give the Admin Safe some ETH for gas, then run the spell AS the Admin Safe
cast rpc anvil_setBalance $SAFE 0x56BC75E2D63100000 --rpc-url $R
forge script script/Spell.s.sol --rpc-url $R --broadcast --slow --unlocked --sender $SAFE
```
Both should end with `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. The first deploy can take a few minutes; **don't interrupt it** (see Troubleshooting).
*(`--slow` sends one transaction at a time. Without it, anvil sometimes leaves the last transactions stuck.)*

### B.3 Load the addresses and check the result
```powershell
$j = Get-Content ..\deployments\fork.json | ConvertFrom-Json
$CTL = $j.oracleguard.controller; $OSM = $j.oracleguard.smartOsm; $AGG = $j.oracleguard.aggregator
$PY = $j.oracleguard.sources.pyth; $RS = $j.oracleguard.sources.redstone; $DX = $j.oracleguard.sources.dexTwap

# Is the rwaUSD Spotter now reading SmartOSM? (first line = SmartOSM's address, second = mat 1.4e27)
cast call 0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2 "ilks(bytes32)(address,uint256)" $ILK --rpc-url $R

# Controller status: state (0=GREEN 1=YELLOW 2=RED), score, guard, line, debt
cast call $CTL "status(bytes32)(uint8,uint16,bool,uint256,uint256)" $ILK --rpc-url $R

# SmartOSM status: 1 = LIVE
cast call $OSM "status()(uint8)" --rpc-url $R
```
**Expected** (verified): pip `0x89334e…` (SmartOSM; your address may differ), status `0 100 false 2.93e50 4.302e49` = GREEN, score 100, no guard, line **$293,029** (debt $43,029 + $250k hourly budget), SmartOSM `1` (LIVE).

**Save a checkpoint** so you can undo each scenario:
```powershell
$SNAP = cast rpc evm_snapshot --rpc-url $R; $SNAP
```

### B.4 Run the scenarios yourself
The true price at this block is **$4,372.478** = `4372478143390000000000` (18 decimals). A "keeper tick" = wait an hour → refresh the 3 simulated sources → `poke()` SmartOSM → `sync()` the controller.

**Scenario S3: one oracle is compromised (reports 10× the price)**
```powershell
cast rpc evm_increaseTime 3600 --rpc-url $R; cast rpc evm_mine --rpc-url $R
cast send $RS "setPrice(uint256)" 4372478143390000000000  --private-key $K0 --rpc-url $R
cast send $DX "setPrice(uint256)" 4372478143390000000000  --private-key $K0 --rpc-url $R
cast send $PY "setPrice(uint256)" 43724781433900000000000 --private-key $K0 --rpc-url $R   # 10x !
cast send $OSM "poke()" --private-key $K0 --rpc-url $R
cast send $CTL "sync(bytes32)" $ILK --private-key $K0 --rpc-url $R
cast call $CTL "status(bytes32)(uint8,uint16,bool,uint256,uint256)" $ILK --rpc-url $R
cast call $AGG "read()((uint256,uint256,uint256,uint16,uint8,uint8,uint64,bool))" --rpc-url $R
```
**Expected** (verified): `1 71 false 9.302e49 4.302e49` → YELLOW, score 71, and the ceiling cut to **$93,029** (debt + $50k). `read()` → `(4372478143390000000000, …, 71, 4, 3, 0, true)`: **the price did not move**, and only 3 of 4 sources count. The fake source was thrown out as an outlier. *(Legacy rwaUSD: $268,595 of bad debt.)*

Undo, and take a fresh checkpoint (a checkpoint can only be used once):
```powershell
cast rpc evm_revert $SNAP --rpc-url $R; $SNAP = cast rpc evm_snapshot --rpc-url $R
```

**Scenario S2: the market drops 8% while the delayed price lags**
```powershell
cast send $RS "setPrice(uint256)" 4022679891918800000000 --private-key $K0 --rpc-url $R
cast send $DX "setPrice(uint256)" 4022679891918800000000 --private-key $K0 --rpc-url $R
cast send $PY "setPrice(uint256)" 4022679891918800000000 --private-key $K0 --rpc-url $R
cast send $CTL "sync(bytes32)" $ILK --private-key $K0 --rpc-url $R
cast call $CTL "status(bytes32)(uint8,uint16,bool,uint256,uint256)" $ILK --rpc-url $R
```
**Expected** (verified): `2 71 false 4.302e49 4.302e49` → RED immediately. The ceiling (4th value) equals the debt (5th): new borrowing is frozen. Liquidations stay on.
```powershell
cast rpc evm_revert $SNAP --rpc-url $R; $SNAP = cast rpc evm_snapshot --rpc-url $R
```

**Scenario S1: every price source goes silent for 26 hours**
```powershell
cast rpc evm_increaseTime 93600 --rpc-url $R; cast rpc evm_mine --rpc-url $R
cast send $OSM "poke()" --private-key $K0 --rpc-url $R          # skipped: no fresh data (but never sets price to 0)
cast send $CTL "sync(bytes32)" $ILK --private-key $K0 --rpc-url $R
cast call $OSM "status()(uint8)" --rpc-url $R                     # 2 = STALE
cast call $CTL "status(bytes32)(uint8,uint16,bool,uint256,uint256)" $ILK --rpc-url $R
cast call $OSM "price()(uint256,uint256,uint64)" --rpc-url $R      # still a real price, NOT 0
```
**Expected** (verified): SmartOSM `2` (STALE), controller `2 0 false 4.302e49 4.302e49` (RED, score 0), price `4372478143390000000000` (still $4,372, never zero). *(Legacy rwaUSD keeps saying "valid".)*
```powershell
cast rpc evm_revert $SNAP --rpc-url $R; $SNAP = cast rpc evm_snapshot --rpc-url $R
```

*(S4, the captured dip / liquidation guard, needs several timed steps. Run it from the dashboard button, or see it in `forge test --match-contract OracleGuardTest -vv`.)*

**Roll back the whole install** (proves the one-transaction undo):
```powershell
forge script script/Spell.s.sol --sig "rollback()" --rpc-url $R --broadcast --slow --unlocked --sender $SAFE
cast call 0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2 "ilks(bytes32)(address,uint256)" $ILK --rpc-url $R   # back to 0x89fb… (legacy OSM)
```

### B.5 Alternative: Varun's one-command script
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli"
$env:ETH_RPC_URL = "https://mainnet.gateway.tenderly.co"
powershell -ExecutionPolicy Bypass -File scripts\demo-up.ps1      # starts anvil + deploy + spell + snapshot
powershell -ExecutionPolicy Bypass -File scripts\demo-down.ps1    # stops it
```
⚠️ It currently deploys **without `--slow`**, which Jeffrey found can hang on this fork. If it sits at "Deploying…" for more than ~5 minutes, stop it (`demo-down.ps1`) and use the manual steps B.1–B.2. (Fix requested from Varun.)

### B.6 Stop everything
In Terminal 1 press **Ctrl + C**. Everything on the local copy disappears. Next time, start again at B.1 (and re-copy `fork.json` for the dashboard, because addresses can change).

---

## PART C: The dashboard (Oracle War Room)

### C.1 Mock mode (no blockchain needed; good for a first look)
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli\dashboard"
pnpm install          # first time only
pnpm dev
```
Open **http://localhost:5173**. The top-right pill says **MOCK**. Click the scenario buttons (S1–S4, Poke, Sync, Warp +1h, Reset) and watch the confidence gauge, the traffic light, the Vat panel, "what this state changes", and the legacy-vs-OracleGuard comparison. Stop with **Ctrl + C**.

### C.2 Live mode (the real contracts on your local fork)
1. Do **Part B.1 and B.2** first (anvil running, deploy + spell done).
2. In a third terminal:
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli\dashboard"
copy ..\deployments\fork.json public\fork.json
pnpm dev --mode live
```
3. Open the URL Vite prints (5173, or **5174** if 5173 is busy). The pill says **LIVE**, and the buttons now send real transactions to your fork.

### C.3 Dashboard checks
```powershell
pnpm check:parity     # the dashboard's score formula == the contract's (5/5 PASS)
pnpm build            # type-check + production build
```
Full guide: `dashboard/DASHBOARD.md`.

---

## PART D: Varun's validation study (Python)
```powershell
cd "C:\Users\Kapilan Kathirvel\Desktop\multipli"
python research/run_study.py
```
It runs the parity self-test, the 9 incidents, the Monte-Carlo fault injection, the threshold sweep and the risk numbers, then writes `research/RESULTS.md` and charts in `research/out/`. With real market data first: `python research/fetch_data.py; python research/run_study.py`.
⚠️ This **regenerates Varun's files**. If you're only looking, undo it afterwards with `git restore research/` so you don't commit his outputs by accident.

---

## Troubleshooting
| Symptom | Cause | Fix |
|---|---|---|
| `forge : The term 'forge' is not recognized` | this terminal doesn't have the new PATH yet | close and reopen the terminal/Cursor (Step 1.1) |
| `HTTP error 403 … Archive requests require a personal token` | the RPC doesn't serve old blocks (e.g. publicnode) | use `https://mainnet.gateway.tenderly.co` or `https://eth.drpc.org` in `contracts\.env` / the anvil command |
| tests very slow or `429 Too Many Requests` | the free RPC is rate-limiting | wait a minute and rerun (data gets cached), or switch to `eth.drpc.org` |
| `Address already in use` when starting anvil | an old anvil is still running | `Stop-Process -Name anvil -Force`, then start again |
| Deploy hangs waiting for receipts | transactions stuck on anvil | Ctrl + C, restart anvil (B.1), rerun **with `--slow`** |
| `nonce too low` | a half-finished deploy left the fork dirty | restart anvil (B.1) and redo B.2 |
| `OSM/not-passed` on `poke()` | less than 1 hour since the last update | `cast rpc evm_increaseTime 3600` + `evm_mine`, then poke |
| poke doesn't change anything / state goes RED unexpectedly | the 3 simulated sources are > 1h old (stale) | refresh them with `setPrice` right before `poke` (as in B.4) |
| `Vat/ceiling-exceeded` | **expected** in RED/YELLOW: that's OracleGuard blocking new borrowing | none (it's the feature) |
| dashboard shows a red error banner in live mode | `public\fork.json` missing or from an old anvil session | re-copy `..\deployments\fork.json` into `dashboard\public\` |
| `running scripts is disabled on this system` (.ps1) | PowerShell execution policy | run with `powershell -ExecutionPolicy Bypass -File scripts\demo-up.ps1` |
| `evm_revert` returns `false` | that checkpoint was already used | take a new one: `$SNAP = cast rpc evm_snapshot --rpc-url $R` |

---

## Cheat sheet
```powershell
# tests
cd contracts; forge test                                   # all 138
forge test --match-contract BaselineTest -vv               # attacks on today's rwaUSD
forge test --match-contract OracleGuardTest -vv            # same attacks, blocked
forge test --match-contract IncidentReplayTest -vv         # 8 historical incidents
# live demo
anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26011000 --chain-id 31337 --auto-impersonate   # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cast rpc anvil_setBalance 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:8545
forge script script/Spell.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow --unlocked --sender 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99
# dashboard
cd dashboard; copy ..\deployments\fork.json public\fork.json; pnpm dev --mode live
```
