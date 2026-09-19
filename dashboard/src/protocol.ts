/**
 * A floating-point model of OracleGuard, used for two things:
 *  1. mainnet mode: OracleGuard is not deployed on mainnet, so the dashboard runs this
 *     model on the *real* mainnet feeds (every number it shows is derived, none is typed in)
 *  2. the score breakdown shown next to the score in both modes
 *
 * Score (Sep 19, team decision): an ADDITIVE score, so a volatility penalty can later be
 * subtracted from it:
 *     score = clamp(0..100, floor(100 * (0.5*Wq + 0.3*Wd + 0.2*Wf)) - volPenalty)
 *     score = 0 when fewer than 2 feeds agree (no quorum)
 * The contract (OracleGuardAggregator._score) still multiplies until Kapilan ports this.
 *
 * Sources of truth: contracts/src/OracleGuardAggregator.sol (steps 1-4: freshness,
 * weighted median, MAD outliers, band) and review.md R3 (what each state changes).
 */

/** Aggregator params (contract defaults) + controller params (review.md R3). */
export const P = {
  // aggregator
  quorumMin: 2,
  dMaxBps: 200, // dispersion at which Wd hits 0 -> 2%
  madK: 3,
  madFloorBps: 10, // 0.1% of the median
  // SmartOSM
  staleLimitSec: 7200, // 2h -> status STALE
  hopSec: 3600,
  jumpLimitBps: 500, // 5% -- only UPWARD jumps are quarantined (ADR-011)
  jumpMinScore: 80,
  // score = 100 * (q*Wq + d*Wd + f*Wf) - volPenalty (weights sum to 1)
  scoreWeights: { q: 0.5, d: 0.3, f: 0.2 },
  volPenalty: 0, // placeholder: the volatility penalty plugs in here
  // RiskController (review.md R3): GREEN >= 80, YELLOW 40-79, RED < 40
  greenScore: 80,
  yellowScore: 40,
  epsBps: 150, // live.lo below OSM*(1-1.5%) -> RED
  guardEpsBps: 300, // live.hi*(1-3%) above OSM -> guard
  lineCapUsd: 1_000_000,
  greenGapUsd: 250_000,
  yellowGapUsd: 50_000,
  holeUsd: 400_000,
  guardMaxSec: 6 * 3600,
} as const

export type Feed = {
  name: string
  weight: number
  maxAgeSec: number
  price: number
  ageSec: number
  ok: boolean
  /** where the number comes from, e.g. "Uniswap v3 PAXG/USDC 30-min TWAP" */
  via?: string
}

export type Source = {
  name: string
  price: number
  ageSec: number
  fresh: boolean
  inlier: boolean
  /** governance weight (2/2/2/1 for Chainlink/Pyth/RedStone/DEX) */
  weight: number
  /** weight / total weight -- this source's share of the price AND of Wq (review.md R1.3) */
  share: number
  maxAgeSec: number
  /** does it currently count towards confidence? (fresh AND inlier) */
  counts: boolean
  via?: string
}

export type Factors = { wq: number; wd: number; wf: number; dBps: number }

export type Reading = {
  mid: number
  lo: number
  hi: number
  score: number
  nFresh: number
  nInliers: number
  freshestAge: number
  ok: boolean
}

export type RiskState = 'GREEN' | 'YELLOW' | 'RED'
export type OsmStatus = 'UNINIT' | 'LIVE' | 'STALE' | 'QUARANTINED' | 'STOPPED'

// ── aggregator ──────────────────────────────────────────────────────────────

function weightedMedian(sorted: { price: number; weight: number }[]): number {
  const total = sorted.reduce((a, s) => a + s.weight, 0)
  let cum = 0
  for (const s of sorted) {
    cum += s.weight
    if (cum * 2 >= total) return s.price
  }
  return sorted[sorted.length - 1]?.price ?? 0
}

function median(v: number[]): number {
  if (v.length === 0) return 0
  const s = [...v].sort((a, b) => a - b)
  const h = s.length >> 1
  return s.length % 2 === 1 ? s[h] : (s[h - 1] + s[h]) / 2
}

/** The three 0-1 factors the score is built from (same definitions as `_score()` on-chain). */
export function factorsOf(sources: Source[], r: Pick<Reading, 'mid' | 'lo' | 'hi' | 'ok'>): Factors {
  const totalWeight = sources.reduce((a, s) => a + s.weight, 0) || 1
  const inlierWeight = sources.filter((s) => s.counts).reduce((a, s) => a + s.weight, 0)
  const wq = Math.min(1, inlierWeight / totalWeight)

  const dBps = r.mid > 0 ? ((r.hi - r.lo) / r.mid) * 10_000 : 0
  const counting = sources.filter((s) => s.counts)
  // with nothing counted there is no agreement to measure (a sum must not award these points)
  const wd = counting.length > 0 ? Math.max(0, 1 - dBps / P.dMaxBps) : 0

  let wf = 0
  if (counting.length > 0) {
    const freshest = counting.reduce((a, s) => (s.ageSec < a.ageSec ? s : a))
    const half = freshest.maxAgeSec / 2
    wf = freshest.ageSec <= half ? 1 : Math.max(0, 1 - (freshest.ageSec - half) / half)
  }
  return { wq, wd, wf, dBps }
}

/** Points each factor adds to the score (they sum to the score before the penalty). */
export function pointsOf(f: Factors): { q: number; d: number; f: number } {
  const w = P.scoreWeights
  return { q: 100 * w.q * f.wq, d: 100 * w.d * f.wd, f: 100 * w.f * f.wf }
}

export function scoreOf(f: Factors, ok: boolean): number {
  if (!ok) return 0
  const pts = pointsOf(f)
  // floor like Solidity's integer division; 1e-9 absorbs float noise (0.3 * 100 = 30.000000000000004)
  return Math.max(0, Math.min(100, Math.floor(pts.q + pts.d + pts.f + 1e-9) - P.volPenalty))
}

/** Full aggregator pass: freshness -> weighted median -> MAD outliers -> band -> score. */
export function aggregate(feeds: Feed[]): { sources: Source[]; reading: Reading; factors: Factors } {
  const totalWeight = feeds.reduce((a, f) => a + f.weight, 0) || 1
  const fresh = feeds.map((f) => f.ok && f.price > 0 && f.ageSec <= f.maxAgeSec)

  const sortedFresh = feeds
    .map((f, i) => ({ ...f, i }))
    .filter((f) => fresh[f.i])
    .sort((a, b) => a.price - b.price)

  const inlier = feeds.map(() => false)
  if (sortedFresh.length > 0) {
    const m0 = weightedMedian(sortedFresh)
    const mad = median(sortedFresh.map((f) => Math.abs(f.price - m0)))
    const thr = P.madK * Math.max(mad, (m0 * P.madFloorBps) / 10_000)
    for (const f of sortedFresh) if (Math.abs(f.price - m0) <= thr) inlier[f.i] = true
  }

  const sources: Source[] = feeds.map((f, i) => ({
    name: f.name,
    price: f.price,
    ageSec: f.ageSec,
    fresh: fresh[i],
    inlier: inlier[i],
    weight: f.weight,
    share: f.weight / totalWeight,
    maxAgeSec: f.maxAgeSec,
    counts: fresh[i] && inlier[i],
    via: f.via,
  }))

  const inl = sortedFresh.filter((f) => inlier[f.i])
  const reading: Reading = {
    mid: inl.length > 0 ? weightedMedian(inl) : 0,
    lo: inl.length > 0 ? inl[0].price : 0,
    hi: inl.length > 0 ? inl[inl.length - 1].price : 0,
    score: 0,
    nFresh: sortedFresh.length,
    nInliers: inl.length,
    freshestAge: inl.length > 0 ? Math.min(...inl.map((f) => f.ageSec)) : 0,
    ok: inl.length >= P.quorumMin,
  }
  const factors = factorsOf(sources, reading)
  reading.score = scoreOf(factors, reading.ok)
  return { sources, reading, factors }
}

// ── controller (review.md R3) ───────────────────────────────────────────────

export type StateVerdict = { state: RiskState; guard: boolean; reason: string }

export function deriveState(
  r: Pick<Reading, 'lo' | 'hi' | 'score' | 'ok'>,
  osmCur: number,
  osmStatus: OsmStatus,
): StateVerdict {
  const floorPrice = osmCur * (1 - P.epsBps / 10_000)
  const guard = r.ok && r.score >= P.greenScore && r.hi * (1 - P.guardEpsBps / 10_000) > osmCur

  if (!r.ok) return { state: 'RED', guard: false, reason: 'no quorum (< 2 inliers)' }
  if (osmStatus === 'STALE' || osmStatus === 'QUARANTINED' || osmStatus === 'STOPPED')
    return { state: 'RED', guard, reason: `OSM ${osmStatus}` }
  if (r.score < P.yellowScore)
    return { state: 'RED', guard, reason: `score ${r.score} < ${P.yellowScore}` }
  if (r.lo < floorPrice)
    return { state: 'RED', guard, reason: 'live.lo below OSM - 1.5% (price falling)' }
  if (r.score < P.greenScore)
    return { state: 'YELLOW', guard, reason: `score ${r.score} < ${P.greenScore}` }
  return { state: 'GREEN', guard, reason: `score ${r.score} and live.lo within 1.5% of OSM` }
}

/** Vat.line the controller would write for this state (review.md R3). */
export function lineFor(state: RiskState, debtUsd: number): number {
  if (state === 'RED') return debtUsd
  const gap = state === 'GREEN' ? P.greenGapUsd : P.yellowGapUsd
  return Math.min(debtUsd + gap, P.lineCapUsd)
}

export type EffectRow = { label: string; value: string; tone: 'ok' | 'warn' | 'bad' | 'flat' }

/** The review.md R3 table row for the current state -- rendered by StateEffects. */
export function effectsFor(state: RiskState, guard: boolean, debtUsd: number): EffectRow[] {
  const line = lineFor(state, debtUsd)
  const usd = (n: number) => `$${n.toLocaleString('en-US', { maximumFractionDigits: 0 })}`

  const borrow: EffectRow =
    state === 'GREEN'
      ? { label: 'Borrow new rwaUSD', value: `up to ${usd(P.greenGapUsd)}/h`, tone: 'ok' }
      : state === 'YELLOW'
        ? { label: 'Borrow new rwaUSD', value: `limited to ${usd(P.yellowGapUsd)} total`, tone: 'warn' }
        : { label: 'Borrow new rwaUSD', value: 'frozen (Vat/ceiling-exceeded)', tone: 'bad' }

  return [
    borrow,
    { label: 'Repay debt', value: 'always allowed', tone: 'ok' },
    { label: 'Open vault / deposit', value: 'allowed', tone: 'ok' },
    { label: 'Withdraw (stays safe)', value: 'allowed', tone: 'ok' },
    guard
      ? { label: 'New liquidations', value: `paused - Dog.hole = 0 (max ${P.guardMaxSec / 3600}h)`, tone: 'warn' }
      : { label: 'New liquidations', value: `open - Dog.hole = ${usd(P.holeUsd)}`, tone: 'ok' },
    { label: 'Running auctions', value: 'unaffected', tone: 'ok' },
    {
      label: 'Vat.line',
      value: state === 'RED' ? `= debt ${usd(line)}` : usd(line),
      tone: state === 'GREEN' ? 'ok' : state === 'YELLOW' ? 'warn' : 'bad',
    },
    { label: 'Spotter.mat', value: 'never touched (ADR-001)', tone: 'flat' },
  ]
}
