/**
 * Real Ethereum-mainnet reads for "mainnet mode". Nothing here is simulated: every price,
 * timestamp and Maker number is fetched from the chain (or RedStone's public API) on each poll.
 *
 * OracleGuard itself is NOT deployed on mainnet, so data.ts runs the protocol.ts model of
 * it on top of these real inputs. Addresses: docs/ONCHAIN_FACTS.md (Maker/Chainlink) plus
 * the Pyth / Uniswap ones below.
 */
import {
  createPublicClient,
  formatUnits,
  http,
  parseAbi,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { mainnet } from 'viem/chains'

export const MAINNET_RPC =
  import.meta.env.VITE_MAINNET_RPC_URL || 'https://ethereum-rpc.publicnode.com'

const ADDR = {
  chainlinkPaxgUsd: '0x9944D86CEB9160aF5C5feB251FD671923323f8C3', // 8 decimals
  pyth: '0x4305FB66699C3B2702D4d05CF36551390A4c69C6', // Pyth core contract on Ethereum
  // Uniswap v3 PAXG/USDC 0.05% (token0 = PAXG 18 dec, token1 = USDC 6 dec), deepest PAXG/USD pool
  uniPaxgUsdc: '0x5aE13BAAEF0620FdaE1D355495Dc51a17adb4082',
  vat: '0xbC22e8C15bC476EF4FD0124c5A03b23607e30D2C',
  spotter: '0xf3aee748355bb07CBe702B4ff8dBE6118b34e2A2',
  legacyOsm: '0x89fbAe0302b8790D55fa36E6Ab09ac93F865993a',
} as const satisfies Record<string, Address>

/** Pyth price id "Crypto.PAXG/USD" */
const PYTH_PAXG_USD = '0x273717b49430906f4b0c230e99aa1007f83758e3199edbc887c0d06c3e332494' as Hex
const REDSTONE_URL = 'https://api.redstone.finance/prices?symbols=PAXG&provider=redstone-primary-prod'
const TWAP_WINDOW_SEC = 1800
const ILK = '0x7061786700000000000000000000000000000000000000000000000000000000' as Hex

const chainlinkAbi = parseAbi([
  'function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)',
])
const pythAbi = parseAbi([
  'function getPriceUnsafe(bytes32 id) view returns ((int64 price, uint64 conf, int32 expo, uint256 publishTime))',
])
const uniAbi = parseAbi(['function observe(uint32[] secondsAgos) view returns (int56[], uint160[])'])
const vatAbi = parseAbi([
  'function ilks(bytes32) view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust)',
])
const spotterAbi = parseAbi(['function ilks(bytes32) view returns (address pip, uint256 mat)'])
const osmAbi = parseAbi(['function zzz() view returns (uint64)'])

/** One real price observation. `ok = false` when the read failed (mirrors "sources never revert"). */
export type RealFeed = {
  key: 'chainlink' | 'pyth' | 'redstone' | 'dexTwap'
  price: number
  updatedAt: number // unix seconds
  ok: boolean
  via: string
}

export type MainnetData = {
  block: number
  blockTime: number
  feeds: RealFeed[]
  vat: { debtUsd: number; lineUsd: number }
  mat: number
  legacy: { price: number; valid: boolean; zzz: number }
}

let client: PublicClient | undefined

function getClient(): PublicClient {
  client ??= createPublicClient({
    chain: mainnet,
    transport: http(MAINNET_RPC),
    batch: { multicall: true },
  }) as PublicClient
  return client
}

async function redstone(): Promise<RealFeed> {
  try {
    const res = await fetch(REDSTONE_URL, { signal: AbortSignal.timeout(5000) })
    const json = (await res.json()) as { PAXG?: { value: number; timestamp: number } }
    const p = json.PAXG
    if (!p || !(p.value > 0)) throw new Error('no PAXG price')
    return {
      key: 'redstone',
      price: p.value,
      updatedAt: Math.floor(p.timestamp / 1000),
      ok: true,
      via: 'RedStone API',
    }
  } catch {
    return { key: 'redstone', price: 0, updatedAt: 0, ok: false, via: 'RedStone API' }
  }
}

export async function fetchMainnet(): Promise<MainnetData> {
  const c = getClient()
  const block = await c.getBlock({ blockTag: 'latest' })
  const blockNumber = block.number ?? 0n
  const at = { blockNumber }

  const [cl, pyth, twap, ilk, spot, legacySlot, legacyZzz, rs] = await Promise.all([
    c.readContract({ ...at, address: ADDR.chainlinkPaxgUsd, abi: chainlinkAbi, functionName: 'latestRoundData' }).catch(() => null),
    c.readContract({ ...at, address: ADDR.pyth, abi: pythAbi, functionName: 'getPriceUnsafe', args: [PYTH_PAXG_USD] }).catch(() => null),
    c.readContract({ ...at, address: ADDR.uniPaxgUsdc, abi: uniAbi, functionName: 'observe', args: [[TWAP_WINDOW_SEC, 0]] }).catch(() => null),
    c.readContract({ ...at, address: ADDR.vat, abi: vatAbi, functionName: 'ilks', args: [ILK] }),
    c.readContract({ ...at, address: ADDR.spotter, abi: spotterAbi, functionName: 'ilks', args: [ILK] }),
    c.getStorageAt({ ...at, address: ADDR.legacyOsm, slot: toHex(3n) }),
    c.readContract({ ...at, address: ADDR.legacyOsm, abi: osmAbi, functionName: 'zzz' }),
    redstone(),
  ])

  const feeds: RealFeed[] = [
    cl && cl[1] > 0n
      ? { key: 'chainlink', price: Number(formatUnits(cl[1], 8)), updatedAt: Number(cl[3]), ok: true, via: 'Chainlink PAXG/USD' }
      : { key: 'chainlink', price: 0, updatedAt: 0, ok: false, via: 'Chainlink PAXG/USD' },
    pyth && pyth.price > 0n
      ? {
          key: 'pyth',
          price: Number(pyth.price) * 10 ** pyth.expo,
          updatedAt: Number(pyth.publishTime),
          ok: true,
          via: 'Pyth on-chain (last push)',
        }
      : { key: 'pyth', price: 0, updatedAt: 0, ok: false, via: 'Pyth on-chain' },
    rs,
    twap
      ? {
          key: 'dexTwap',
          // average tick over the window -> USDC per PAXG (decimals 18 vs 6 -> x 1e12)
          price: 1.0001 ** (Number(twap[0][1] - twap[0][0]) / TWAP_WINDOW_SEC) * 1e12,
          updatedAt: Number(block.timestamp), // a TWAP is computed at read time
          ok: true,
          via: 'Uniswap v3 PAXG/USDC 30-min TWAP',
        }
      : { key: 'dexTwap', price: 0, updatedAt: 0, ok: false, via: 'Uniswap v3 TWAP' },
  ]

  const [Art, rate, , line] = ilk
  const word = BigInt(legacySlot ?? '0x0')
  return {
    block: Number(blockNumber),
    blockTime: Number(block.timestamp),
    feeds,
    vat: {
      debtUsd: Number(formatUnits(Art * rate, 45)),
      lineUsd: Number(formatUnits(line, 45)),
    },
    mat: Number(formatUnits(spot[1], 27)),
    // Maker OSM slot 3 = cur: low 128 bits price (WAD), high bits `has`
    legacy: {
      price: Number(formatUnits(word & ((1n << 128n) - 1n), 18)),
      valid: word >> 128n === 1n,
      zzz: Number(legacyZzz),
    },
  }
}
