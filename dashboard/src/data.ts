import {
  createPublicClient,
  decodeEventLog,
  formatUnits,
  getAddress,
  http,
  toHex,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { foundry } from 'viem/chains'
import aggregatorAbiJson from './abi/IOracleGuardAggregator.json' with { type: 'json' }
import controllerAbiJson from './abi/IRiskController.json' with { type: 'json' }
import osmAbiJson from './abi/ISmartOSM.json' with { type: 'json' }
import vatAbiJson from './abi/IVat.json' with { type: 'json' }
import forkExample from './fork.example.json' with { type: 'json' }
import {
  P,
  aggregate,
  deriveState,
  factorsOf,
  lineFor,
  type Factors,
  type Feed,
  type OsmStatus,
  type Reading,
  type RiskState,
  type Source,
} from './protocol'

export type { Factors, Reading, Source } from './protocol'
export { effectsFor, P } from './protocol'

const aggregatorAbi = aggregatorAbiJson as Abi
const osmAbi = osmAbiJson as Abi
const controllerAbi = controllerAbiJson as Abi
const vatAbi = vatAbiJson as Abi

/** bytes32("paxg") */
export const ILK =
  '0x7061786700000000000000000000000000000000000000000000000000000000' as Hex

export const SOURCE_NAMES = ['Chainlink', 'Pyth', 'RedStone', 'DEX TWAP'] as const

/** Weights and maxAge per review.md R1.1. The mock world uses these; live reads them from sourceAt(). */
const SOURCE_CFG: { name: string; weight: number; maxAgeSec: number }[] = [
  { name: 'Chainlink', weight: 2, maxAgeSec: 25 * 3600 },
  { name: 'Pyth', weight: 2, maxAgeSec: 3600 },
  { name: 'RedStone', weight: 2, maxAgeSec: 3600 },
  { name: 'DEX TWAP', weight: 1, maxAgeSec: 3600 },
]

export type OsmState = {
  cur: number
  nxt: number
  ageSec: number
  status: OsmStatus
}

export type Risk = {
  state: RiskState
  guard: boolean
  lineUsd: number
  debtUsd: number
  /** why the controller is in this state (mock derives it; live shows the score) */
  reason: string
}

export type Legacy = {
  price: number
  valid: boolean
  ageHours: number
}

export type LogEvent = {
  id: string
  t: number
  name: string
  detail: string
}

export type Snapshot = {
  sources: Source[]
  reading: Reading
  factors: Factors
  osm: OsmState
  risk: Risk
  legacy: Legacy
  events: LogEvent[]
  mode: 'mock' | 'live'
  error?: string
  updatedAt: number
}

export type BorrowStatus = 'open' | 'limited' | 'frozen'

export type DataProvider = {
  start(onUpdate: (snap: Snapshot) => void): () => void
  /** J3 will drive this; mock already applies named scripts. */
  applyScript(name: MockScriptName): void
}

export type MockScriptName =
  | 'idle'
  | 'reset'
  | 's1'
  | 's2'
  | 's3'
  | 's4'
  | 'poke'
  | 'sync'
  | 'warp1h'

const OSM_STATUS: OsmStatus[] = ['UNINIT', 'LIVE', 'STALE', 'QUARANTINED', 'STOPPED']
const RISK_STATE: RiskState[] = ['GREEN', 'YELLOW', 'RED']

const BASE_PRICE = 4372.478
const START_DEBT = 43_029
const POLL_MS = 2000

type ForkShape = {
  rpc: string
  oracleguard: {
    aggregator: string
    smartOsm: string
    controller: string
    sources?: Record<string, string>
  }
  maker: {
    vat: string
    legacyOsm: string
  }
}

const bundledFork = forkExample as ForkShape

export function mode(): 'mock' | 'live' {
  return import.meta.env.VITE_MODE === 'live' ? 'live' : 'mock'
}

export function borrowStatus(risk: Risk): BorrowStatus {
  if (risk.state === 'RED') return 'frozen'
  if (risk.state === 'YELLOW') return 'limited'
  return 'open'
}

function wadToNum(wad: bigint): number {
  return Number(formatUnits(wad, 18))
}

function radToUsd(rad: bigint): number {
  return Number(formatUnits(rad, 45))
}

function jitter(n: number, bps: number): number {
  return n + (Math.random() * 2 - 1) * (bps / 10_000) * n
}

function fmtUsd(n: number): string {
  return n.toLocaleString('en-US', { maximumFractionDigits: 2 })
}

function pushEvent(events: LogEvent[], name: string, detail: string): LogEvent[] {
  const ev: LogEvent = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    t: Date.now(),
    name,
    detail,
  }
  return [ev, ...events].slice(0, 40)
}

// ── mock ────────────────────────────────────────────────────────────────────
//
// The mock is a small simulation, not a set of canned screenshots: scenarios only
// move the *feeds* (price, freshness, liveness) and the aggregator + controller
// logic in protocol.ts derives score, state, line and guard from them. That keeps
// every panel consistent with the contracts, and J3's buttons just call applyScript.

type MockFeed = {
  name: string
  weight: number
  maxAgeSec: number
  price: number
  updatedAt: number
  ok: boolean
}

type MockWorld = {
  script: MockScriptName
  warp: number // simulated seconds added by time warps / scenarios
  market: number // the "true" market price the healthy feeds track
  feedsFrozen: boolean // scenario S1: nobody refreshes the feeds any more
  clMul: number // scenario S3: compromised Chainlink multiplier
  clFrozen: boolean // scenario S2: Chainlink keeps quoting the pre-drop price
  feeds: MockFeed[]
  osm: { cur: number; nxt: number; lastGoodAt: number; zzz: number; quarantined: boolean }
  debtUsd: number
  state: RiskState
  guard: boolean
  legacy: { price: number; updatedAt: number }
  events: LogEvent[]
}

function simNow(w: MockWorld): number {
  return Math.floor(Date.now() / 1000) + w.warp
}

function seedWorld(): MockWorld {
  const now = Math.floor(Date.now() / 1000)
  const w: MockWorld = {
    script: 'idle',
    warp: 0,
    market: BASE_PRICE,
    feedsFrozen: false,
    clMul: 1,
    clFrozen: false,
    feeds: SOURCE_CFG.map((c) => ({
      ...c,
      price: BASE_PRICE,
      // Chainlink is a deviation feed: quiet is normal, so it starts 16.5h old
      updatedAt: c.name === 'Chainlink' ? now - 16.5 * 3600 : now - 20,
      ok: true,
    })),
    osm: { cur: BASE_PRICE, nxt: BASE_PRICE, lastGoodAt: now, zzz: now, quarantined: false },
    debtUsd: START_DEBT,
    state: 'GREEN',
    guard: false,
    legacy: { price: BASE_PRICE, updatedAt: now - 16.5 * 3600 },
    events: [],
  }
  w.events = pushEvent(
    pushEvent([], 'Synced', `ilk=paxg state=GREEN line=$${fmtUsd(lineFor('GREEN', START_DEBT))}`),
    'Init',
    `SmartOSM primed from legacy cur $${fmtUsd(BASE_PRICE)}`,
  )
  return w
}

/** Refresh the feeds that are still being published, then drift the market a little. */
function advanceFeeds(w: MockWorld): void {
  const now = simNow(w)
  w.market = jitter(w.market, 1.5)
  if (w.feedsFrozen) return
  for (const f of w.feeds) {
    if (f.name === 'Chainlink') {
      if (w.clFrozen) continue
      // a deviation feed only publishes on a 0.5% move or its 24h heartbeat
      const candidate = jitter(w.market, 2) * w.clMul
      if (Math.abs(candidate - f.price) / f.price > 0.005 || now - f.updatedAt > 24 * 3600) {
        f.price = candidate
        f.updatedAt = now
      }
    } else {
      f.price = jitter(w.market, 3)
      f.updatedAt = now
    }
  }
  const cl = w.feeds[0]
  w.legacy = { price: cl.price, updatedAt: cl.updatedAt }
}

function feedsOf(w: MockWorld): Feed[] {
  const now = simNow(w)
  return w.feeds.map((f) => ({
    name: f.name,
    weight: f.weight,
    maxAgeSec: f.maxAgeSec,
    price: f.price,
    ageSec: Math.max(0, now - f.updatedAt),
    ok: f.ok,
  }))
}

function osmStatusOf(w: MockWorld): OsmStatus {
  if (w.osm.quarantined) return 'QUARANTINED'
  if (simNow(w) - w.osm.lastGoodAt > P.staleLimitSec) return 'STALE'
  return 'LIVE'
}

/** The keeper's `sync()`: recompute state + guard and log what changed. */
function syncState(w: MockWorld, reading: Reading, loud: boolean): void {
  const v = deriveState(reading, w.osm.cur, osmStatusOf(w))
  if (v.state !== w.state) {
    w.events = pushEvent(w.events, 'StateChanged', `${w.state} -> ${v.state} (${v.reason})`)
    w.state = v.state
  }
  if (v.guard !== w.guard) {
    w.events = pushEvent(
      w.events,
      v.guard ? 'GuardOn' : 'GuardOff',
      v.guard ? 'ilk=paxg - Dog.hole = 0, new liquidations paused' : 'ilk=paxg - Dog.hole restored',
    )
    w.guard = v.guard
  }
  if (loud) {
    w.events = pushEvent(
      w.events,
      'Synced',
      `state=${w.state} score=${reading.score} line=$${fmtUsd(lineFor(w.state, w.debtUsd))} guard=${w.guard ? 'on' : 'off'}`,
    )
  }
}

/** The keeper's `poke()`: mirrors SmartOSM.poke (quorum check, jump quarantine, cur <- nxt). */
function pokeOsm(w: MockWorld, reading: Reading): void {
  const now = simNow(w)
  if (!reading.ok || reading.mid === 0) {
    w.events = pushEvent(w.events, 'PokeSkipped', `reason=NO_QUORUM score=${reading.score}`)
    return
  }
  const jumpBps = w.osm.nxt > 0 ? (Math.abs(reading.mid - w.osm.nxt) / w.osm.nxt) * 10_000 : 0
  if (jumpBps > P.jumpLimitBps && reading.score < P.jumpMinScore && !w.osm.quarantined) {
    w.osm.quarantined = true
    w.events = pushEvent(
      w.events,
      'Quarantined',
      `candidate=$${fmtUsd(reading.mid)} nxt=$${fmtUsd(w.osm.nxt)} score=${reading.score}`,
    )
    return
  }
  w.osm.quarantined = false
  w.osm.cur = w.osm.nxt
  w.osm.nxt = reading.mid
  w.osm.lastGoodAt = now
  w.osm.zzz = now
  w.events = pushEvent(
    w.events,
    'Poke',
    `cur=$${fmtUsd(w.osm.cur)} nxt=$${fmtUsd(w.osm.nxt)} score=${reading.score}`,
  )
}

function applyMockScript(w: MockWorld, script: MockScriptName): MockWorld {
  const reading = () => aggregate(feedsOf(w)).reading

  switch (script) {
    case 'reset': {
      const fresh = seedWorld()
      fresh.events = pushEvent(w.events, 'Reset', 'reverted to snapshot')
      return fresh
    }

    case 's1': {
      // stale feed: warp 25h and stop publishing -> everything ages out of maxAge
      w.warp += 25 * 3600
      w.feedsFrozen = true
      w.events = pushEvent(w.events, 'Scenario', 'S1 stale feed - warp +25h, publishers down')
      pokeOsm(w, reading())
      syncState(w, reading(), true)
      return w
    }

    case 's2': {
      // real market drop of 8%; the slow push feed keeps quoting the old price
      w.market *= 0.92
      w.clFrozen = true
      w.events = pushEvent(w.events, 'Scenario', 'S2 market -8% - fast feeds follow, Chainlink lags')
      advanceFeeds(w)
      syncState(w, reading(), true)
      return w
    }

    case 's3': {
      // one compromised source reports 10x
      w.clMul = 10
      w.clFrozen = false
      w.events = pushEvent(w.events, 'Scenario', 'S3 compromised source - Chainlink x10')
      advanceFeeds(w)
      pokeOsm(w, reading())
      syncState(w, reading(), true)
      return w
    }

    case 's4': {
      // captured wick: all sources dip 15%, the OSM captures it, then the market recovers
      const before = w.market
      w.market = before * 0.85
      advanceFeeds(w)
      w.events = pushEvent(w.events, 'Scenario', 'S4 captured wick - all sources -15%')
      pokeOsm(w, reading())
      w.warp += P.hopSec
      advanceFeeds(w) // publishers refresh after the warp, still at the wick price
      pokeOsm(w, reading()) // the wick is now `cur`, the price every vault is valued at
      w.market = before
      advanceFeeds(w)
      syncState(w, reading(), true)
      return w
    }

    case 'poke': {
      pokeOsm(w, reading())
      syncState(w, reading(), false)
      return w
    }

    case 'sync': {
      syncState(w, reading(), true)
      return w
    }

    case 'warp1h': {
      w.warp += P.hopSec
      w.events = pushEvent(w.events, 'Warp', '+1h (evm_increaseTime)')
      advanceFeeds(w)
      syncState(w, reading(), false)
      return w
    }

    default:
      return w
  }
}

function snapFromWorld(w: MockWorld): Snapshot {
  const { sources, reading, factors } = aggregate(feedsOf(w))
  const now = simNow(w)
  return {
    sources,
    reading,
    factors,
    osm: {
      cur: w.osm.cur,
      nxt: w.osm.nxt,
      ageSec: Math.max(0, now - w.osm.lastGoodAt),
      status: osmStatusOf(w),
    },
    risk: {
      state: w.state,
      guard: w.guard,
      lineUsd: lineFor(w.state, w.debtUsd),
      debtUsd: w.debtUsd,
      reason: deriveState(reading, w.osm.cur, osmStatusOf(w)).reason,
    },
    legacy: {
      price: w.legacy.price,
      valid: true, // the legacy OSM never reports staleness -- that is the whole point
      ageHours: Math.max(0, now - w.legacy.updatedAt) / 3600,
    },
    events: w.events,
    mode: 'mock',
    updatedAt: Date.now(),
  }
}

export function createMockProvider(): DataProvider {
  let world = seedWorld()
  let timer: ReturnType<typeof setInterval> | undefined
  let emit: ((s: Snapshot) => void) | undefined

  const tick = () => {
    advanceFeeds(world)
    syncState(world, aggregate(feedsOf(world)).reading, false)
    emit?.(snapFromWorld(world))
  }

  return {
    start(onUpdate) {
      emit = onUpdate
      tick()
      timer = setInterval(tick, POLL_MS)
      return () => {
        if (timer) clearInterval(timer)
        emit = undefined
      }
    },
    applyScript(name) {
      world = applyMockScript(world, name)
      emit?.(snapFromWorld(world))
    },
  }
}

// ── live ────────────────────────────────────────────────────────────────────

function decodeReason(reason: number): string {
  return { 1: 'NO_QUORUM', 2: 'AGGREGATOR_FAILED' }[reason] ?? `code=${reason}`
}

async function loadFork(): Promise<ForkShape> {
  try {
    const res = await fetch('/fork.json')
    if (res.ok) return (await res.json()) as ForkShape
  } catch {
    /* bundled example until Kapilan writes deployments/fork.json */
  }
  return bundledFork
}

function parseLegacyCur(word: Hex): { price: number; valid: boolean } {
  const v = BigInt(word)
  return { price: wadToNum(v & ((1n << 128n) - 1n)), valid: v >> 128n === 1n }
}

/** Name the on-chain sources from fork.json addresses, falling back to their slot order. */
function nameFor(addr: string, i: number, fork: ForkShape): string {
  const pretty: Record<string, string> = {
    chainlink: 'Chainlink',
    pyth: 'Pyth',
    redstone: 'RedStone',
    dexTwap: 'DEX TWAP',
    mockA: 'Mock A',
    mockB: 'Mock B',
    mockC: 'Mock C',
  }
  for (const [key, value] of Object.entries(fork.oracleguard.sources ?? {})) {
    try {
      if (getAddress(value) === getAddress(addr)) return pretty[key] ?? key
    } catch {
      /* placeholder address in the example file */
    }
  }
  return SOURCE_NAMES[i] ?? `source[${i}]`
}

async function readSourceCfg(
  client: PublicClient,
  aggregator: Address,
  fork: ForkShape,
): Promise<{ name: string; weight: number; maxAgeSec: number }[]> {
  const count = (await client.readContract({
    address: aggregator,
    abi: aggregatorAbi,
    functionName: 'sourceCount',
  })) as bigint
  const rows = await Promise.all(
    Array.from({ length: Number(count) }, (_, i) =>
      client.readContract({
        address: aggregator,
        abi: aggregatorAbi,
        functionName: 'sourceAt',
        args: [BigInt(i)],
      }) as Promise<readonly [Address, number, number]>,
    ),
  )
  return rows.map(([src, weight, maxAge], i) => ({
    name: nameFor(src, i, fork),
    weight: Number(weight),
    maxAgeSec: Number(maxAge),
  }))
}

async function readLive(
  client: PublicClient,
  fork: ForkShape,
  cfg: { name: string; weight: number; maxAgeSec: number }[],
): Promise<Snapshot> {
  const aggregator = fork.oracleguard.aggregator as Address
  const smartOsm = fork.oracleguard.smartOsm as Address
  const controller = fork.oracleguard.controller as Address
  const vat = fork.maker.vat as Address
  const legacyOsm = fork.maker.legacyOsm as Address
  const head = await client.getBlockNumber()
  const fromBlock = head > 2_000n ? head - 2_000n : 0n

  const [block, reading, obs, price, osmStatus, age, risk, ilk, legacySlot, logs] =
    await Promise.all([
      client.getBlock({ blockNumber: head }),
      client.readContract({
        address: aggregator,
        abi: aggregatorAbi,
        functionName: 'read',
      }) as Promise<{
        mid: bigint
        lo: bigint
        hi: bigint
        score: number
        nFresh: number
        nInliers: number
        freshestAge: bigint
        ok: boolean
      }>,
      client.readContract({
        address: aggregator,
        abi: aggregatorAbi,
        functionName: 'observations',
      }) as Promise<
        readonly [
          readonly { price: bigint; conf: bigint; updatedAt: bigint; ok: boolean }[],
          readonly boolean[],
          readonly boolean[],
        ]
      >,
      client.readContract({
        address: smartOsm,
        abi: osmAbi,
        functionName: 'price',
      }) as Promise<readonly [bigint, bigint, bigint]>,
      client.readContract({
        address: smartOsm,
        abi: osmAbi,
        functionName: 'status',
      }) as Promise<number>,
      client.readContract({
        address: smartOsm,
        abi: osmAbi,
        functionName: 'age',
      }) as Promise<bigint>,
      client.readContract({
        address: controller,
        abi: controllerAbi,
        functionName: 'status',
        args: [ILK],
      }) as Promise<readonly [number, number, boolean, bigint, bigint]>,
      client.readContract({
        address: vat,
        abi: vatAbi,
        functionName: 'ilks',
        args: [ILK],
      }) as Promise<readonly [bigint, bigint, bigint, bigint, bigint]>,
      client.getStorageAt({ address: legacyOsm, slot: toHex(3n) }),
      client
        .getLogs({ address: [smartOsm, controller], fromBlock, toBlock: head })
        .catch(() => []),
    ])

  // chain time, not wall time: the fork is warped around by the scenario buttons
  const now = Number(block.timestamp)
  const [obsList, fresh, inlier] = obs
  const totalWeight = cfg.reduce((a, c) => a + c.weight, 0) || 1
  const sources: Source[] = obsList.map((o, i) => {
    const c = cfg[i] ?? { name: SOURCE_NAMES[i] ?? `source[${i}]`, weight: 1, maxAgeSec: 3600 }
    return {
      name: c.name,
      price: wadToNum(o.price),
      ageSec: Math.max(0, now - Number(o.updatedAt)),
      fresh: fresh[i] ?? false,
      inlier: inlier[i] ?? false,
      weight: c.weight,
      share: c.weight / totalWeight,
      maxAgeSec: c.maxAgeSec,
      counts: (fresh[i] ?? false) && (inlier[i] ?? false),
    }
  })

  const legacy = parseLegacyCur(legacySlot ?? '0x0')
  const [art, rate, , line] = ilk
  const debtFromVat = wadToNum((art * rate) / 10n ** 27n)

  const events: LogEvent[] = []
  for (const log of logs.slice(-40).reverse()) {
    for (const abi of [osmAbi, controllerAbi]) {
      try {
        const decoded = decodeEventLog({ abi, data: log.data, topics: log.topics })
        const raw = decoded.args as unknown
        const args: Record<string, unknown> =
          raw && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {}
        let detail = Object.entries(args)
          .map(([k, v]) => `${k}=${String(v)}`)
          .join(' · ')
        if (decoded.eventName === 'PokeSkipped' && args.reason != null) {
          detail = `reason=${decodeReason(Number(args.reason))} score=${String(args.score ?? '')}`
        }
        events.push({
          id: `${log.transactionHash}-${String(log.logIndex)}`,
          t: now * 1000,
          name: decoded.eventName ?? 'Log',
          detail,
        })
        break
      } catch {
        /* try the next abi */
      }
    }
  }

  const r: Reading = {
    mid: wadToNum(reading.mid),
    lo: wadToNum(reading.lo),
    hi: wadToNum(reading.hi),
    score: Number(reading.score),
    nFresh: Number(reading.nFresh),
    nInliers: Number(reading.nInliers),
    freshestAge: Number(reading.freshestAge),
    ok: reading.ok,
  }
  const state = RISK_STATE[Number(risk[0])] ?? 'GREEN'

  return {
    sources,
    reading: r,
    factors: factorsOf(sources, r),
    osm: {
      cur: wadToNum(price[0]),
      nxt: wadToNum(price[1]),
      ageSec: Number(age),
      status: OSM_STATUS[Number(osmStatus)] ?? 'UNINIT',
    },
    risk: {
      state,
      guard: Boolean(risk[2]),
      lineUsd: radToUsd(risk[3]) || radToUsd(line),
      debtUsd: radToUsd(risk[4]) || debtFromVat,
      reason: `controller score=${Number(risk[1])}`,
    },
    legacy: {
      price: legacy.price,
      valid: legacy.valid,
      ageHours: Number(age) / 3600,
    },
    events,
    mode: 'live',
    updatedAt: Date.now(),
  }
}

export function createLiveProvider(): DataProvider {
  let timer: ReturnType<typeof setInterval> | undefined
  let emit: ((s: Snapshot) => void) | undefined
  let client: PublicClient | undefined
  let cfg: { name: string; weight: number; maxAgeSec: number }[] | undefined

  const poll = async () => {
    try {
      const fork = await loadFork()
      const rpc = import.meta.env.VITE_RPC_URL || fork.rpc || 'http://127.0.0.1:8545'
      if (!client) client = createPublicClient({ chain: foundry, transport: http(rpc) })
      // weights change only through governance, so read them once
      if (!cfg) cfg = await readSourceCfg(client, fork.oracleguard.aggregator as Address, fork)
      emit?.(await readLive(client, fork, cfg))
    } catch (err) {
      cfg = undefined
      emit?.({
        ...snapFromWorld(seedWorld()),
        mode: 'live',
        error: err instanceof Error ? err.message : String(err),
        updatedAt: Date.now(),
      })
    }
  }

  return {
    start(onUpdate) {
      emit = onUpdate
      void poll()
      timer = setInterval(() => void poll(), POLL_MS)
      return () => {
        if (timer) clearInterval(timer)
        emit = undefined
      }
    },
    applyScript() {
      /* J3: viem test actions against anvil */
    },
  }
}

let singleton: DataProvider | undefined

export function getProvider(): DataProvider {
  if (!singleton) {
    singleton = mode() === 'live' ? createLiveProvider() : createMockProvider()
  }
  return singleton
}

export function formatAge(sec: number): string {
  if (sec < 90) return `${Math.round(sec)}s`
  if (sec < 3600) return `${Math.round(sec / 60)}m`
  if (sec < 86400) return `${(sec / 3600).toFixed(1)}h`
  return `${(sec / 86400).toFixed(1)}d`
}

export function formatPrice(n: number): string {
  if (!Number.isFinite(n) || n === 0) return '—'
  return `$${n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
}

export function formatUsdCompact(n: number): string {
  return `$${n.toLocaleString('en-US', { maximumFractionDigits: 0 })}`
}

export function formatPct(x: number): string {
  return `${(x * 100).toFixed(1)}%`
}
