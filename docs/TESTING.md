# Testing

## 1. Fork setup
```bash
# contracts/.env
ETH_RPC_URL=https://mainnet.gateway.tenderly.co   # keyless ARCHIVE rpc; also works: https://eth.drpc.org, https://1rpc.io/eth. publicnode does NOT (no archive)
FORK_BLOCK=26011000
```
```solidity
function setUp() public {
    vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("FORK_BLOCK"));
}
```
- **Always pin the block**, so results are deterministic and the RPC cache works (`~/.foundry/cache/rpc`).
- Public RPCs rate-limit. Use Alchemy/Infura for heavy test runs.
- Run: `forge test -vvv --match-path "test/fork/*"`; unit: `forge test --match-path "test/unit/*"`.

## 2. Fork test helpers (put in `test/fork/ForkBase.sol`)
- `openVault(address who, uint256 paxgWad, uint256 daiWad)`: `deal(PAXG, who, paxgWad)` → `approve(JOIN)` → `join.join(who, wad)` → `vat.frob(ILK, who, who, who, int(ink), int(art))`. The `art` normalisation is `dart = daiWad * RAY / rate`.
  - If `deal` + GemJoin misbehaves (PAXG fee logic), fall back to `vm.prank(ADMIN_SAFE); vat.slip(ILK, who, int(wad));`.
- `legacyCur()`: `vm.prank(SPOTTER); (bytes32 v,) = IPip(LEGACY_OSM).peek();`
- `pokeLegacy()`: `vm.warp(zzz + hop); osm.poke(); spotter.poke(ILK);`
- `mockChainlink(price, updatedAt)`: `vm.mockCall(CL_PAXG_USD, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(roundId, price, updatedAt, updatedAt, roundId));`
- `applySpell()`: deploy OracleGuard, then `vm.startPrank(ADMIN_SAFE)` and run the spell steps.

## 3. Test matrix

| Test | Setup | Baseline expectation (exploit works) | OracleGuard expectation |
|---|---|---|---|
| S1 stale feed | warp 7 days, no Chainlink updates | legacy `peek` `has=true`, age 7d; `frob(+dart)` succeeds | S1a: only Chainlink stale, mocks fresh → YELLOW, mint limited to gap. S1b: all sources stale → `PokeSkipped`, `status=STALE` → RED → mint reverts `Vat/ceiling-exceeded`; repay (`dart<0`) succeeds |
| S2 market −8%, OSM lagging | mocks −8%; Chainlink unchanged | mint at stale-high spot succeeds | `live.lo < cur·(1−ε)` → RED immediately; `bark` on an unsafe vault still works |
| S3 feed swap / manipulation | Safe `setPriceFeed(evil 10×)`; baseline: 2 hops | spot 10× → 10 PAXG mints ≈$312k vs $43.7k real value (per-urn `ink·spot` binds before `line`); log both from live `spot`/`mat` | Chainlink source 10× = MAD outlier → median unchanged → no promotion. Variant: if 2 of 4 sources are manipulated, the score drops and the jump is quarantined |
| S4 captured wick / stale-low | vault at ≈145%; all sources −15% at poke then recover | legacy captures the wick → spot low → `bark` succeeds on a vault that is healthy at the recovered price | guard: live `hi` ≫ cur → `hole=0` → `bark` reverts `Dog/liquidation-limit-hit`; guard expires after `guardMaxDuration` |
| S5 weekend (H1) | tslax ilk, calendar closed | n/a | YELLOW while closed; reopen needs kUp healthy syncs |
| Spell rollback | apply, then `spotter.file(pip, LEGACY_OSM)` | n/a | system back to legacy behaviour |

## 4. Unit tests (no fork)
- Aggregator: median correctness (odd/even, weights), outlier rejection, quorum, score bounds, all stale, source revert (`vm.mockCallRevert`).
- SmartOSM: `pass()` timing, init priming, quarantine then confirm, full-quorum jump accepted, `void()` reverts, `peek` toll.
- RiskController: every transition, hysteresis spacing (same-block spam doesn't upgrade), executors' `AboveCap`, only-controller auth.
- SessionCalendar: hour-of-week alignment (Mon 00:00 UTC = h0), holidays.

## 5. Invariants (H3) — `test/invariant/`
Handler actions: random mock price moves, warps, pokes, syncs, frob up/down, bark attempts.
- `invariant_peekAlwaysValid`: `SmartOSM.peek()` → `has && val > 0`
- `invariant_spotNonZero`: `Vat.ilks(ILK).spot > 0`
- `invariant_repayNeverOracleBlocked`: a repay action in the handler never reverts with `ceiling-exceeded`
- `invariant_lineWithinCap`: `Vat.ilks(ILK).line <= lineCap`

## 6. Fuzz
- `testFuzz_aggregator(uint256[4] prices, bool[4] ok, uint32[4] ages)`: `lo<=mid<=hi` when ok; `score<=100`; never reverts.
- `testFuzz_jump(uint256 move, uint16 score)`: quarantine iff `move>limit && score<jumpMinScore`.
