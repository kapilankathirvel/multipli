# Contracts Specification

Build contracts exactly to this spec. If you must deviate, add an ADR in `DECISIONS.md` and update this file.

- Solidity `0.8.24`. Maker units: **WAD 1e18, RAY 1e27, RAD 1e45**. Prices = USD per token, WAD.
- Auth pattern on every new contract: `mapping(address=>uint256) public wards; rely/deny; modifier auth`.
- Custom errors, events on every state change.

```
contracts/src/
├─ interfaces/  IVat.sol ISpotter.sol IDog.sol IPip.sol IGemJoin.sol IChainlinkFeed.sol IPriceSource.sol
├─ sources/     ChainlinkSource.sol  MockSource.sol  (PythSource.sol: stretch)
├─ OracleGuardAggregator.sol
├─ SmartOSM.sol
├─ RiskController.sol
├─ SessionCalendar.sol
└─ executors/   LineExecutor.sol  HoleExecutor.sol
```

---

## 0. Interfaces to the existing Maker core (minimal)

```solidity
interface IVat {
    function ilks(bytes32) external view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
    function urns(bytes32, address) external view returns (uint256 ink, uint256 art);
    function rwaUSD(address) external view returns (uint256);   // NOTE: Maker `dai(address)` is renamed `rwaUSD(address)` in this fork (verified ABI)
    function Line() external view returns (uint256);
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external;
    function file(bytes32 ilk, bytes32 what, uint256 data) external;   // "line", "spot", "dust"
    function slip(bytes32 ilk, address usr, int256 wad) external;      // auth
    function hope(address) external;
    function rely(address) external;
    function wards(address) external view returns (uint256);
}
interface ISpotter {
    function ilks(bytes32) external view returns (address pip, uint256 mat);
    function par() external view returns (uint256);
    function poke(bytes32 ilk) external;
    function file(bytes32 ilk, bytes32 what, address pip_) external;   // what = "pip"
}
interface IDog {
    function ilks(bytes32) external view returns (address clip, uint256 chop, uint256 hole, uint256 dirt);
    function Hole() external view returns (uint256);
    function Dirt() external view returns (uint256);
    function bark(bytes32 ilk, address urn, address kpr) external returns (uint256 id);
    function file(bytes32 ilk, bytes32 what, uint256 data) external;   // what = "hole" (RAD)
    function rely(address) external;
}
interface IPip { function peek() external view returns (bytes32, bool); function read() external view returns (bytes32); }
interface IGemJoin { function join(address usr, uint256 wad) external; function exit(address usr, uint256 wad) external; }
interface IChainlinkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
    function aggregator() external view returns (address);
}
interface IChainlinkAggregatorBounds { function minAnswer() external view returns (int192); function maxAnswer() external view returns (int192); }
```

Revert strings to assert in tests: `"Vat/ceiling-exceeded"`, `"Vat/not-safe"`, `"Dog/liquidation-limit-hit"`, `"Dog/not-unsafe"`, `"OSM/not-passed"`.

---

## 1. `IPriceSource` + sources

```solidity
struct Observation { uint256 price; uint256 conf; uint64 updatedAt; bool ok; }  // price & conf in WAD
interface IPriceSource {
    function observe() external view returns (Observation memory);
    function sourceName() external view returns (string memory);
}
```
**Rule: `observe()` never reverts.**

### 1.1 `ChainlinkSource`
- Constructor: `(address feed, uint256 maxAge, string name)`. Caches `decimals`. Tries to read `aggregator().minAnswer/maxAnswer` (in `try/catch`; if unavailable, bounds are disabled).
- `observe()`: `try feed.latestRoundData()` then:
  - `ok=false` if `answer <= 0`, `updatedAt == 0`, `updatedAt > block.timestamp`, **`answer <= minAnswer || answer >= maxAnswer`** (clamp, V7).
  - `price = answer * 1e18 / 10**dec`; `conf = 0`; `updatedAt` passed through.
  - Staleness is **not** decided here; the aggregator decides using `maxAge` (exposed as `maxAge()`), so the UI can still show the stale value.

### 1.2 `MockSource` (stand-in for Pyth / RedStone / Uniswap TWAP in the demo)
- Storage: `Observation obs; string name; uint256 maxAge;`
- `auth` functions: `set(uint256 price, uint256 conf, uint64 updatedAt, bool ok)`, `setPrice(uint256 price)` (sets `updatedAt = now`, `ok = true`), `setOk(bool)`.
- `observe()` returns `obs`.
- Events: `MockSet(price, conf, updatedAt, ok)`.

### 1.3 `PythSource` (stretch)
Wraps `IPyth.getPriceUnsafe(id)`, converts `expo` to WAD, `conf` to WAD, `publishTime` as `updatedAt`. `ok=false` if `conf/price > maxConfBps`.

---

## 2. `OracleGuardAggregator` (one instance per asset)

**Storage**
```solidity
struct SourceCfg { IPriceSource src; uint16 weight; uint32 maxAge; }
SourceCfg[] public sources;          // ≤ 5
uint16  public quorumMin;            // e.g. 2   (hard floor: fewer fresh inliers → score 0)
uint16  public dMaxBps;              // dispersion at which W_d hits 0, e.g. 200 (2%)
uint16  public madK;                 // outlier multiplier, e.g. 3
uint16  public madFloorBps;          // min MAD as bps of median, e.g. 10 (0.1%)
```
**Admin (auth):** `addSource(IPriceSource, uint16 weight, uint32 maxAge)`, `removeSource(uint256 idx)`, `file(bytes32 what, uint256 data)` for the params above. Events `SourceAdded/SourceRemoved/File`.

**Main view**
```solidity
struct Reading {
    uint256 mid;        // weighted median of inliers (WAD)
    uint256 lo;         // min inlier price
    uint256 hi;         // max inlier price
    uint16  score;      // 0..100
    uint8   nFresh;     // ok && fresh
    uint8   nInliers;
    uint64  freshestAge;// seconds, age of the freshest inlier
    bool    ok;         // nInliers >= quorumMin
}
function read() external view returns (Reading memory);
function observations() external view returns (Observation[] memory obs, bool[] memory fresh, bool[] memory inlier); // for UI
```
**Algorithm (`read`)**
1. For each source, call `observe()`. `fresh = ok && now - updatedAt <= maxAge`.
2. `m0` = weighted median of fresh prices (sort ascending, first price where cumulative weight ≥ total/2).
3. `MAD` = plain median of `|p - m0|`; `thr = madK * max(MAD, m0 * madFloorBps / 1e4)`. Inlier if `|p - m0| <= thr`.
4. `mid` = weighted median of inliers; `lo/hi` = min/max inlier; `d = (hi - lo) * 1e4 / mid` (bps).
5. Score (integer maths, 0–100):
   - `Wq = inlierWeight * 1e4 / totalWeight()` (weight-based, review.md §R1; `totalWeight()` is a public view)
   - `Wd = d >= dMaxBps ? 0 : 1e4 - d * 1e4 / dMaxBps`
   - `Wf`: `a` = age of the **freshest** inlier, `M` = that source's maxAge. `Wf = a <= M/2 ? 1e4 : 1e4 - min(1e4, (a - M/2) * 1e4 / (M/2))` (grace band then linear). **Do not use the oldest age**: at the fork block Chainlink is ≈16.5h old, and an oldest-based Wf would boot the demo into RED.
   - `score = 100 * Wq * Wd * Wf / 1e12`
   - Override: `nInliers < quorumMin` gives `score = 0, ok = false` (mid/lo/hi = last computed or 0; consumers must check `ok`).
6. Gas budget: ≤ 150k with 4 sources.

**Tests:** at `FORK_BLOCK` with real Chainlink + 3 fresh mocks, score ≥ 80 (GREEN baseline); single outlier ignored; 2-of-4 stale → score drops but `ok`; all stale → `ok=false`; fuzz: `lo <= mid <= hi`, `score <= 100`, never reverts with ≤5 random sources.

---

## 3. `SmartOSM` (drop-in replacement for Maker OSM)

**Keeps the Maker OSM ABI exactly:** `wards, rely, deny, stopped, stop, start, src, hop, zzz, bud, kiss(address), kiss(address[]), diss(address), diss(address[]), change(address), step(uint16), void(), pass(), poke(), peek(), peep(), read()`.
Here `src` is the `OracleGuardAggregator` address.

**Extra storage**
```solidity
ISpotter public immutable spotter;
bytes32  public immutable ilk;
uint64   public lastGoodAt;       // last successful poke
uint32   public staleLimit;       // e.g. 2 * hop   (status only)
uint16   public jumpLimitBps;     // e.g. 500 (5%)
uint16   public jumpMinScore;     // score needed to accept a jump immediately, e.g. 80
Feed     public pending;          // quarantined candidate
uint64   public pendingSince;
Reading  public lastReading;      // snapshot at last poke (for UI/controller)
enum Status { UNINIT, LIVE, STALE, QUARANTINED, STOPPED }
```

**Functions**
- `init(uint256 priceWad)` (auth, once): sets `cur = nxt = Feed(price,1)`, `lastGoodAt = now`, `zzz = prev(now)`. Used by the spell to prime from the legacy OSM (no discontinuity). Emits `Init`.
- `poke()` (permissionless, `stoppable`):
  1. `require(pass(), "OSM/not-passed")` (same string as Maker).
  2. `Reading r = aggregator.read(); lastReading = r;`
  3. If `!r.ok`: emit `PokeSkipped(reason=NO_QUORUM, r.score)` and **return without changing cur/nxt** (legacy behaviour, but now *observable*: `age()` keeps growing and `status()` becomes STALE).
  4. Jump check vs `nxt` (**asymmetric, ADR-011**: only `r.mid > nxt` with jump > jumpLimitBps and score < jumpMinScore is quarantined; on quarantine `cur = nxt` still advances; a later hop still showing a rise confirms it). Original text for reference: `jump = |r.mid - nxt| * 1e4 / nxt`.
     - If `jump > jumpLimitBps && r.score < jumpMinScore`:
       - if `pending.has == 1` and `|r.mid - pending| <= jumpLimitBps` (re-confirmed on a later hop), then accept.
       - else `pending = r.mid; pendingSince = now;` emit `Quarantined(r.mid, nxt, r.score)`; `zzz = prev(now)`; return.
  5. Accept: `cur = nxt; nxt = Feed(r.mid, 1); pending = 0; zzz = prev(now); lastGoodAt = now;` emit `Poke(cur, zzz)`.
  6. `try spotter.poke(ilk) {} catch {}` (atomic propagation, V12). SmartOSM must be `bud`-kissed for itself? No: Spotter reads `peek()`, so **Spotter must be kissed**.
- `peek()` (toll) returns `(cur.val, cur.has == 1)`. **Invariant: after `init`, `has == true` and `val > 0`.**
- `peep()`, `read()`: as in Maker.
- `void()`: **reverts `VoidDisabled()`** (ABI kept; zero-price trap removed; ADR-004).
- `change(address)`: auth (production: timelock only).
- Views: `age() = now - lastGoodAt`; `status()`: STOPPED if stopped; QUARANTINED if `pending.has`; STALE if `age() > staleLimit`; else LIVE. `price() returns (uint256 cur, uint256 nxt, uint64 lastGoodAt)`.
- Events: `Init, Poke(bytes32 val, uint256 age), PokeSkipped(uint8 reason, uint16 score), Quarantined(uint256 candidate, uint256 nxt, uint16 score), Rely, Deny, Kiss, Diss, Stop, Start, Change, Step`.
- **Bud note:** `peek/peep/read` are `toll`-gated like Maker. Kiss Spotter, Clipper, End, RiskController, and (for the UI) a view helper or an EOA via `kiss`.

**Tests:** ABI compatibility (Spotter.poke works with SmartOSM as pip); stale sources mean `status()==STALE` while `peek` stays valid; manipulated single source is ignored; low-score jump is quarantined then confirmed next hop; full-quorum 15% crash is accepted immediately; `void()` reverts.

---

## 4. Executors (bounded authority)

### 4.1 `LineExecutor`
```solidity
IVat public immutable vat;
mapping(bytes32 => uint256) public cap;   // RAD, set by auth (governance)
function setCap(bytes32 ilk, uint256 capRad) external auth;
function setLine(bytes32 ilk, uint256 lineRad) external auth;   // only RiskController is ward
// require(lineRad <= cap[ilk]) else revert AboveCap(); vat.file(ilk, "line", lineRad); emit LineSet
```
Requires `vat.rely(LineExecutor)` (spell).

### 4.2 `HoleExecutor`
Same shape: `cap[ilk]` (RAD), `setHole(ilk, holeRad)` calls `dog.file(ilk, "hole", holeRad)`. Requires `dog.rely(HoleExecutor)`.

---

## 5. `SessionCalendar`
```solidity
mapping(bytes32 => uint256) public weekMask;   // bit h (0..167) = market open during hour-of-week h (UTC, Monday 00:00 = h0)
mapping(bytes32 => mapping(uint256 => bool)) public holiday; // day index = ts / 1 days
mapping(bytes32 => bool) public alwaysOpen;    // e.g. PAXG treated as always open in MVP
function setWeekMask(bytes32 asset, uint256 mask) external auth;
function setHoliday(bytes32 asset, uint256 dayIdx, bool closed) external auth;
function setAlwaysOpen(bytes32 asset, bool) external auth;
function isOpen(bytes32 asset, uint256 ts) public view returns (bool);
// hourOfWeek = ((ts / 3600) + 72) % 168   // Unix epoch was a Thursday → +72h aligns Monday 00:00
```
Helper for tests: NYSE-ish mask = Mon–Fri 14:00–21:00 UTC.

---

## 6. `RiskController`

**Per-ilk config (auth `file`)**
```solidity
struct IlkCfg {
    OracleGuardAggregator agg;
    SmartOSM   osm;
    bytes32    sessionAsset;
    uint256    lineCapRad;      // GREEN line (e.g. 1,000,000 RAD = governance value)
    uint256    yellowGapRad;    // YELLOW headroom above current debt (e.g. 50,000 RAD)
    uint256    holeCapRad;      // normal Dog.hole (e.g. 400,000 RAD)
    uint16     greenScore;      // 80
    uint16     yellowScore;     // 50
    uint16     epsBps;          // RED if live.lo < osmCur*(1-eps), e.g. 150 (1.5%)
    uint16     epsLiqBps;       // guard if live.hi*(1-epsLiq) > osmCur, e.g. 300 (3%)
    uint32     upgradeInterval; // min seconds between counted healthy syncs, e.g. 600
    uint8      kUp;             // healthy syncs needed to upgrade, e.g. 3
    uint32     guardMaxDuration;// e.g. 6 hours
}
enum State { GREEN, YELLOW, RED }
mapping(bytes32 => IlkCfg) public cfg;
mapping(bytes32 => State)  public state;
mapping(bytes32 => uint8)  public healthyStreak;
mapping(bytes32 => uint64) public lastHealthyCount;
mapping(bytes32 => bool)   public guardActive;
mapping(bytes32 => uint64) public guardSince;
LineExecutor public lineExec; HoleExecutor public holeExec; SessionCalendar public calendar; IVat public vat; IDog public dog;
```

**`sync(bytes32 ilk)`**, permissionless and idempotent:
1. `Reading r = agg.read(); (uint256 osmCur,,) = osm.price(); SmartOSM.Status s = osm.status(); bool open = calendar.isOpen(sessionAsset, now);`
2. **Target state**
   - RED if `!r.ok` or `r.score < yellowScore` or `s == STALE` or `s == QUARANTINED` or `r.lo * 1e4 < osmCur * (1e4 - epsBps)`.
   - else YELLOW if `r.score < greenScore` or `!open`.
   - else GREEN.
3. **Hysteresis:** if target is worse than current, apply now and reset the streak. If better, increment `healthyStreak` only if `now >= lastHealthyCount + upgradeInterval`; upgrade one level when `healthyStreak >= kUp` (prevents same-block spam upgrades).
4. **Apply line:** `debt = Art * rate` (RAD). *(Implemented per review.md §R3.)*
   - GREEN: `line = min(debt + greenGapRad, lineCapRad)`, refilled at most once per `refillInterval` (**rate limit**: new debt ≤ greenGap per hour even for undetected failures)
   - YELLOW: `line = min(debt_at_entry + yellowGapRad, lineCapRad)`, anchored on entry and **never raised while YELLOW**
   - RED: `line = debt`, so any `dart > 0` reverts `Vat/ceiling-exceeded`; repay (`dart < 0`) always passes.
   - Only call the executor if the value changed.
   - Note: Maker's `Clipper.getFeedPrice()` resolves the pip via `spotter.ilks(ilk)` dynamically, so the `Spotter.file` swap is picked up by the Clipper with no change.
5. **Liquidation guard:**
   - Condition `G = r.ok && r.score >= greenScore && r.hi * (1e4 - epsLiqBps) > osmCur * 1e4` (live market well above the delayed OSM, with agreement).
   - If `G && !guardActive`: `holeExec.setHole(ilk, 0)` (Dog.bark needs `hole > dirt`, so 0 always blocks; don't read a moving `dirt`), `guardActive = true`, `guardSince = now`, emit `GuardOn`.
   - If `guardActive && (!G || now - guardSince > guardMaxDuration)`: `holeExec.setHole(ilk, holeCapRad)`, `guardActive = false`, emit `GuardOff(expired)`. After an expiry the guard is **latched**: it won't re-arm until `G` has been false once (so liquidations can never be paused indefinitely).
6. Emit `Synced(ilk, state, r.score, r.mid, osmCur, lineRad, guardActive)` and `StateChanged(ilk, from, to)` on change.

**Views for UI:** `status(ilk) returns (State, uint16 score, bool guard, uint256 lineRad, uint256 debtRad)`.

**Tests:** see `TESTING.md`. Key: RED blocks mint *and* repay still works; YELLOW limits mint to the gap; guard blocks `bark` with `Dog/liquidation-limit-hit` and auto-expires; upgrade needs `kUp` spaced syncs.

---

## 7. Scripts

- `script/Deploy.s.sol`: deploys sources (ChainlinkSource real + 3 MockSources primed to the Chainlink price), Aggregator, SmartOSM, SessionCalendar, executors, RiskController. Writes addresses to `deployments/fork.json` (the dashboard reads this).
- `script/Spell.s.sol`: run as the impersonated Admin Safe (`vm.startPrank(ADMIN_SAFE)` in tests; `anvil_impersonateAccount` for the live demo):
  1. `smartOsm.init(legacyPrice)` where `legacyPrice` = the legacy OSM `cur` (read via `vm.load` or a kissed reader).
  2. `smartOsm.kiss([SPOTTER, CLIPPER, END, controller])`
  3. `spotter.file(ILK, "pip", smartOsm)`
  4. `vat.rely(lineExec)`; `dog.rely(holeExec)`; `lineExec.setCap(ILK, 1_000_000 RAD)`; `holeExec.setCap(ILK, 400_000 RAD)`
  5. `spotter.poke(ILK)`; `controller.sync(ILK)`
- `script/Scenarios.s.sol` (or TS in `keeper/`): helpers to set mock prices, warp time, and poke. Used by the dashboard's scenario buttons.

**Reading the legacy OSM `cur` (verified storage layout):** slot 0 `wards`, 1 `stopped`, 2 `src|hop|zzz` (packed), **3 = `cur`**, **4 = `nxt`**. `val` is the low 128 bits and `has` the high 128. Verified on 2026-09-19: slot 3 → val 4372.478 PAXG/USD, has 1.
- In tests: `uint256 v = uint256(vm.load(LEGACY_OSM, bytes32(uint256(3)))); uint256 price = uint128(v);`
- In the live spell (a broadcast has one sender, so you can't prank Spotter): read off-chain and pass it via env:
  `LEGACY_PRICE=$(cast to-dec $(cast storage 0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a 3 --rpc-url $RPC))` and take the low 128 bits (do the masking in the script with `vm.envUint` + `uint128(...)`).
