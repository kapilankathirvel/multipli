/**
 * Score check: src/protocol.ts must reproduce the worked vectors of review.md §R1.4
 * (same feed inputs, same median / outlier / band results).
 *
 * The scores are for the ADDITIVE formula agreed on Sep 19:
 *   score = floor(100 * (0.5*Wq + 0.3*Wd + 0.2*Wf)) - volPenalty      (0 without quorum)
 * The old product-formula scores are kept in `was` so the contract port can be checked
 * against both (OracleGuardAggregator._score still multiplies until Kapilan updates it).
 *
 *   node --experimental-strip-types scripts/parity.mjs      (or: pnpm check:parity)
 */
import { P as CFG, aggregate } from '../src/protocol.ts'

const P = 4372.478
const STALE = 99 * 3600 // older than any maxAge

/** weights + maxAge per review.md §R1.1 */
const cfg = [
  { name: 'Chainlink', weight: 2, maxAgeSec: 25 * 3600 },
  { name: 'Pyth', weight: 2, maxAgeSec: 3600 },
  { name: 'RedStone', weight: 2, maxAgeSec: 3600 },
  { name: 'DEX TWAP', weight: 1, maxAgeSec: 3600 },
]

const feeds = (prices, ages = [10, 10, 10, 10]) =>
  cfg.map((c, i) => ({ ...c, price: prices[i], ageSec: ages[i], ok: true }))

const vectors = [
  { id: 'V-a all agree', feeds: feeds([P, P, P, P]), mid: P, score: 100, was: 100 },
  { id: 'V-b DEX x10', feeds: feeds([P, P, P, 10 * P]), mid: P, score: 92, was: 85 },
  {
    id: 'V-c Chainlink stale',
    feeds: feeds([P, P, P, P], [STALE, 10, 10, 10]),
    mid: P,
    score: 85,
    was: 71,
  },
  { id: 'V-d 0.5% split', feeds: feeds([P, P, 1.005 * P, 1.005 * P]), mid: P, score: 92, was: 75 },
  // a 16.7% spread zeroes Wd, but in a sum that no longer zeroes the score. The SmartOSM
  // jump quarantine still stops this price: +20% > 5% jump limit with score < 80.
  { id: 'V-e 2 majors x1.2', feeds: feeds([P, 1.2 * P, 1.2 * P, P]), mid: 1.2 * P, score: 70, was: 0 },
]

let failed = 0
for (const v of vectors) {
  const { reading, factors } = aggregate(v.feeds)
  const okMid = Math.abs(reading.mid - v.mid) < 1e-6
  const okScore = reading.score === v.score
  if (!okMid || !okScore) failed++
  console.log(
    `${okMid && okScore ? 'PASS' : 'FAIL'}  ${v.id.padEnd(22)} mid=${reading.mid.toFixed(3)} (want ${v.mid.toFixed(3)})` +
      `  score=${reading.score} (want ${v.score}, product formula ${v.was})` +
      `  Wq=${factors.wq.toFixed(3)} Wd=${factors.wd.toFixed(3)} Wf=${factors.wf.toFixed(3)}`,
  )
}

// V-e must still be stopped before it reaches `cur`: SmartOSM quarantines it
const ve = aggregate(vectors[4].feeds).reading
const quarantined = ve.mid / P - 1 > CFG.jumpLimitBps / 10_000 && ve.score < CFG.jumpMinScore
if (!quarantined) failed++
console.log(
  `${quarantined ? 'PASS' : 'FAIL'}  V-e is quarantined by SmartOSM (jump +20% > 5%, score ${ve.score} < ${CFG.jumpMinScore})`,
)

console.log(failed === 0 ? '\nAll review.md §R1.4 vectors reproduced.' : `\n${failed} vector(s) failed.`)
process.exit(failed === 0 ? 0 : 1)
