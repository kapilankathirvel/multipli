import {
  createPublicClient,
  decodeEventLog,
  formatUnits,
  getAddress,
  http,
  parseAbi,
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
import { fetchMainnet, type MainnetData, type RealFeed } from './mainnet'
import {
  P,
  aggregate,
  deriveState,
  factorsOf,
  lineFor,
  scoreOf,
  type Factors,
  type Feed,
  type OsmStatus,
  type Reading,
  type RiskState,
  type Source,
} from './protocol'

export type { Factors, Reading, Source } from './protocol'
export { effectsFor, P, pointsOf } from './protocol'

const aggregatorAbi = aggregatorAbiJson as Abi
const osmAbi = osmAbiJson as Abi
const controllerAbi = controllerAbiJson as Abi
const vatAbi = vatAbiJson as Abi
const spotterAbi = parseAbi(['function ilks(bytes32) view returns (address pip, uint256 mat)'])

/** bytes32("paxg") */
export const ILK =
  '0x7061786700000000000000000000000000000000000000000000000000000000' as Hex

export const SOURCE_NAMES = ['Chainlink', 'Pyth', 'RedStone', 'DEX TWAP'] as const

/**
 * Weight and maxAge per source: the same values script/DeployLib.sol configures on the
 * fork (review.md R1.1). Fork mode reads them from the aggregator instead.
 */
const SOURCE_CFG: Record<RealFeed['key'], { name: string; weight: number; maxAgeSec: number }> = {
  chainlink: { name: 'Chainlink', weight: 2, maxAgeSec: 25 * 3600 },
  pyth: { name: 'Pyth', weight: 2, maxAgeSec: 3600 },
  redstone: { name: 'RedStone', weight: 2, maxAgeSec: 3600 },
  dexTwap: { name: 'DEX TWAP', weight: 1, maxAgeSec: 3600 },
}

/**
 * mainnet: real Ethereum-mainnet feeds + Maker state, OracleGuard modelled in the browser
 * fork:    a local anvil fork with OracleGuard really deployed (Deploy + Spell), read on-chain
 */
export type Mode = 'mainnet' | 'fork'

export type OsmState = {
  cur: number
  nxt: number
  ageSec: number
  status: OsmStatus
}

export type Risk = {
  state: RiskState
  guard: boolean
  /** the debt ceiling OracleGuard sets for this state */
  lineUsd: number
  debtUsd: number
  /** why the controller is in this state */
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
  mode: Mode
  block: number
  sources: Source[]
  reading: Reading
  factors: Factors
  /** fork only: the score the deployed aggregator computes (old product formula until ported) */
  chainScore?: number
  osm: OsmState
  risk: Risk
  /** the Vat's own numbers for ilk paxg: debt and the debt ceiling currently in force */
  vat: { debtUsd: number; lineUsd: number }
  /** Spotter.mat: collateral ratio (1.40 = borrow up to 1/1.4 of the collateral value) */
  mat: number
  legacy: Legacy
  events: LogEvent[]
  updatedAt: number
}

export type BorrowStatus = 'open' | 'limited' | 'frozen'

export type ScriptName = 'reset' | 's1' | 's2' | 's3' | 's4' | 'poke' | 'sync' | 'warp1h'

export type DataProvider = {
  start(onUpdate: (snap: Snapshot) => void, onError: (msg: string) => void): () => void
  /** mainnet mode: the scenario buttons apply their faults on top of the real feeds */
  applyScript(name: ScriptName): void
}

const OSM_STATUS: OsmStatus[] = ['UNINIT', 'LIVE', 'STALE', 'QUARANTINED', 'STOPPED']
const RISK_STATE: RiskState[] = ['GREEN', 'YELLOW', 'RED']

const TICK_MS = 2000
const MAINNET_FETCH_MS = 6000 // ~ half a block; public RPC friendly

export type ForkShape = {
  rpc: string
  snapshotId?: string
  oracleguard: {
    aggregator: string
    smartOsm: string
    controller: string
    /** written by script/Deploy.s.sol: chainlink | pyth | redstone | dexTwap */
    sources?: Record<string, string>
  }
  maker: {
    vat: string
    spotter?: string
    legacyOsm: string
  }
}

const bundledFork = forkExample as ForkShape

export function mode(): Mode {
  const m = import.meta.env.VITE_MODE
  return m === 'fork' || m === 'live' ? 'fork' : 'mainnet'
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

// ── mainnet ─────────────────────────────────────────────────────────────────
//
// Inputs are real (mainnet.ts). OracleGuard is not deployed on mainnet, so its SmartOSM
// and RiskController run here, on protocol.ts. The scenario buttons never invent prices:
// they apply a fault (time warp, publishers down, a multiplier) on top of the real feeds.

type World = {
  data: MainnetData
  warp: number // simulated seconds added by the buttons
  frozen?: RealFeed[] // S1: publishers stopped at this snapshot
  clMul: number // S3: compromised Chainlink multiplier
  fastMul: number // S2: the fast feeds move, Chainlink lags
  wickMul: number // S4: a short-lived dip on every feed
  osm: { cur: number; nxt: number; lastGoodAt: number; zzz: number; quarantined: boolean }
  keeperTriedAt: number
  state: RiskState
  guard: boolean
  events: LogEvent[]
}

function realNow(): number {
  return Math.floor(Date.now() / 1000)
}

function simNow(w: World): number {
  return realNow() + w.warp
}

function feedsOf(w: World): Feed[] {
  // publishers keep publishing in real time, so a live feed's age uses the real clock;
  // once S1 stops them, their age runs on the (warped) simulated clock
  const base = w.frozen ?? w.data.feeds
  const now = w.frozen ? simNow(w) : realNow()
  return base.map((f) => {
    const cfg = SOURCE_CFG[f.key]
    const mul = (f.key === 'chainlink' ? w.clMul : w.fastMul) * w.wickMul
    return {
      ...cfg,
      price: f.price * mul,
      ageSec: f.ok ? Math.max(0, now - f.updatedAt) : 0,
      ok: f.ok,
      via: f.via,
    }
  })
}

function readingOf(w: World): Reading {
  return aggregate(feedsOf(w)).reading
}

function osmStatusOf(w: World): OsmStatus {
  if (w.osm.quarantined) return 'QUARANTINED'
  if (simNow(w) - w.osm.lastGoodAt > P.staleLimitSec) return 'STALE'
  return 'LIVE'
}

function debtOf(w: World): number {
  return w.data.vat.debtUsd
}

/** The keeper's `sync()`: recompute state + guard and log what changed. */
function syncState(w: World, loud: boolean): void {
  const reading = readingOf(w)
  const v = deriveState(reading, w.osm.cur, osmStatusOf(w))
  if (v.state !== w.state) {
    w.events = pushEvent(w.events, 'StateChanged', `${w.state} → ${v.state} (${v.reason})`)
    w.state = v.state
  }
  if (v.guard !== w.guard) {
    w.events = pushEvent(
      w.events,
      v.guard ? 'GuardOn' : 'GuardOff',
      v.guard ? 'Dog.hole = 0, new liquidations paused' : 'Dog.hole restored',
    )
    w.guard = v.guard
  }
  if (loud) {
    w.events = pushEvent(
      w.events,
      'Synced',
      `state=${w.state} score=${reading.score} line=$${fmtUsd(lineFor(w.state, debtOf(w)))} guard=${w.guard ? 'on' : 'off'}`,
    )
  }
}

/** Mirrors SmartOSM.poke: quorum check, upward-jump quarantine (ADR-011), cur ← nxt ← mid. */
function pokeOsm(w: World): void {
  const now = simNow(w)
  w.keeperTriedAt = now
  const reading = readingOf(w)
  if (!reading.ok || reading.mid === 0) {
    // zzz is NOT advanced (same as the contract), so the price keeps ageing -> STALE
    w.events = pushEvent(w.events, 'PokeSkipped', `reason=NO_QUORUM score=${reading.score}`)
    return
  }
  const jumpBps = w.osm.nxt > 0 ? (Math.abs(reading.mid - w.osm.nxt) / w.osm.nxt) * 10_000 : 0
  if (
    reading.mid > w.osm.nxt &&
    jumpBps > P.jumpLimitBps &&
    reading.score < P.jumpMinScore &&
    !w.osm.quarantined
  ) {
    w.osm.cur = w.osm.nxt
    w.osm.quarantined = true
    w.osm.zzz = now
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

/** SmartOSM.poke reverts `OSM/not-passed` before zzz + hop, so jump the clock there first. */
function waitForHop(w: World): void {
  const due = w.osm.zzz + P.hopSec - simNow(w)
  if (due > 0) w.warp += due
}

/** State right after the spell: SmartOSM primed from the legacy OSM's price, controller synced. */
function seedWorld(data: MainnetData): World {
  const now = realNow()
  const w: World = {
    data,
    warp: 0,
    clMul: 1,
    fastMul: 1,
    wickMul: 1,
    osm: {
      cur: data.legacy.price,
      nxt: data.legacy.price,
      lastGoodAt: now,
      zzz: now,
      quarantined: false,
    },
    keeperTriedAt: now,
    state: 'GREEN',
    guard: false,
    events: [],
  }
  const r = readingOf(w)
  if (r.ok) w.osm.nxt = r.mid
  w.events = pushEvent([], 'Init', `SmartOSM primed from the legacy OSM price $${fmtUsd(data.legacy.price)}`)
  syncState(w, true)
  return w
}

function applyScript(w: World, script: ScriptName): World {
  switch (script) {
    case 'reset': {
      const fresh = seedWorld(w.data)
      fresh.events = pushEvent(fresh.events, 'Reset', 'faults cleared, back to the real feeds')
      return fresh
    }

    case 's1': {
      // publishers go down, then 26h pass: every feed ages past its maxAge
      w.frozen = w.data.feeds.map((f) => ({ ...f }))
      w.warp += 26 * 3600
      w.events = pushEvent(w.events, 'Scenario', 'S1 stale feed: publishers down, +26h')
      pokeOsm(w)
      syncState(w, true)
      return w
    }

    case 's2': {
      // a real 8% drop: the fast feeds follow, Chainlink (deviation feed) still quotes the old price
      w.fastMul *= 0.92
      w.events = pushEvent(w.events, 'Scenario', 'S2 market −8%: fast feeds follow, Chainlink lags')
      syncState(w, true)
      return w
    }

    case 's3': {
      // one compromised source reports 10x
      w.clMul = 10
      w.events = pushEvent(w.events, 'Scenario', 'S3 compromised source: Chainlink ×10')
      waitForHop(w)
      pokeOsm(w)
      syncState(w, true)
      return w
    }

    case 's4': {
      // captured wick: every feed dips 15% for two hops, the OSM captures it as `cur`, then it recovers
      w.wickMul = 0.85
      w.events = pushEvent(w.events, 'Scenario', 'S4 captured wick: all sources −15%')
      waitForHop(w)
      pokeOsm(w)
      waitForHop(w)
      pokeOsm(w) // the wick is now `cur`, the price every vault is valued at
      w.wickMul = 1
      syncState(w, true)
      return w
    }

    case 'poke': {
      waitForHop(w)
      pokeOsm(w)
      syncState(w, false)
      return w
    }

    case 'sync': {
      syncState(w, true)
      return w
    }

    case 'warp1h': {
      w.warp += P.hopSec
      w.events = pushEvent(w.events, 'Warp', '+1h')
      pokeOsm(w)
      syncState(w, false)
      return w
    }
  }
}

function snapFromWorld(w: World): Snapshot {
  const { sources, reading, factors } = aggregate(feedsOf(w))
  const now = simNow(w)
  const status = osmStatusOf(w)
  return {
    mode: 'mainnet',
    block: w.data.block,
    sources,
    reading,
    factors,
    osm: {
      cur: w.osm.cur,
      nxt: w.osm.nxt,
      ageSec: Math.max(0, now - w.osm.lastGoodAt),
      status,
    },
    risk: {
      state: w.state,
      guard: w.guard,
      lineUsd: lineFor(w.state, debtOf(w)),
      debtUsd: debtOf(w),
      reason: deriveState(reading, w.osm.cur, status).reason,
    },
    vat: w.data.vat,
    mat: w.data.mat,
    legacy: {
      // the legacy stack reads Chainlink through the adapter, so S3's x10 reaches it too
      price: w.data.legacy.price * w.clMul,
      valid: w.data.legacy.valid,
      ageHours: Math.max(0, now - w.data.legacy.zzz) / 3600,
    },
    events: w.events,
    updatedAt: Date.now(),
  }
}

export function createMainnetProvider(): DataProvider {
  let world: World | undefined
  let emit: ((s: Snapshot) => void) | undefined
  let fail: ((msg: string) => void) | undefined
  const timers: ReturnType<typeof setInterval>[] = []

  const fetchNow = async () => {
    try {
      const data = await fetchMainnet()
      if (!world) world = seedWorld(data)
      else world.data = data
      tick()
    } catch (err) {
      fail?.(`Mainnet read failed: ${err instanceof Error ? err.message.split('\n')[0] : String(err)}`)
    }
  }

  const tick = () => {
    if (!world) return
    // a keeper pokes once per hop, like production; skipped pokes are retried a hop later
    const now = simNow(world)
    if (now - world.osm.zzz >= P.hopSec && now - world.keeperTriedAt >= P.hopSec) {
      world.keeperTriedAt = now
      pokeOsm(world)
    }
    syncState(world, false)
    emit?.(snapFromWorld(world))
  }

  return {
    start(onUpdate, onError) {
      emit = onUpdate
      fail = onError
      void fetchNow()
      timers.push(setInterval(() => void fetchNow(), MAINNET_FETCH_MS))
      timers.push(setInterval(tick, TICK_MS))
      return () => {
        timers.forEach(clearInterval)
        emit = undefined
        fail = undefined
      }
    },
    applyScript(name) {
      if (!world) return
      world = applyScript(world, name)
      emit?.(snapFromWorld(world))
    },
  }
}

// ── fork ────────────────────────────────────────────────────────────────────

function decodeReason(reason: number): string {
  return { 1: 'NO_QUORUM', 2: 'AGGREGATOR_FAILED' }[reason] ?? `code=${reason}`
}

const WAD_ARGS = new Set(['mid', 'osmCur', 'candidate', 'nxt', 'price'])

/**
 * Turns raw decoded event args into something a human can read in the log:
 * WAD/RAD integers become dollars, state codes become names. Returns null to hide an
 * arg (the ilk is always paxg; Poke's second field is the hop timestamp, not an age).
 */
function formatEventArg(key: string, value: unknown): string | null {
  const usd = (n: number) => `$${n.toLocaleString('en-US', { maximumFractionDigits: 2 })}`
  if (key === 'ilk' || key === 'age') return null
  if (key === 'reason') return `reason=${decodeReason(Number(value))}`
  if (key === 'state' || key === 'from' || key === 'to')
    return `${key}=${RISK_STATE[Number(value)] ?? String(value)}`
  if (key === 'val') return `cur=${usd(wadToNum(BigInt(value as Hex)))}` // Poke(bytes32 cur, …)
  if (key === 'lineRad') return `line=${usd(radToUsd(value as bigint))}`
  if (WAD_ARGS.has(key) && typeof value === 'bigint') return `${key}=${usd(wadToNum(value))}`
  return `${key}=${String(value)}`
}

export async function loadFork(): Promise<ForkShape> {
  try {
    const res = await fetch('/fork.json')
    if (res.ok) return (await res.json()) as ForkShape
  } catch {
    /* bundled example until Deploy writes deployments/fork.json */
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

type SourceCfg = { name: string; weight: number; maxAgeSec: number }

async function readSourceCfg(
  client: PublicClient,
  aggregator: Address,
  fork: ForkShape,
): Promise<SourceCfg[]> {
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

async function readFork(client: PublicClient, fork: ForkShape, cfg: SourceCfg[]): Promise<Snapshot> {
  const aggregator = fork.oracleguard.aggregator as Address
  const smartOsm = fork.oracleguard.smartOsm as Address
  const controller = fork.oracleguard.controller as Address
  const vat = fork.maker.vat as Address
  const legacyOsm = fork.maker.legacyOsm as Address
  // cacheTime 0: viem caches the head for ~4s by default, which made ages and the event
  // log lag one poll behind every scenario button (found on the first live anvil run)
  const head = await client.getBlockNumber({ cacheTime: 0 })
  const fromBlock = head > 2_000n ? head - 2_000n : 0n

  const [block, reading, obs, price, osmStatus, age, risk, ilk, legacySlot, logs, spot] =
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
      fork.maker.spotter
        ? client
            .readContract({
              address: fork.maker.spotter as Address,
              abi: spotterAbi,
              functionName: 'ilks',
              args: [ILK],
            })
            .catch(() => null)
        : Promise.resolve(null),
    ])

  // the legacy OSM is a Maker OSM: `zzz` is the last accepted update, so its true age
  // is independent of SmartOSM's (this is what "VALID forever" looks like)
  const legacyZzz = (await client
    .readContract({ address: legacyOsm, abi: osmAbi, functionName: 'zzz' })
    .catch(() => 0n)) as bigint

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
      via: c.name === 'Chainlink' ? 'real Chainlink feed (forked)' : 'MockSource (demo-controlled)',
    }
  })

  const legacy = parseLegacyCur(legacySlot ?? '0x0')
  const [art, rate, , line] = ilk
  const debtFromVat = radToUsd(art * rate)

  const events: LogEvent[] = []
  for (const log of logs.slice(-40).reverse()) {
    for (const abi of [osmAbi, controllerAbi]) {
      try {
        const decoded = decodeEventLog({ abi, data: log.data, topics: log.topics })
        const raw = decoded.args as unknown
        const args: Record<string, unknown> =
          raw && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {}
        const detail = Object.entries(args)
          .map(([k, v]) => formatEventArg(k, v))
          .filter((s): s is string => s !== null)
          .join(' · ')
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
    score: 0,
    nFresh: Number(reading.nFresh),
    nInliers: Number(reading.nInliers),
    freshestAge: Number(reading.freshestAge),
    ok: reading.ok,
  }
  // the dashboard shows the agreed additive score; the deployed contract may still multiply
  const factors = factorsOf(sources, r)
  r.score = scoreOf(factors, r.ok)
  const state = RISK_STATE[Number(risk[0])] ?? 'GREEN'
  const osm: OsmState = {
    cur: wadToNum(price[0]),
    nxt: wadToNum(price[1]),
    ageSec: Number(age),
    status: OSM_STATUS[Number(osmStatus)] ?? 'UNINIT',
  }
  const model = deriveState(r, osm.cur, osm.status)

  return {
    mode: 'fork',
    block: Number(head),
    sources,
    reading: r,
    factors,
    chainScore: Number(reading.score),
    osm,
    risk: {
      state,
      guard: Boolean(risk[2]),
      lineUsd: radToUsd(risk[3]) || radToUsd(line),
      debtUsd: radToUsd(risk[4]) || debtFromVat,
      reason:
        model.state === state
          ? model.reason
          : `set on-chain by the RiskController (its score = ${Number(risk[1])})`,
    },
    vat: { debtUsd: debtFromVat, lineUsd: radToUsd(line) },
    mat: spot ? Number(formatUnits(spot[1], 27)) : 1.4,
    legacy: {
      price: legacy.price,
      valid: legacy.valid,
      ageHours: legacyZzz > 0n ? Math.max(0, now - Number(legacyZzz)) / 3600 : Number(age) / 3600,
    },
    events,
    updatedAt: Date.now(),
  }
}

export function createForkProvider(): DataProvider {
  let timer: ReturnType<typeof setInterval> | undefined
  let emit: ((s: Snapshot) => void) | undefined
  let fail: ((msg: string) => void) | undefined
  let client: PublicClient | undefined
  let cfg: SourceCfg[] | undefined

  const poll = async () => {
    try {
      const fork = await loadFork()
      const rpc = import.meta.env.VITE_RPC_URL || fork.rpc || 'http://127.0.0.1:8545'
      if (!client) client = createPublicClient({ chain: foundry, transport: http(rpc) })
      // weights change only through governance, so read them once
      if (!cfg) cfg = await readSourceCfg(client, fork.oracleguard.aggregator as Address, fork)
      emit?.(await readFork(client, fork, cfg))
    } catch (err) {
      cfg = undefined
      fail?.(`Fork RPC failed: ${err instanceof Error ? err.message.split('\n')[0] : String(err)}`)
    }
  }

  return {
    start(onUpdate, onError) {
      emit = onUpdate
      fail = onError
      void poll()
      timer = setInterval(() => void poll(), TICK_MS)
      return () => {
        if (timer) clearInterval(timer)
        emit = undefined
        fail = undefined
      }
    },
    applyScript() {
      /* fork mode: scenarios.ts drives anvil directly */
    },
  }
}

let singleton: DataProvider | undefined

export function getProvider(): DataProvider {
  if (!singleton) {
    singleton = mode() === 'fork' ? createForkProvider() : createMainnetProvider()
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
