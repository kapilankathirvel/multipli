/**
 * J3 scenario controls. One `Runner` interface, two implementations:
 *
 *  - mainnet: hands the script to data.ts, which applies the fault on top of the real
 *             mainnet feeds (OracleGuard is modelled in the browser there)
 *  - fork:    viem **test actions** against anvil (snapshot / revert / increaseTime / mine)
 *             plus MockSource.setPrice, SmartOSM.poke and RiskController.sync
 *
 * Steps follow docs/DEMO_SCRIPT.md §B. Two live-mode rules that bit us in K3:
 *   1. the three MockSources have a 1h maxAge -> refresh them before every poke
 *      and after every time warp, or the poke is skipped for lack of quorum;
 *   2. `SmartOSM.poke()` reverts with `OSM/not-passed` until `zzz + hop`, so we
 *      warp to the next hop instead of letting the button fail.
 */
import {
  createTestClient,
  http,
  pad,
  publicActions,
  toHex,
  walletActions,
  type Abi,
  type Address,
} from 'viem'
import { foundry } from 'viem/chains'
import mockAbiJson from './abi/IMockSource.json' with { type: 'json' }
import priceSourceAbiJson from './abi/IPriceSource.json' with { type: 'json' }
import controllerAbiJson from './abi/IRiskController.json' with { type: 'json' }
import osmAbiJson from './abi/ISmartOSM.json' with { type: 'json' }
import { ILK, getProvider, loadFork, mode, type ForkShape, type ScriptName } from './data'

const mockAbi = mockAbiJson as Abi
const priceSourceAbi = priceSourceAbiJson as Abi
const osmAbi = osmAbiJson as Abi
const controllerAbi = controllerAbiJson as Abi

/** anvil account #0 — the deployer, and therefore the MockSources' ward (see script/Deploy.s.sol). */
const ANVIL_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address

export type ScenarioId = ScriptName

export const SCENARIOS: { id: ScenarioId; label: string; hint: string; kind: 'danger' | 'step' | 'reset' }[] = [
  { id: 'reset', label: 'Reset', hint: 'clear every fault and go back to the starting state', kind: 'reset' },
  { id: 's1', label: 'S1 stale feed', hint: 'publishers stop and 26h pass: every feed is stale → no quorum → RED', kind: 'danger' },
  { id: 's2', label: 'S2 market −8%', hint: 'fast feeds drop 8%, Chainlink lags → RED, liquidations stay open', kind: 'danger' },
  { id: 's3', label: 'S3 compromised', hint: 'Chainlink reports 10× the price → rejected as an outlier', kind: 'danger' },
  { id: 's4', label: 'S4 captured wick', hint: 'every feed dips 15% long enough for the OSM to capture it, then recovers → 🛡️ guard ON', kind: 'danger' },
  { id: 'poke', label: 'Poke', hint: 'SmartOSM.poke(): the queued price (nxt) becomes the price vaults use (cur); the new median is queued', kind: 'step' },
  { id: 'sync', label: 'Sync', hint: 'RiskController.sync(): re-evaluate GREEN/YELLOW/RED, set the debt ceiling and the liquidation guard', kind: 'step' },
  { id: 'warp1h', label: 'Warp +1h', hint: 'move the clock forward one hour (one OSM hop), then poke and sync', kind: 'step' },
]

export type Runner = {
  /** Runs a scenario and resolves with a one-line status for the UI. */
  run(id: ScenarioId): Promise<string>
  /** Live mode: connect and take the snapshot that `Reset` returns to. */
  prepare(): Promise<void>
}

// ── mainnet ─────────────────────────────────────────────────────────────────

function createMainnetRunner(): Runner {
  return {
    async prepare() {},
    async run(id) {
      getProvider().applyScript(id)
      return `${id} applied on top of the real mainnet feeds`
    },
  }
}

// ── fork ────────────────────────────────────────────────────────────────────

type Anvil = ReturnType<typeof makeClient>

function makeClient(rpc: string) {
  return createTestClient({
    chain: foundry,
    mode: 'anvil',
    transport: http(rpc),
    account: ANVIL_0,
  })
    .extend(publicActions)
    .extend(walletActions)
}

function createLiveRunner(): Runner {
  let client: Anvil | undefined
  let fork: ForkShape | undefined
  let snapshotId: `0x${string}` | undefined

  async function ready(): Promise<{ c: Anvil; f: ForkShape }> {
    if (!fork) fork = await loadFork()
    if (!client) {
      const rpc = import.meta.env.VITE_RPC_URL || fork.rpc || 'http://127.0.0.1:8545'
      client = makeClient(rpc)
      // anvil already holds account #0's key; impersonating is harmless and keeps
      // the private key out of the repo
      await client.impersonateAccount({ address: ANVIL_0 }).catch(() => {})
    }
    if (!snapshotId) {
      const fromFile = fork.snapshotId
      snapshotId =
        fromFile && fromFile !== '0x0'
          ? (fromFile as `0x${string}`)
          : await client.snapshot()
    }
    return { c: client, f: fork }
  }

  const og = (f: ForkShape) => ({
    osm: f.oracleguard.smartOsm as Address,
    controller: f.oracleguard.controller as Address,
    chainlink: f.oracleguard.sources?.chainlink as Address | undefined,
    mocks: (['pyth', 'redstone', 'dexTwap'] as const)
      .map((k) => f.oracleguard.sources?.[k] as Address | undefined)
      .filter((a): a is Address => Boolean(a)),
  })

  /** The honest reference price: the real Chainlink source, which scenarios never touch. */
  async function market(c: Anvil, f: ForkShape): Promise<bigint> {
    const cl = og(f).chainlink
    if (!cl) throw new Error('fork.json has no oracleguard.sources.chainlink')
    const obs = (await c.readContract({
      address: cl,
      abi: priceSourceAbi,
      functionName: 'observe',
    })) as { price: bigint }
    if (obs.price === 0n) throw new Error('Chainlink source returned 0')
    return obs.price
  }

  /**
   * Sends one tx and waits for it. `mine` is a no-op under automine but keeps the
   * buttons working if anvil was started with --block-time; a reverted tx (e.g.
   * `OSM/not-passed`) surfaces as an error instead of a silent no-op.
   */
  async function send(
    c: Anvil,
    what: string,
    tx: { address: Address; abi: Abi; functionName: string; args?: unknown[] },
  ): Promise<void> {
    const hash = await c.writeContract({ ...tx, account: ANVIL_0, chain: foundry })
    await c.mine({ blocks: 1 }).catch(() => {})
    const receipt = await c.waitForTransactionReceipt({ hash, timeout: 30_000 })
    if (receipt.status !== 'success') throw new Error(`${what} reverted (tx ${hash.slice(0, 10)}…)`)
  }

  async function setMocks(c: Anvil, addrs: Address[], priceWad: bigint): Promise<void> {
    for (const address of addrs) {
      await send(c, 'setPrice', {
        address,
        abi: mockAbi,
        functionName: 'setPrice',
        args: [priceWad],
      })
    }
  }

  async function warp(c: Anvil, seconds: number): Promise<void> {
    await c.increaseTime({ seconds })
    await c.mine({ blocks: 1 })
  }

  /** `poke()` reverts until zzz + hop, so jump to the next hop first. */
  async function waitForHop(c: Anvil, osm: Address): Promise<void> {
    const [passed, zzz, hop, block] = await Promise.all([
      c.readContract({ address: osm, abi: osmAbi, functionName: 'pass' }) as Promise<boolean>,
      c.readContract({ address: osm, abi: osmAbi, functionName: 'zzz' }) as Promise<bigint>,
      c.readContract({ address: osm, abi: osmAbi, functionName: 'hop' }) as Promise<number>,
      c.getBlock(),
    ])
    if (passed) return
    const target = Number(zzz) + Number(hop)
    await warp(c, Math.max(1, target - Number(block.timestamp) + 1))
  }

  /**
   * Waits for the hop, THEN lets the caller refresh the sources, THEN pokes.
   * Order matters: waiting for the hop warps time, which would re-stale anything
   * refreshed beforehand (the mocks only live for 1h).
   */
  async function poke(c: Anvil, osm: Address, prepare?: () => Promise<void>): Promise<void> {
    await waitForHop(c, osm)
    if (prepare) await prepare()
    await send(c, 'SmartOSM.poke', { address: osm, abi: osmAbi, functionName: 'poke' })
  }

  async function sync(c: Anvil, controller: Address): Promise<void> {
    await send(c, 'RiskController.sync', {
      address: controller,
      abi: controllerAbi,
      functionName: 'sync',
      args: [ILK],
    })
  }

  const pct = (p: bigint, bps: bigint) => (p * bps) / 10_000n

  return {
    async prepare() {
      await ready()
    },

    async run(id) {
      const { c, f } = await ready()
      const { osm, controller, mocks } = og(f)

      switch (id) {
        case 'reset': {
          if (snapshotId) await c.revert({ id: snapshotId })
          // anvil consumes a snapshot on revert -> take a fresh one for the next Reset
          snapshotId = await c.snapshot()
          await c.mine({ blocks: 1 })
          return 'reverted to the post-spell snapshot'
        }

        case 's1': {
          // nobody refreshes anything: the mocks age out after 1h, Chainlink after 25h
          await warp(c, 26 * 3600)
          await poke(c, osm).catch(() => {}) // emits PokeSkipped(NO_QUORUM); the tx itself succeeds
          await sync(c, controller)
          return 'S1: warped +26h with no publishers → no quorum, OSM STALE'
        }

        case 's2': {
          // the market really drops; the slow push feed keeps quoting the old price.
          // No poke: the OSM must lag, that is the whole point of the scenario.
          const p = await market(c, f)
          await setMocks(c, mocks, pct(p, 9_200n))
          await sync(c, controller)
          return 'S2: fast sources −8%, Chainlink unchanged → RED (live.lo < OSM −1.5%)'
        }

        case 's3': {
          // one compromised source reports 10x; the other three stay honest
          const p = await market(c, f)
          await poke(c, osm, async () => {
            await setMocks(c, mocks.slice(1), p)
            await setMocks(c, mocks.slice(0, 1), p * 10n)
          })
          await sync(c, controller)
          // The legacy stack never reads the mocks, so compromise ITS single feed too, or the
          // comparison panel has nothing to compare. We write the end state of Kapilan's
          // Baseline_S3 fork test (Safe swaps the adapter to a 10x feed, OSM poked twice) into
          // the legacy OSM's `cur` (slot 3: has << 128 | val). After the spell nothing reads the
          // legacy OSM, so this only feeds the Legacy-vs-OracleGuard panel; Reset reverts it.
          await c.setStorageAt({
            address: f.maker.legacyOsm as Address,
            index: 3,
            value: pad(toHex((1n << 128n) | (p * 10n)), { size: 32 }),
          })
          await c.mine({ blocks: 1 })
          return 'S3: one source ×10 → outlier, median unchanged · legacy fed the same ×10'
        }

        case 's4': {
          // captured wick: everything dips 15%, the OSM takes it, then the market recovers
          const p = await market(c, f)
          const low = pct(p, 8_500n)
          await poke(c, osm, () => setMocks(c, mocks, low)) // wick lands in nxt
          await poke(c, osm, () => setMocks(c, mocks, low)) // ...and now in cur: every vault is valued at it
          await setMocks(c, mocks, p) // the market recovers
          await sync(c, controller)
          return 'S4: wick captured into cur, sources recovered → guard should be ON'
        }

        case 'poke': {
          const p = await market(c, f)
          await poke(c, osm, () => setMocks(c, mocks, p))
          await sync(c, controller)
          return 'poked (sources refreshed first)'
        }

        case 'sync': {
          await sync(c, controller)
          return 'controller.sync(paxg)'
        }

        case 'warp1h': {
          await warp(c, 3600)
          const p = await market(c, f)
          // 1h maxAge: the mocks are stale the moment we warp, so refresh inside the poke
          await poke(c, osm, () => setMocks(c, mocks, p))
          await sync(c, controller)
          return 'warped +1h → refreshed → poked → synced'
        }

        default:
          return `unknown scenario ${String(id)}`
      }
    },
  }
}

let singleton: Runner | undefined

export function getRunner(): Runner {
  if (!singleton) singleton = mode() === 'fork' ? createLiveRunner() : createMainnetRunner()
  return singleton
}

/** Trims viem's multi-line revert dumps down to something that fits in the status bar. */
export function shortError(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err)
  const revert = msg.match(/reverted with(?: the following)? reason:?\s*\n?(.+)/i)
  if (revert) return revert[1].trim()
  return msg.split('\n')[0].slice(0, 160)
}
