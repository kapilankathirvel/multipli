# On-chain Facts (Ethereum mainnet)

Verified **2026-09-19** from verified source code (Blockscout), `eth_call` at block ≈26,011,000, and event logs. **This file is the source of truth for constants.** All addresses are EIP-55 checksummed and ready to paste into Solidity.

## 1. Addresses

| Role | Address | Notes |
|---|---|---|
| rwaUSD token | `0x8Fcd23142047A3073ed332a0Ed07d1e8D2BD5177` | Base `0x272E…2789`, Ink `0x2A66…0D4c`, Monad `0x9aBb…2C69` (CCIP) |
| Vat | `0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C` | Maker-fork core ledger. ⚠️ `dai(address)` is renamed **`rwaUSD(address)`** (verified ABI) |
| Spotter | `0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2` | `ilks("paxg").pip` = legacy OSM |
| Dog | `0x15a36d5cAf263160c2a49DDE6429C045Fb711dDD` | `ilks("paxg").clip` = Clipper below |
| Clipper (paxg) | `0x62B7a353928142A18C07026A33F8089d1c7378F4` | |
| Calc (price decay) | `0xfEb42fB58E790DD5f38d936df45b4Bdd29260DE5` | |
| Vow | `0x7815e8e9BCEF8708A799eE3802586298e5AFA611` | |
| End | `0x026782F431bfC233c67128af42a4e9De7f834BF5` | |
| Legacy OSM | `0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a` | stock Maker `osm.sol`, 0.6.12 |
| OsmMom | `0x58B377160283C5B8446B6AD0f2a2D62490E8621a` | can only `stop()` the OSM; owner = Admin Safe; authority = `0xC8185a4695B668C7A292f0a75f5A5777702787B5` |
| PriceFeedAdapter | `0x82F5790Bd1c96790E4c3a3ebC8142bD4D6F8b1CD` | custom, 0.6.12, owner = Admin Safe |
| Chainlink PAXG/USD proxy | `0x9944D86CEB9160aF5C5feB251FD671923323f8C3` | `description()="PAXG / USD"`, `decimals()=8` |
| Chainlink PAXG/USD aggregator | `0x6795D4A47c9c8F4117b409D966259CdCf6A9Eb6E` | `minAnswer=1`, `maxAnswer≈2^176` (no effective clamp) |
| PAXG token | `0x45804880De22913dAFE09f4980848ECE6EcbAf78` | 18 decimals. ⚠️ Paxos charges a transfer fee on PAXG; `deal()` in tests avoids it |
| PAXG GemJoin | `0x3c9567C3b9c20E72858cD5714209EA7D7a8011fD` | `ilk()="paxg"`, `dec()=18` |
| Admin Safe | `0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99` | Gnosis Safe **4-of-8**. `wards=1` on Vat, Spotter, Dog, Clipper, Join, OSM. Owner of the adapter and OsmMom |

## 2. PAXG ilk parameters (`ilk = "paxg"`)

| Param | Raw | Human |
|---|---|---|
| `Spotter.ilks.mat` | `0x4860d8812f0b38878000000` | **1.40** (140%) |
| `Vat.ilks.Art` | | 42,650.26 (normalised) |
| `Vat.ilks.rate` | | 1.008888 |
| **Debt** (`Art·rate`) | | **≈ 43,029 rwaUSD** |
| `Vat.ilks.spot` | | 3,123.20, so the price the Vat sees ≈ 3,123.20 × 1.40 ≈ **$4,372** |
| `Vat.ilks.line` | | **1,000,000** |
| `Vat.ilks.dust` | | 200 |
| `Vat.Line` (global) | | 5,000,000 |
| `Vat.live` | | 1 |
| `Dog.ilks.chop` | | 1.05 |
| `Dog.ilks.hole` | | 400,000 |
| `Dog.ilks.dirt` | | 0 |
| `Clipper.buf` | | 1.10 |
| `Clipper.stopped` | | 0 |

## 3. Oracle state

| Item | Value | Meaning |
|---|---|---|
| `OSM.hop` | 3600 | 1h. The source default is 1800, so `step()` was called at block 25,043,242 |
| `OSM.src` | PriceFeedAdapter | |
| `OSM.stopped` | 0 | |
| `OSM.zzz` | 1789808400 | last poke boundary |
| `OSM.bud` | Spotter, End, Clipper (Kiss events, blocks 24,800,413–435) | |
| OSM wards (from Rely/Deny logs) | Admin Safe (block 24,800,437), OsmMom (block 25,996,369); deployer `0xeefa…251f` denied | |
| `Adapter.maxDelay` | 86400 | 24h |
| `Adapter.paused` | false | |
| Chainlink `latestRoundData.updatedAt` | 1789749023 | **≈16.5h older than `OSM.zzz`**: the OSM captured a price that was already stale-ish |

## 4. Verified behaviour (read from source)

- `PriceFeedAdapter.peek()` returns `(0,false)` if paused, `answer<=0`, `startedAt==0`, `updatedAt==0`, or `now-updatedAt > maxDelay`. There is no min/max bound check. `read()` reverts `"Pip/invalid"`.
- `OSM.poke()`: `require(pass())`; `(wut, ok) = src.peek(); if (ok) { cur = nxt; nxt = Feed(wut,1); zzz = prev(now); emit Poke }`. **When `!ok`, nothing happens.**
- `OSM.peek()` returns `(cur.val, cur.has == 1)` with **no age check**. It is gated by `toll` (bud only).
- `OSM.void()` sets `cur = nxt = 0` and `stopped = 1`, so the next `Spotter.poke` gives **`spot = 0`**.
- `OsmMom.stop(ilk)` calls `OSM.stop()`, which only blocks `poke()` and **keeps serving the frozen `cur`**.
- Adapter admin functions (`setPriceFeed`, `setAsset`, `setMaxDelay`, `pause`, `unpause`, `transferOwnership`) are `onlyOwner` with **no timelock**.

## 5. Re-verify with `cast` (after installing Foundry)

```bash
export ETH_RPC_URL=https://mainnet.gateway.tenderly.co   # keyless archive RPC (publicnode has no archive)
ILK=$(cast --format-bytes32-string paxg)
cast call 0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2 "ilks(bytes32)(address,uint256)" $ILK          # pip, mat
cast call 0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C "ilks(bytes32)(uint256,uint256,uint256,uint256,uint256)" $ILK  # Art rate spot line dust
cast call 0x15a36d5cAf263160c2a49DDE6429C045Fb711dDD "ilks(bytes32)(address,uint256,uint256,uint256)" $ILK         # clip chop hole dirt
cast call 0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a "hop()(uint16)"
cast call 0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a "zzz()(uint64)"
cast call 0x82F5790Bd1c96790E4c3a3ebC8142bD4D6F8b1CD "maxDelay()(uint256)"
cast call 0x82F5790Bd1c96790E4c3a3ebC8142bD4D6F8b1CD "owner()(address)"
cast call 0x9944D86CEB9160aF5C5feB251FD671923323f8C3 "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
cast call 0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C "wards(address)(uint256)" 0x194Ebc1B9B382ef0E6998cAAcE59aF843cf53b99
```

## 6. Unknowns (ask the Multipli team or check on the fork)
- The rwaUSD `DaiJoin`-equivalent address (needed only to *exit* minted rwaUSD to ERC-20; internal Vat `dai` is enough to prove the exploit).
- Clipper `tail`, `cusp`, `chip`, `tip`, and the Calc parameters.
- Who pokes the OSM/Spotter in production and how often.
- Whether ClipperMom or AutoLine are deployed.
