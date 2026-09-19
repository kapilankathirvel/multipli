# OracleGuard: what is implemented, explained file by file

> Read `SOLUTION_EXPLAINED.md` first (the big picture). This file explains **every piece of code built so far**, how it works, how it's tested, and the numbers behind it, so you can answer code-level questions.
> State as of this writing: **91 tests, all passing** (`cd contracts && forge test`).

---

## 0. The toolbox (what the tools are)
| Tool | What it is | Why we use it |
|---|---|---|
| **Solidity 0.8.24** | Smart-contract language | Our contracts. (Multipli's core is 0.6.12; we only talk to it through small interfaces.) |
| **Foundry** (`forge`, `anvil`, `cast`) | Ethereum dev toolkit | `forge` compiles and tests, `anvil` runs a local chain, `cast` makes calls from the terminal |
| **Mainnet fork** | A local copy of the real Ethereum state at block **26,011,000** | Lets us attack and fix the **real deployed rwaUSD contracts** without touching the real chain |
| **Archive RPC** (`mainnet.gateway.tenderly.co`) | Serves historical chain state | The fork is pinned to a past block, which normal public RPCs refuse to serve |

### Units (Maker's fixed-point numbers; they come up constantly)
| Name | Value | Used for | Example |
|---|---|---|---|
| **WAD** | 1e18 | token amounts, prices | $4,372.47 = `4372478143390000000000` |
| **RAY** | 1e27 | ratios, `spot`, `rate`, `mat` | `mat` 1.40 = `1.4e27` |
| **RAD** | 1e45 | debt (WAD × RAY) | debt ceiling $1M = `1_000_000 * 1e45` |
| **bps** | 1/10,000 | our thresholds | 150 bps = 1.5% |

### Test cheatcodes you'll see (Foundry "vm" tricks)
| Cheatcode | Meaning |
|---|---|
| `vm.createSelectFork(rpc, block)` | Start the test on a copy of mainnet at that block |
| `vm.prank(addr)` / `startPrank` | Pretend the next call(s) come from `addr` (e.g. the Admin Safe) |
| `vm.warp(t)` | Jump the clock to time `t` (e.g. "7 days later") |
| `deal(token, who, amt)` | Give someone tokens (e.g. PAXG) |
| `vm.mockCall(addr, call, result)` | Make a contract return a fake answer (e.g. Chainlink reports −15%) |
| `vm.load(addr, slot)` | Read raw storage (how we read the legacy OSM's price without whitelisting) |
| `vm.expectRevert("msg")` | The next call must fail with this message |

---

## 1. Repo map
```
contracts/
├─ src/
│  ├─ Constants.sol                     verified mainnet addresses + units
│  ├─ interfaces/IMaker.sol             how we talk to Vat, Spotter, Dog, OSM, Chainlink...
│  ├─ interfaces/IPriceSource.sol       FROZEN: source / executor / calendar interfaces (team boundary)
│  ├─ interfaces/IOracleGuard.sol       FROZEN: Aggregator / SmartOSM / RiskController / MockSource APIs
│  ├─ utils/Auth.sol                    Maker-style admin rights (wards/rely/deny)
│  ├─ sources/ChainlinkSource.sol       wraps the real Chainlink feed
│  ├─ sources/MockSource.sol            controllable stand-in for Pyth / RedStone / DEX
│  ├─ OracleGuardAggregator.sol         median + outliers + confidence score
│  ├─ SmartOSM.sol                      drop-in OSM replacement
│  ├─ RiskController.sol                GREEN / YELLOW / RED / guard
│  └─ executors/{Line,Hole}Executor.sol the only contracts allowed to touch Vat.line / Dog.hole
├─ script/
│  ├─ DeployLib.sol                     shared install logic (used by scripts AND tests)
│  ├─ Deploy.s.sol                      deploy + write deployments/fork.json
│  └─ Spell.s.sol                       governance spell (as the Admin Safe) + rollback
└─ test/
   ├─ fork/Harness.t.sol                the fork matches our verified facts
   ├─ fork/Baseline.t.sol               attacks that SUCCEED on legacy rwaUSD (S1, S3, S4)
   ├─ fork/SourcesExecutors.t.sol       real Chainlink read; executors move the real Vat/Dog
   ├─ fork/Aggregator.fork.t.sol        demo config starts GREEN on the real feed
   ├─ fork/SmartOSM.fork.t.sol          real Spotter/Vat/Dog/Clipper run on SmartOSM
   ├─ fork/OracleGuard.t.sol            THE PROOF: same attacks fail after the spell
   ├─ unit/*.t.sol                      logic tests without a fork (fast)
   └─ mocks/*                           EvilFeed, MockChainlinkFeed, MockSpotter, MockVat/Dog/Calendar, RevertingSource
abi/*.json                              exported frozen ABIs (for the dashboard)
deployments/fork.example.json           frozen address-file schema
```

---

## 2. Phase 1: proving the problem (`test/fork/Baseline.t.sol`)

**`ForkBase.sol`** (shared helpers):
- `legacyCur()` reads the legacy OSM price straight from storage **slot 3**: low 128 bits = price, high bits = "has".
- `pokeLegacy()` warps to the next hour and pokes the legacy OSM + Spotter.
- `openVault(who, paxg, dai)` = `deal` PAXG → `join` → `frob`. (`frob` is Maker's "change my vault" function.)
- `maxDrawWad(who)` = the most rwaUSD a vault can still borrow = `ink × spot − art × rate`.

| Test | Steps | Result (printed) |
|---|---|---|
| **S1 stale forever** | warp 7 days → the adapter says invalid → poke the OSM (does nothing) → it still says valid → borrow | Chainlink round **186h** old, OSM price still valid at **$4,372**, **31,231 rwaUSD** minted |
| **S3 feed swap** | Safe calls `adapter.setPriceFeed(EvilFeed 10×)` → 2 hourly pokes → borrow max with 10 PAXG | **$312,319** minted vs **$43,724** collateral → **$268,595 bad debt** |
| **S4 captured wick** | victim vault at 145% → Chainlink −15% at poke time → market recovers → OSM serves the dip for 1h → `dog.bark` | healthy vault **liquidated**, 10 PAXG seized |

**S3 math:**
- 10 PAXG × $4,372.4 × 10 (fake) = $437,240 of fake value.
- ÷ 1.4 = **$312,319** borrowable.
- Real value $43,724 → $268,595 can never be repaid by the collateral.

**One surprise found here:** this Vat renames Maker's `dai(address)` to **`rwaUSD(address)`** (the internal balance). Recorded in `docs/ONCHAIN_FACTS.md`.

---

## 3. The contracts, one by one

### 3.1 `utils/Auth.sol`: admin rights
`wards[address] = 1` means admin. `rely(x)` / `deny(x)` add or remove admins; the `auth` modifier guards admin functions. The deployer is admin at creation. Same pattern as Maker, so Multipli engineers recognise it instantly.

### 3.2 `sources/ChainlinkSource.sol`
- **Job:** turn Chainlink's `latestRoundData()` into our `Observation {price, conf, updatedAt, ok}`.
- **Never reverts:** the whole call is in `try/catch`; any failure → `ok = false`.
- `ok = false` if:
  - the price is ≤ 0,
  - the timestamp is 0 or in the future,
  - the price is absurd (would overflow),
  - **or the price sits exactly on Chainlink's min/max "circuit breaker" bound**. That's the LUNA 2022 failure: the feed kept reporting the floor price while the real price was far lower.
- Converts 8 decimals → 18 (WAD).
- **Does NOT judge staleness.** The aggregator does, so the UI can still display a stale value.
- *Bug our fuzz test found:* a gigantic Chainlink answer made `answer × 1e18` overflow and revert → fixed with a guard.

### 3.3 `sources/MockSource.sol`
- A source whose price we set: `setPrice(p)` (stamps "now", ok = true), `set(price, conf, time, ok)`, `setOk(bool)`. Admin-only.
- Stands in for Pyth / RedStone / the DEX TWAP so the demo can inject attacks (ADR-003).

### 3.4 `OracleGuardAggregator.sol`: the brain
**Configuration:**
- A list of sources, each with `weight` and `maxAge`. The demo uses Chainlink 2 / 25h, Pyth 2 / 1h, RedStone 2 / 1h, DEX 1 / 1h.
- Parameters: `quorumMin = 2`, `dMaxBps = 200` (2%), `madK = 3`, `madFloorBps = 10` (0.1%).

**`read()` step by step:**
1. **Observe** every source (`try/catch`). A source is **fresh** if `ok`, 0 < price ≤ 1e36, and age ≤ its `maxAge`.
2. **Sort** fresh prices (insertion sort; ≤ 8 sources, so cheap).
3. **Weighted median `m0`**: walk the sorted list adding weights until you pass half of the total weight.
4. **Outlier filter (MAD):**
   - deviation = |price − m0|; MAD = median of the deviations;
   - threshold = 3 × max(MAD, 0.1% of m0);
   - inside the threshold = **inlier**.
   - The 0.1% floor matters: when sources agree exactly, MAD = 0, and without the floor any tiny difference would count as an outlier.
5. **mid** = weighted median of the inliers; **lo / hi** = lowest / highest inlier.
6. **Score:**
   - `Wq` = inlier weight / total weight.
   - `Wd` = 1 − spread / 2% (spread = (hi − lo) / mid), floored at 0.
   - `Wf` = 1 if the freshest inlier is ≤ half its maxAge old, then falls linearly to 0.
   - `score = ⌊100 × Wq × Wd × Wf⌋` (integer maths in bps).
   - If fewer than 2 inliers → `ok = false`, score 0.

**Worked examples (all tested, weights 2/2/2/1):**
| Situation | Calculation | Score |
|---|---|---|
| all agree | 7/7 × 1 × 1 | **100** |
| DEX reports 10× | DEX is an outlier → 6/7 | **85** (GREEN) |
| Chainlink stale | 5/7 | **71** (YELLOW) |
| 0.5% split between sources | 1 × (1 − 0.5/2) | **75** |
| two majors +20% | spread 16.7% ≥ 2% → Wd = 0 | **0** (RED); the mid follows the wrong majority, which is the correlated-failure limit |

**Engineering notes:**
- "Stack too deep" compiler errors forced splitting the logic into small helpers (`_observeAll`, `_inliers`, `_freshest`, `_score`) instead of using the slow `via-ir` compiler mode.
- `read()` costs ≈105k gas.
- `observations()` returns per-source detail for the dashboard; `totalWeight()` returns 7.

### 3.5 `SmartOSM.sol`: the safe delay (drop-in OSM)
- **Same interface as Maker's OSM:** `peek` (reads `cur`), `peep` (reads `nxt`), `read`, `poke`, `pass`, `hop` (3600s), `zzz` (last update boundary), `kiss/diss` (reader whitelist), `stop/start`, `change`, `step`, `void`. So the real Spotter, Clipper, and End use it without any change.
- Stores `cur` (the price in use) and `nxt` (next hour's price).

**`init(price)`:** sets `cur = nxt = price`. The spell primes it with the legacy OSM's price, so nothing jumps at the swap.

**`poke()`** (anyone can call it, once per hour):
1. `require(pass())`: an hour has passed since the last update.
2. Ask the aggregator for a `Reading`.
3. **No quorum** (`!ok`) → emit `PokeSkipped` and **return**. `cur`/`nxt` are unchanged, and `zzz` is NOT advanced, so it can be retried as soon as sources recover. `age()` keeps growing → `status() = STALE`.
4. **Jump check:** if the new price differs from `nxt` by **> 5%** AND the score is **< 80**, it's suspicious:
   - if an earlier quarantined value is within 5% of this one → confirmed, accept;
   - otherwise → store it as `pending`, consume this hour, emit `Quarantined`, return. It needs a later hour to confirm it.
   - A big move **with** score ≥ 80 (everyone agrees, e.g. a real crash) is accepted immediately.
5. **Accept:** `cur = nxt`, `nxt = new price`, update `lastGoodAt`, emit `Poke`.
6. `try spotter.poke(ilk)`: the Vat's price updates in the same transaction.

**Other pieces:**
- `status()`: UNINIT(0) / LIVE(1) / STALE(2, age > 2h) / QUARANTINED(3) / STOPPED(4).
- `age()`, `price()`, `lastReading()` are readable by anyone (the UI and the controller).
- `void()` always reverts `VoidDisabled()`: no zero-price self-destruct.
- **Zero-price invariant:** after `init`, `cur` only ever takes values from `nxt`, and `nxt` only takes `ok` medians (> 0), so `peek()` is always `(price > 0, true)`. A fuzz test (256 random runs) checks it.
- Cost: ≈247k gas per poke (includes the aggregator + Spotter update).

### 3.6 `executors/LineExecutor.sol` and `HoleExecutor.sol`: bounded power
- LineExecutor is the **only** OracleGuard contract with admin rights on the Vat, and it can call exactly `vat.file(ilk, "line", x)`, with `x ≤ cap[ilk]`, only when called by the controller.
- HoleExecutor is the same for `dog.file(ilk, "hole", x)`.
- Caps are set by governance (the real current values: line $1M, hole $400k).
- **Why:** the RiskController's logic can have bugs; these contracts make sure the worst it can do is lower a ceiling. Same idea as Maker's own `DssAutoLine` / `ClipperMom`.

### 3.7 `RiskController.sol`: the reflexes
**Per-collateral config** (`setIlk`, set by DeployLib):
- lineCap $1M, greenGap $250k, yellowGap $50k, holeCap $400k;
- scores 80 / 50; ε 1.5% (RED trigger), ε_guard 3%;
- upgrades need 3 syncs ≥ 10 min apart; guard max 6h; GREEN refill every 1h;
- sessionAsset 0 = market always open.

**`sync(ilk)`** (anyone, any time):
1. Read the live `Reading`, SmartOSM `cur`, and SmartOSM `status`.
2. **Target state:**
   - **RED** if: not ok, score < 50, SmartOSM not LIVE, or `live.lo < cur × (1 − 1.5%)` (the market is well below the delayed price, so borrowing at `cur` would be over-borrowing).
   - else **YELLOW** if score < 80 or the market is closed.
   - else **GREEN**.
3. **Hysteresis:** a worse target applies immediately. A better target moves up one level only after `kUp` = 3 healthy syncs, each ≥ 10 minutes apart (so same-block spam can't upgrade).
4. **Apply the debt ceiling** (through LineExecutor, only if it changed):
   - RED: `line = current debt`. The Vat rule is "after borrowing, total debt ≤ line", so any borrow fails `Vat/ceiling-exceeded` while repaying still works.
   - YELLOW: on entry `line = debt + $50k` (capped at lineCap). While YELLOW it's **never raised**, so repeated syncs can't leak more than $50k in total.
   - GREEN: `line = debt + $250k` (capped), refilled at most once per hour: **the rate limit**.
5. **Guard:**
   - condition = ok AND score ≥ 80 AND `live.hi × (1 − 3%) > cur` (the market is well above the delayed price).
   - ON → `hole = 0` (Dog refuses new liquidations with `Dog/liquidation-limit-hit`).
   - OFF when the condition clears, or after 6h (expired). After an expiry it's **latched**: it won't re-arm until the condition has cleared once.
6. Emit `Synced` (and `StateChanged` / `GuardOn` / `GuardOff`).

**Live number:** right after the spell, debt ≈ $43,029, so GREEN line = **$293,029**.

### 3.8 `script/DeployLib.sol`, `Deploy.s.sol`, `Spell.s.sol`
- **DeployLib.deploy(legacyPrice)** creates:
  - the sources (real Chainlink + 3 mocks primed to the Chainlink price),
  - the aggregator (weights 2/2/2/1),
  - SmartOSM (init at the legacy price; whitelist Spotter, Clipper, End),
  - the executors (caps = the real current line and hole) and the controller,
  - and gives the Safe admin rights on everything.
  - It **does not touch Maker core**.
- **DeployLib.spell(d)** (must run as the Admin Safe):
  1. `Spotter.file("paxg","pip",SmartOSM)`,
  2. `Vat.rely(LineExecutor)`,
  3. `Dog.rely(HoleExecutor)`,
  4. `Spotter.poke`,
  5. `controller.sync`.
  - These are the **only** changes to Multipli's core.
- **DeployLib.rollback(d)**: restore the ceiling and the hole, pip → legacy OSM, revoke both executors, Spotter.poke.
- **Deploy.s.sol** reads the legacy price (storage slot 3), runs deploy, and writes `deployments/fork.json` (the frozen schema the dashboard and demo script read).
- **Spell.s.sol** reads `fork.json` and runs the spell as the impersonated Safe (`--unlocked --sender <Safe>`). `--sig "rollback()"` undoes it.
- **Why a shared library:** the demo and the tests install *exactly* the same system, so "it works in tests" means "it works in the demo".
- **Smoke-tested on a live anvil fork:** pip → SmartOSM, GREEN, score 100, line $293,029, SmartOSM LIVE.

---

## 4. The proof: `test/fork/OracleGuard.t.sol`
**Setup:** fork → `DeployLib.deploy` → prank the Safe → `DeployLib.spell`.
**`_tick(price)`** = one keeper cycle: wait for the hour → refresh the 3 mock sources → `SmartOSM.poke()` → `controller.sync()`.

| Test | What it does | Assertions |
|---|---|---|
| `test_spell_installsOracleGuard` | right after the spell | pip = SmartOSM, GREEN, line = debt + $250k, hole = $400k, score 100 |
| **S1a** | warp 7 days, mocks fresh, Chainlink stale | score 71, YELLOW; borrowing $60k reverts `Vat/ceiling-exceeded`, $40k works |
| **S1b** | warp 7 days, nothing fresh | SmartOSM STALE, RED, price still > 0, borrowing reverts, **repay of $5k works** |
| **S2** | mocks −8% (Chainlink lags) | RED immediately, hole still $400k (liquidations on), borrowing reverts |
| **S3a** | the exact baseline attack (Safe swaps the legacy feed, legacy OSM pokes to 10×) | Vat price unchanged: the legacy path is no longer used |
| **S3b** | Chainlink itself mocked at 10× | median ≈ real price, score 71, YELLOW; the attacker's max borrow **$31,231 < $43,724** collateral → no bad debt |
| **S4** | 145% vault; everyone −15% at the poke; recover; poke | SmartOSM `cur` = the dip; **guard ON**; `bark` → `Dog/liquidation-limit-hit`; next hour guard OFF and `bark` → `Dog/not-unsafe` (the vault is genuinely healthy) |
| `test_spell_rollback` | Safe runs the rollback | pip = legacy OSM, executors lose Vat/Dog rights, line back to $1M |

---

## 5. All test suites at a glance (91 tests)
| Suite | # | What it proves |
|---|---|---|
| unit/Sources (Chainlink + Mock) | 10 | conversion, never reverts (fuzz), clamp detection, auth |
| unit/Aggregator + ParityVectors | 24 | median, outliers, staleness, quorum, freshness grace, weights, review.md examples exactly, fuzz |
| unit/SmartOSM | 16 | Maker semantics, stale handling, quarantine + confirmation, real crash passes, void disabled, fuzz "never 0" |
| unit/RiskController | 15 | every state, rate limit, YELLOW leak bound, RED repay, spam-proof upgrades, guard on/off/expiry/latch, no guard on real crash |
| fork/Harness | 1 | our facts match mainnet |
| fork/Baseline | 3 | the legacy exploits work |
| fork/SourcesExecutors | 5 | real feed read, executors move the real Vat/Dog, caps, auth |
| fork/Aggregator.fork | 4 | demo starts at 100; Chainlink stale → 71; market drop → mid follows the market; gas |
| fork/SmartOSM.fork | 5 | drop-in on the real Spotter/Vat/Dog/Clipper; no price jump at the swap; atomic update; never 0; real-crash liquidation works |
| fork/OracleGuard | 8 | all attacks neutralised + install + rollback |

Run everything: `cd contracts && forge test`. Verbose with logs: `forge test -vv --match-contract OracleGuardTest`.

---

## 6. End-to-end: what happens in one keeper cycle (a story)
1. It's 10:00. The keeper refreshes the Pyth / RedStone / DEX prices (in production, those networks update themselves).
2. The keeper calls **`SmartOSM.poke()`**:
   - SmartOSM asks the **Aggregator**; it reads all 4 sources, drops stale or odd ones, and returns mid $4,372, score 100.
   - No suspicious jump → `cur` = the price from 09:00, `nxt` = the 10:00 median.
   - SmartOSM calls **Spotter.poke** → the Vat's `spot` = cur / 1.4.
3. The keeper calls **`RiskController.sync("paxg")`**:
   - live score 100, SmartOSM LIVE, live price not below the delayed price → **GREEN**.
   - The hour has passed → the ceiling is refilled to debt + $250k via **LineExecutor → Vat.file("line")**.
   - The guard condition is false → nothing.
4. Users borrow / repay / deposit on the **unchanged Vat**. Liquidators use the **unchanged Dog / Clipper**, which read the price through SmartOSM.

---

## 7. Code-level questions you may get (with answers)
- **"Where exactly is the staleness fix?"**
  - `SmartOSM.poke()`: no quorum → `PokeSkipped`, and `age()` grows → `status()` = STALE.
  - `RiskController._target()`: status ≠ LIVE → RED.
- **"Show me that the price can never be zero."**
  - `SmartOSM.init` rejects 0. `poke` only writes `nxt` from an `ok` reading with `mid > 0`. `cur` only copies `nxt`. `void()` reverts.
  - Fuzz test `testFuzz_peekAlwaysValid` + fork test `test_staleSources_vatNeverSeesZero`.
- **"How does RED block minting but not repaying?"** Maker's Vat only checks the ceiling when debt increases (`dart > 0`). We set `line = current debt`. Test S1b does a repay in RED.
- **"Why is the guard `hole = 0` and not something else?"** Dog.bark requires `hole > dirt` (dirt = amount already in liquidation). 0 always fails that, even as auctions settle; any other number could leak.
- **"What stops the controller from setting a crazy ceiling?"** The LineExecutor's cap (`AboveCap`). And only the controller and the Safe are its admins.
- **"How do you read the legacy OSM price without being whitelisted?"** Storage slot 3 (verified: `cur`, low 128 bits = price). Used for priming SmartOSM and in tests.
- **"Why a library for deployment?"** So tests and the live demo run the same code path.
- **"What's MAD?"** Median Absolute Deviation: a robust spread measure. We flag anything more than 3× MAD (or 0.3% of price, whichever is bigger) from the median.
- **"What if a source contract reverts or returns garbage?"** The aggregator wraps each source in `try/catch` (test `test_revertingSource_isIgnored`), and prices above 1e36 are ignored (`test_absurdPrice_isIgnored`).
- **"What if the aggregator itself reverts?"** SmartOSM wraps it in `try/catch` → `PokeSkipped(reason 2)`.
- **"Can someone spam `sync` to get GREEN back?"** No. Upgrades need 3 syncs ≥ 10 min apart (`test_downgradeInstant_upgradeNeedsSpacedHealthySyncs`).
- **"Why does S3b still allow $31k of borrowing?"** Because that's legitimate: $43.7k of real gold at 140% supports $31k. The attack (borrowing $312k on a fake 10× price) is what's blocked.
- **"How much gas?"** Aggregator `read` ≈105k; SmartOSM `poke` ≈247k (vs ≈40k legacy). Once per hour.

---

## 8. What is NOT built yet (so you don't claim it)
- **K6b:** on-chain replay of the 9 historical incidents (next).
- **K7:** integration of Varun's SessionCalendar / PythSource + the live dashboard.
- **K8:** invariant tests.
- **Varun:** the validation study (FP/FN numbers), the calendar, the demo scripts.
- **Jeffrey:** the dashboard and deck.
- **Designed only (roadmap):** verifiable challenge window, round-TWAP poke, Proof-of-Reserve gate, timelock, fundamental gold anchor, tokenized-stock markets.
