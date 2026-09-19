# DASHBOARD.md — the Oracle War Room, explained

> **Who this is for:** anyone who needs to demo, defend, or change the dashboard — teammates, the mentor, judges.
> **What it covers:** why the dashboard exists, how it connects to OracleGuard, every panel, every button, both data modes, how to run it end to end on a real mainnet fork, and what to do when something breaks.
> **Companion docs:** `FLOW_EXPLAINED.md` (the on-chain flow this screen visualises) · `review.md` (the mentor asks it answers) · `docs/DEMO_SCRIPT.md` (the scenario runbook) · `dashboard/README.md` (quick-start).

---

## 1. Why a dashboard at all?

OracleGuard is a set of smart contracts. Its entire value is *behaviour over time*: a feed goes stale, a price gets manipulated, a crash happens — and the protocol reacts differently than the legacy one would. None of that is visible in a contract. Judges have ~3 minutes; they will not read Solidity.

The dashboard ("Oracle War Room") exists to make four things **visible and undeniable**:

1. **The problem is real.** The legacy Maker OSM that rwaUSD uses today serves a price as `VALID` no matter how old it is, and trusts a single feed. The *Legacy vs OracleGuard* panel shows this side by side, on the real contracts.
2. **The score is not magic.** The mentor asked *"define how the 0–100 confidence score is calculated and how much each oracle contributes"* (`review.md` R1). The dashboard shows each oracle's weight share and the score as the literal product `Wq × Wd × Wf`, recomputed in the browser from the raw observations.
3. **Every state has a concrete consequence.** The mentor asked *"clearly specify what GREEN/YELLOW/RED actually changes"* (R3). The *What this state changes* panel renders exactly that, parameter by parameter, for whatever state we're in.
4. **Attacks fail live.** The scenario buttons replay the four attacks from `docs/DEMO_SCRIPT.md` against the real, forked rwaUSD contracts, and every panel updates within 2 seconds.

It is **not** a user-facing app. There's no wallet, no login, no borrowing UI. It's an operator/war-room view of one collateral type (`paxg`) — the kind of screen a risk team would watch.

---

## 2. How it fits into OracleGuard

```
                     ┌──────────────────── on-chain (mainnet fork on anvil) ─────────────────────┐
  Chainlink (real) ─┐│                                                                           │
  Pyth     (mock)  ─┼┼─► Aggregator ──► SmartOSM ──► Spotter ──► Vat   (Multipli core, unchanged) │
  RedStone (mock)  ─┤│   weighted       1h delay      spot =            ▲                         │
  DEX TWAP (mock)  ─┘│   median +       cur / nxt     price / 1.4       │ Vat.line                │
                     │   score 0–100        │                           │                         │
                     │                      └──► RiskController ──► LineExecutor                  │
                     │                           GREEN/YELLOW/RED ──► HoleExecutor ──► Dog.hole   │
                     │   Legacy OSM (still deployed, no longer wired in — shown for contrast)      │
                     └───────────────────────────────▲───────────────────────────────────────────┘
                                                     │ viem: reads every 2s, writes on button press
                                              ┌──────┴──────┐
                                              │  Dashboard  │
                                              └─────────────┘
```

| Dashboard panel | Reads from | On-chain call(s) |
|---|---|---|
| Sources | Aggregator | `observations()`, `sourceCount()`, `sourceAt(i)` |
| Confidence | Aggregator | `read()` (+ the factors recomputed in the UI) |
| Controller | SmartOSM + RiskController | `price()`, `status()`, `age()`, `controller.status(paxg)` |
| Vat · paxg | RiskController / Vat | `controller.status(paxg)` → `lineRad`, `debtRad`; fallback `vat.ilks(paxg)` |
| What this state changes | derived | state + guard from `controller.status(paxg)`, rules from `review.md` §R3 |
| Legacy vs OracleGuard | Legacy OSM + SmartOSM | `eth_getStorageAt(legacyOsm, 3)`, legacy `zzz()` |
| Event log | SmartOSM + RiskController logs | `eth_getLogs`, decoded with the frozen ABIs |
| Scenario buttons | MockSources, SmartOSM, RiskController, anvil | `setPrice`, `poke()`, `sync(paxg)`, `evm_*` test RPCs; S3 only: `anvil_setStorageAt` on the legacy OSM |

The dashboard only ever **writes** through the same permissionless/keeper paths a real keeper would use (`poke`, `sync`) plus the demo-only MockSource setters and anvil's time/snapshot RPCs. It never writes to OracleGuard's state or the live Maker core (Vat, Spotter, Dog), so it cannot bypass OracleGuard's rules — if a panel changes, the contracts decided it. The one exception is S3's legacy side: it writes a 10× price into the **legacy OSM**, which after the spell nothing reads — it exists only so the comparison panel has a compromised legacy to compare against (§5).

---

## 3. Two data modes

The pill in the top-right corner shows the mode and the block number the page last read. The line under the header says in plain words where the numbers come from.

### MAINNET (default: `pnpm dev`)
- **Real inputs, read every 6s from Ethereum mainnet** (public RPC `ethereum-rpc.publicnode.com`, override with `VITE_MAINNET_RPC_URL`). `src/mainnet.ts`:

| Source row | Where the number comes from |
|---|---|
| Chainlink | `latestRoundData()` on the real PAXG/USD feed `0x9944…f8C3` (price + `updatedAt`) |
| Pyth | `getPriceUnsafe(PAXG/USD)` on the Pyth contract `0x4305…69C6`: the **last price someone pushed on-chain**. Pyth is a pull oracle and nobody pushes PAXG on Ethereum, so it is genuinely ~110 days old and shows **stale**. That's a real finding, not a bug (Pyth's off-chain Hermes API now requires an API key). |
| RedStone | RedStone's public price API (`api.redstone.finance`, `redstone-primary-prod`), price + timestamp |
| DEX TWAP | 30-minute TWAP from the Uniswap v3 PAXG/USDC 0.05% pool `0x5aE1…4082` (`observe([1800, 0])`), USDC ≈ USD |
| Vat · paxg | the real `Vat.ilks("paxg")`: debt = `Art × rate`, ceiling = `line` |
| Legacy OSM | the real legacy OSM: slot 3 (`cur` + `has`) and `zzz` |
| `mat` | the real `Spotter.ilks("paxg").mat` (1.40) |

- **OracleGuard is not deployed on mainnet**, so its logic (aggregator, SmartOSM, RiskController) runs in the page (`src/protocol.ts` + the `World` in `src/data.ts`) on top of those real inputs. It starts like the spell: SmartOSM primed from the legacy OSM's price. A simulated keeper pokes once per hour, like production.
- **Scenario buttons never invent prices.** They put a fault *on top of* the real feeds: stop the publishers and move the clock (S1), multiply the fast feeds by 0.92 (S2), multiply Chainlink by 10 (S3), dip every feed by 15% for two hops (S4). Reset removes every fault.
- If a read fails, that source shows `no data` (like a source adapter returning `ok = false`); if the whole RPC fails, a red banner says so. There is no fallback to fake numbers.

### FORK (`pnpm dev --mode live`)
- Talks to an **anvil fork of Ethereum mainnet at block 26,011,000** with OracleGuard deployed and installed by the governance spell: the real rwaUSD `Vat`, `Spotter`, `Dog`, legacy OSM and Chainlink feed, plus three `MockSource`s the buttons control.
- Polls every 2 seconds. All ages use **chain time**, so time warps show up.
- Addresses come from `dashboard/public/fork.json` (a copy of `deployments/fork.json`).
- **Score:** the page shows the agreed additive score, recomputed from the chain's `observations()`. Until Kapilan ports it, the deployed aggregator still multiplies, so the score card shows *"The deployed contract still multiplies the factors (score N)"* whenever the two differ, and the status card says the state was *"set on-chain by the RiskController"* when the chain's state differs from what the new score would give.
- Use it for the video (J6): these are real transactions against real Maker contracts.

`.env.development` sets `VITE_MODE=mainnet`; `.env.live` sets `VITE_MODE=fork` (the old value `live` still works).

---

## 4. The screen, panel by panel

### 4.1 Header
Title, the mode pill (`Mainnet data · block N` or `Local fork · block N`), the time of the last successful read, and one sentence saying where the numbers come from. A red banner appears only when a read fails.

### 4.2 Scenario bar
Two rows: **scenarios** (Reset, S1–S4) and **step by hand** (Poke, Sync, Warp +1h). Hovering a button shows what it does in the status line; after a click the line shows the result or the revert reason. Details in §5.

### 4.3 Status card (left)
- **Risk state**: GREEN / YELLOW / RED, and the **confidence score**.
- **Why**: the rule that produced the state (§6).
- **Liquidation guard**: off, or 🛡️ ON (`Dog.hole = 0`).
- **Price vaults are valued at**: SmartOSM `cur`, and `nxt` (the price that takes over at the next hourly poke).
- **SmartOSM**: its status in words (`LIVE` = last good update under 2h ago; `STALE`; `QUARANTINED` = holding back a suspicious upward jump) and the age of the last good update.

### 4.4 Confidence score (right)
The score as a **sum of points** (team decision Sep 19, so a volatility penalty can be subtracted later):

```
score = ⌊ 50·Wq + 30·Wd + 20·Wf ⌋ − volatility penalty      (0 if fewer than 2 sources agree)
GREEN ≥ 80 · YELLOW 40–79 · RED < 40
```

| Row | Factor (0–1) | Computed from | Max points |
|---|---|---|---|
| Quorum | Wq = weight of counted sources ÷ total weight | which sources are fresh *and* agree | 50 |
| Agreement | Wd = 1 − spread ÷ 2% (spread = (hi − lo) / median of the counted prices); 0 if nothing counts | the counted prices | 30 |
| Freshness | Wf = 1 while the newest counted price is ≤ ½ its source's max age, then linear → 0 | the newest counted price's age | 20 |
| Volatility penalty | placeholder, currently 0 | — | − |

**Nothing in these rows is hard-coded except the 50/30/20 split and the source weights (2/2/2/1).** The factors are recomputed from the sources on every poll. They look constant when nothing is happening because nothing is changing: the counted sources stay the same, prices agree to ~0.05%, and the newest price is always seconds old. They move as soon as a scenario runs (S2: Quorum 50 × 0.43; S1: everything 0).

The coloured strip under the total shows the thresholds and where the score sits.

### 4.5 Price sources
One row per source: price, **age / max age**, status (`counted` = fresh and agreeing, `stale`, `outlier`, `no data`), and its **weight share** (28.6 / 28.6 / 28.6 / 14.3%). Under each name: where the number comes from. Footer: OracleGuard's price (weighted median of the counted sources) and the spread.

**Max age per source** (governance-set in the aggregator, same values as `script/DeployLib.sol`, `review.md` §R1.1):
- **Chainlink 25h.** The PAXG/USD feed is a *deviation + heartbeat* feed: it only writes when the price moves past its deviation threshold, or once every 24h (the heartbeat). In a quiet market it updates only every ~24h, and that is normal. 24h + 1h grace = 25h. Anything tighter would mark a healthy Chainlink as stale most of the day.
- **Pyth / RedStone 1h.** These publish off-chain many times a second; a healthy one is seconds old. 1h matches the SmartOSM hop (a new price is accepted at most once an hour), so a source older than one hop has missed a whole update cycle.
- **DEX TWAP 1h.** A TWAP is computed at read time, so it is always "fresh"; the 1h bound only matters if the adapter stops returning data.

### 4.6 Borrowing against PAXG
The `Vat` (Maker's core ledger) numbers for the `paxg` collateral type, in plain words:
- **debt**: all rwaUSD currently borrowed against PAXG (`Art × rate`). Real: ≈ $43,030.
- **debt ceiling**: `Vat.line`, the most rwaUSD that may be outstanding against PAXG. A new borrow that would push debt above it reverts (`Vat/ceiling-exceeded`); repayments never check it.
- **room**: ceiling − debt = how much can still be borrowed right now.

This is OracleGuard's only borrowing lever: GREEN sets the ceiling to debt + $250k, YELLOW to debt + $50k, RED to exactly the debt (no new borrowing). In mainnet mode a note also shows the **real** mainnet ceiling today ($1,000,000), since OracleGuard isn't installed there.
Below: what the state means for users (borrow / repay / new liquidations / `Spotter.mat` never touched).

### 4.7 Legacy OSM vs OracleGuard
Left: the legacy OSM Multipli runs today (real price, reported **VALID** at any age, no staleness check, one source). Right: OracleGuard's price, state, score and SmartOSM status.
Banners appear automatically:
- **S3**: the legacy price is > 50% away from OracleGuard's median. *"10 PAXG worth $X can borrow $Y, leaving $Z of bad debt"*.
- **S1**: the legacy price is > 24h old but still VALID, and OracleGuard is RED.

The dollar figures are **derived**: collateral = 10 × OracleGuard's price; max borrow = 10 × legacy price ÷ `mat`. On the fork they reproduce the Baseline tests ($312,320 borrowable against $43,725, i.e. $268,595 of bad debt; S1: $31,232).

### 4.8 Event log (collapsed)
Click to open. Mainnet mode logs the modelled events (`Init`, `Poke`, `PokeSkipped`, `Quarantined`, `StateChanged`, `GuardOn/Off`, `Synced`, plus `Scenario` / `Warp` / `Reset`); fork mode decodes the real SmartOSM and RiskController events.

---

## 5. The buttons

Each button maps to a step in `docs/DEMO_SCRIPT.md` §B and a threat in `docs/PROBLEM.md`. "Live" shows the exact on-chain actions (`src/scenarios.ts`).

### Reset
- **Does:** returns everything to the post-spell starting point (GREEN, score ~100, line $293,029).
- **Live:** `evm_revert` to a snapshot the dashboard took when the page loaded, then takes a fresh snapshot (anvil consumes a snapshot on revert, so the next Reset needs a new one).
- **Mainnet:** clears every fault and re-primes the modelled SmartOSM from the real legacy price.
- **Use:** before every scenario, so each one starts clean.

### S1 · stale feed — threat V1 (unbounded stale acceptance) + V10
- **Story:** the publishers go quiet for a day. The legacy OSM keeps serving its last price as valid forever.
- **Live:** `evm_increaseTime(26h)` with nobody refreshing → the mocks (1h maxAge) *and* Chainlink (25h) are all stale → `SmartOSM.poke()` → `sync(paxg)`.
- **Expect:** 4 × ✗, **no quorum**, score **0**, `PokeSkipped NO_QUORUM`, OSM **STALE**, **RED**, borrowing **frozen**, line = debt. Legacy column still says **VALID** → **S1 banner**.
- **Say:** *"Same price, a day old. Legacy lets you borrow against it. We freeze new debt — and you can still repay."*

### S2 · market −8% — threat V2 (stale-high over-borrowing)
- **Story:** the real market drops 8%. The delayed OSM price is still high, so for up to an hour you could borrow against a price that no longer exists.
- **Live:** read the real Chainlink price `p` → `setPrice(0.92·p)` on the three mocks → `sync(paxg)`. **No poke** — the OSM lagging is the whole point.
- **Expect:** Chainlink becomes the **outlier** (✗) because the other three agree at −8%; Wq ≈ 0.71; **RED** via `live.lo < OSM·(1 − 1.5%)`. Liquidations **stay open**.
- **Say:** *"We see the market below our own delayed price, so we close the over-borrowing window — but a real drop must still liquidate, so the Dog stays open."*

### S3 · compromised source — threats V5 + V6 (single source, admin key)
- **Story:** one oracle is compromised and reports 10× the real price. On the legacy stack, one feed *is* the price.
- **Live, OracleGuard side:** `setPrice(p)` on two mocks (honest), `setPrice(10·p)` on the Pyth mock → poke → `sync(paxg)`.
- **Live, legacy side:** the legacy stack never reads the mocks, so compromising a mock alone leaves nothing to compare (we found this on the first live run — the banner never fired). So the button also writes the **end state of Kapilan's `Baseline_S3` fork test** into the legacy OSM: `anvil_setStorageAt(legacyOsm, slot 3, has=1 | 10·p)` — exactly what the Safe swapping the adapter to a 10× feed and two pokes produce. After the spell nothing reads the legacy OSM, so this touches only the comparison panel; Reset reverts it. The status line says so: `legacy fed the same ×10`.
- **Expect:** the ×10 feed is an **outlier** (✗), median unchanged, score 71 → **YELLOW** (a major oracle is missing, so we're cautious: $50k of new debt, total). Legacy column shows $43,724.78 → **S3 banner** with the measured $268,595 bad debt.
- **Say:** *"No single oracle can move our price — it takes two of the three major networks. Legacy would have minted $312k against $44k of gold."*

### S4 · captured wick — threat V3 (stale-low unfair liquidation)
- **Story:** a brief −15% wick gets captured by the 1-hour OSM. The market recovers, but the protocol is now valuing every vault at the wick for the next hour — healthy vaults get liquidated.
- **Live:** `setPrice(0.85·p)` → poke (wick into `nxt`) → warp to next hop → refresh at 0.85·p → poke (wick into `cur`) → `setPrice(p)` (recovery) → `sync(paxg)`.
- **Expect:** OSM `cur` ≈ $3,716 while live ≈ $4,372. Score high, state **GREEN**, **🛡️ guard ON** (`Dog.hole = 0`): *new* liquidations paused, auto-expiring after at most 6h. "New liquidations: paused" in the effects panel.
- **Say:** *"The market is well above our delayed price with broad agreement — vaults are safer than the OSM thinks. So we pause new liquidations until the delayed price catches up. Never more than 6 hours."*

### Poke
- **Does:** one hourly keeper step. Waits for the hop if needed, refreshes the three mocks to the real Chainlink price, then `SmartOSM.poke()`, then `sync`.
- **Why the refresh:** the mocks have a 1h maxAge — without it, a poke after any warp would be skipped for lack of quorum.

### Sync
- **Does:** `RiskController.sync(paxg)` only. Re-evaluates the state from current evidence. Permissionless and idempotent.

### Warp +1h
- **Does:** `evm_increaseTime(3600)` → refresh the mocks → poke → sync. One "hour of normal life". Use it to show the pipeline flowing, a quarantined rise being confirmed on the next hop, or the guard counting down.

### Two ordering rules the live buttons enforce (learned the hard way in K3)
1. `SmartOSM.poke()` reverts `OSM/not-passed` until `zzz + hop` — so every poke first **warps to the next hop**.
2. The mocks' 1h maxAge means they must be refreshed **after** that warp and **immediately before** the poke. Refreshing first and warping second re-stales them.

---

## 6. Rules reference (what decides the colour)

Checked top to bottom by `RiskController._target` (and mirrored in `src/protocol.ts:deriveState`):

1. no quorum (< 2 inliers) **or** score < 40 → **RED**  *(the deployed contract still uses 50 until `DeployLib.sol` is updated)*
2. SmartOSM not `LIVE` (STALE / QUARANTINED / STOPPED) → **RED**
3. `live.lo < OSM cur × (1 − 1.5%)` — market below our delayed price → **RED**
4. score < 80 → **YELLOW** (also: market closed per SessionCalendar, for ilks that have one)
5. otherwise → **GREEN**

**Guard** (independent): score ≥ 80 **and** `live.hi × (1 − 3%) > OSM cur` → `Dog.hole = 0`, auto-off after 6h.

**Hysteresis:** downgrades are immediate; upgrades need `kUp = 3` healthy syncs ≥ 10 minutes apart. This is why, in live mode, the colour can stay YELLOW/RED for a few syncs after a scenario "recovers" — the mainnet-mode model simplifies this and upgrades immediately.

---

## 7. Running it

### 7.1 Mainnet data (no local chain)
```powershell
cd C:\Users\jeffr\Desktop\multipli\multipli\dashboard
pnpm install          # once
pnpm dev              # http://localhost:5173 (needs internet: mainnet RPC + RedStone API)
pnpm check:parity     # score vectors (5/5) + V-e quarantine check
pnpm build            # typecheck + production build
```

### 7.2 Live, end to end (real mainnet fork)
**Tools:** Foundry only — `anvil`, `forge`, `cast`. Nothing else: no wallet, no Hardhat, no Docker.

On this machine Foundry **v1.5.1** (the version Kapilan verified the contracts with) is installed at `%USERPROFILE%\.foundry\bin` and on the user PATH. It came from the official `foundry-rs/foundry` GitHub release `foundry_v1.5.1_win32_amd64.zip`, SHA-256 `293fedd9…e86d5ae`, checked against the digest GitHub recorded when the release CI uploaded it. **Open a new terminal** after install so the PATH change is picked up; check with `forge --version`. To install on another Windows machine: download that zip from the release page, extract it to `%USERPROFILE%\.foundry\bin`, add that folder to PATH.

**Archive RPC:** the fork is pinned to an old block, so the upstream RPC must serve archive state. `https://mainnet.gateway.tenderly.co` and `https://eth.drpc.org` both work keyless. (`publicnode` does not; `1rpc.io` rate-limits.)

Open three terminals from the repo root:

```powershell
# ── terminal 1: the fork (leave running) ─────────────────────────────────────
anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26011000 --chain-id 31337 --auto-impersonate

# ── terminal 2: deploy OracleGuard, then install it with the governance spell ─
cd contracts
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow `
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
cast rpc anvil_setBalance 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:8545
forge script script/Spell.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --slow --unlocked `
  --sender 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99

# ── terminal 3: the dashboard against the fork ───────────────────────────────
cd dashboard
copy ..\deployments\fork.json public\fork.json
pnpm dev --mode live
```

Notes:
- The private key is **anvil's public test key #0** — it only exists on local forks. It's also the MockSources' ward, which is why the scenario buttons can move them.
- The spell runs **as the rwaUSD Admin Safe**, impersonated (anvil `--unlocked`). It points `Spotter.pip` at SmartOSM and gives the executors their authority. Rollback: same command with `--sig "rollback()"`.
- **Use `--slow`** (sends one transaction, waits for its receipt, then the next). Without it, forge fires Deploy's 28 transactions in a burst and on this fork anvil left the last three stuck in its mempool as "queued" even though their nonces were correct — forge then waits for receipts forever. See §9 if it happens anyway.
- **The first deploy on a fresh fork is slow** (minutes, not seconds): the first `forge` run downloads solc 0.8.24, and anvil fetches every mainnet storage slot it touches from the RPC. Don't kill it mid-broadcast — a half-finished deploy leaves the fork dirty (`nonce too low` next time, see §9).
- Anvil's account #0 carries its **real mainnet nonce** (~8,150) on the fork, so deployed addresses are not the familiar `0x5FbDB…` ones — always use `fork.json`.
- If port 5173 is taken (another dev server), Vite silently moves to **5174** — check the terminal for the URL.
- Every time you restart anvil you must re-run terminal 2 **and** re-copy `fork.json` (addresses can change).
- `dashboard/public/fork.json` is gitignored — it's per-machine state.

---

## 8. Code map

```
dashboard/
├─ DASHBOARD.md                ← this file
├─ README.md                   quick-start + panel checklist
├─ scripts/parity.mjs          review.md §R1.4 vectors, additive score (pnpm check:parity)
├─ public/fork.json            (gitignored) live-mode address book
└─ src/
   ├─ protocol.ts              aggregator + additive score + controller rules. No React, no viem.
   ├─ mainnet.ts               real mainnet reads (Chainlink, Pyth, RedStone, Uniswap TWAP, Vat, Spotter, legacy OSM)
   ├─ data.ts                  types, mainnet provider (real inputs + modelled OracleGuard), fork provider, formatting
   ├─ scenarios.ts             button runner: faults on the mainnet world / viem test actions against anvil
   ├─ useOracle.ts             React hook over the provider
   ├─ App.tsx                  layout
   ├─ abi/*.json               copies of the frozen /abi (never edit here — re-copy from /abi)
   ├─ fork.example.json        placeholder addresses (fallback when public/fork.json is missing)
   └─ components/
      ├─ ScenarioBar.tsx       §4.2 / §5
      ├─ StatusCard.tsx        §4.3
      ├─ ScoreCard.tsx         §4.4
      ├─ SourcesTable.tsx      §4.5
      ├─ BorrowPanel.tsx       §4.6
      ├─ LegacyPanel.tsx       §4.7
      └─ EventLog.tsx          §4.8
```

Stack: React 19 + Vite + TypeScript, viem (`createPublicClient` for reads, `createTestClient` for anvil actions), hand-written CSS on Tailwind's base.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Red banner: *Live RPC failed* | anvil not running, or no `public/fork.json` (placeholder addresses) | start anvil; re-run Deploy + Spell; re-copy `fork.json` |
| Deploy fails `nonce too low` | a previous deploy was interrupted mid-broadcast | stop anvil, start a fresh fork, deploy again (with `--slow`) and let it finish |
| Deploy never finishes; `cast rpc txpool_status` shows `queued` > 0 | burst-sent txs stuck in anvil's mempool | kill forge; `cast rpc anvil_dropAllTransactions`; re-send the stuck calls listed in `contracts/broadcast/Deploy.s.sol/31337/run-latest.json` with `cast send` (for us: the last three `rely(AdminSafe)`), or restart the fork and deploy with `--slow` |
| Page says **Mainnet data** after `pnpm dev --mode live` | you opened the old server on :5173; the live one moved to :5174 | use the URL Vite printed |
| First `forge` command seems to hang | first-time solc 0.8.24 download, or the first deploy pulling fork state | wait; later runs are fast |
| Button status: `SmartOSM.poke reverted` | poke called before `zzz + hop` | shouldn't happen (the runner warps first) — press **Reset** and retry, report it |
| Score drops to 0 after **Warp +1h** / poke is `PokeSkipped` | mocks went stale (1h maxAge) | use the dashboard's buttons, which refresh them; don't warp with raw `cast` |
| State stays YELLOW/RED after recovering | hysteresis: upgrades need 3 healthy syncs ≥ 10 min apart | press **Warp +1h** a few times |
| Buttons fail with `NotAuthorized` on `setPrice` | the MockSources' ward isn't anvil account #0 (someone deployed with another key, or wired a real PythSource via `PYTH_SOURCE`) | redeploy with the documented command; the Pyth-mock buttons only work while Pyth is a MockSource |
| Upstream RPC errors / 429s | rate limit on the keyless RPC | restart anvil with `--fork-url https://eth.drpc.org` (or a keyed Alchemy/Infura URL) |

---

## 10. Verified end to end (Sep 19, real mainnet fork)

Anvil fork of Ethereum mainnet at block 26,011,000 → `Deploy.s.sol` → `Spell.s.sol` as the impersonated Admin Safe → on-chain check: `Spotter.ilks(paxg).pip` = SmartOSM, SmartOSM `LIVE`, 4 sources, controller GREEN / score 100. Then every button, both headless (the dashboard's own `data.ts` + `scenarios.ts` driven from Node) and clicked in Chrome against `pnpm dev --mode live`:

| Button | State | Score | Line / headroom | Legacy column | Matches |
|---|---|---|---|---|---|
| (post-spell) | GREEN | 100 | $293,029 / $250,000 | $4,372.48 VALID | DEMO_SCRIPT §D "GREEN, score 100, line $293,029" |
| S1 | **RED**, OSM STALE, `PokeSkipped NO_QUORUM` | 0 (no quorum) | $43,029 / $0 | $4,372.48 **VALID at 27.8h** → S1 banner | ✓ |
| S2 | **RED** (live.lo < OSM − 1.5%) | 71 (Chainlink ✗) | $43,029 / $0 | unchanged | ✓ |
| S3 | **YELLOW** (Pyth ✗ at $43,724.78) | 71 | $93,029 / $50,000 | **$43,724.78** VALID → S3 banner | ✓ |
| S4 | GREEN + **🛡️ guard ON**, OSM `cur` **$3,716.61** vs live $4,372 | 100 | $293,029 | unchanged | DEMO_SCRIPT §D "$3,716 while true price $4,372" |
| Poke / Sync / Warp +1h | GREEN, OSM age back to 0 | 100 | $293,029 | — | ✓ |
| Reset (after each) | back to post-spell exactly | 100 | $293,029 | $4,372.48 | ✓ |

In every row the UI's recomputed `⌊100 · Wq · Wd · Wf⌋` equalled the contract's `read().score`.

What the live run caught that mock mode couldn't (all fixed):
1. **Stale head block** — viem caches `getBlockNumber()` for ~4s, so right after a button the ages and the event-log range were computed against the previous block (S1's sources still showed their pre-warp ages). Now read with `cacheTime: 0`.
2. **S3 had no legacy contrast** — the mocks don't feed the legacy stack, so the killer-moment banner never fired. Now the legacy side gets the `Baseline_S3` end state (§5, S3).
3. **Unreadable event log** — raw WAD/RAD integers and bytes32 ilks. Now formatted.
4. **"1.0d" maxAge** for Chainlink hid that it's deliberately 25h. Now shown in hours.
5. **Stale feeds labelled "outlier"**, and Wf claiming "freshest inlier 0s old" with no inliers. Now "not checked" / "no inliers to measure".
6. Buttons' accessible name was their tooltip, not their label. Fixed with `aria-label`.

---

## 11. Honest limitations
- **Mock hysteresis is simplified** — the mock upgrades immediately; the real controller needs 3 healthy syncs. Live mode is the source of truth.
- **The S1/S3 dollar figures in the banners are constants** from the baseline fork tests, not recomputed per click. They're real measurements, but of the legacy system in a separate test, not of the button you just pressed.
- **One ilk.** The UI is hard-wired to `paxg`. Multi-ilk is a list + a selector; not needed for the demo.
- **Event timestamps** in live mode are the chain's *current* time at the read, not each event's own block time (all events in one poll share a timestamp).
- **Live S3's legacy side is injected**, not attacked: the button writes `Baseline_S3`'s end state into the legacy OSM's storage (§5). The attack itself, end to end on the legacy contracts, is Kapilan's `Baseline_S3` fork test.
- **Pyth / RedStone / DEX TWAP are stand-ins** on the fork (ADR-003). The aggregator treats them exactly like real adapters behind the same `IPriceSource` interface; Varun's real `PythSource` can be wired in with `PYTH_SOURCE=` at deploy time.
