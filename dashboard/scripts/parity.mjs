/**
 * Parity check: the dashboard's copy of the score formula (src/protocol.ts) must
 * reproduce the worked vectors in review.md §R1.4 exactly -- same numbers the
 * Solidity aggregator and Varun's Python model are checked against.
 *
 *   node --experimental-strip-types scripts/parity.mjs      (or: pnpm check:parity)
 */
import { aggregate } from '../src/protocol.ts'

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
  { id: 'V-a all agree', feeds: feeds([P, P, P, P]), mid: P, score: 100 },
  { id: 'V-b DEX x10', feeds: feeds([P, P, P, 10 * P]), mid: P, score: 85 },
  {
    id: 'V-c Chainlink stale',
    feeds: feeds([P, P, P, P], [STALE, 10, 10, 10]),
    mid: P,
    score: 71,
  },
  { id: 'V-d 0.5% split', feeds: feeds([P, P, 1.005 * P, 1.005 * P]), mid: P, score: 75 },
  { id: 'V-e 2 majors x1.2', feeds: feeds([P, 1.2 * P, 1.2 * P, P]), mid: 1.2 * P, score: 0 },
]

let failed = 0
for (const v of vectors) {
  const { reading, factors } = aggregate(v.feeds)
  const okMid = Math.abs(reading.mid - v.mid) < 1e-6
  const okScore = reading.score === v.score
  if (!okMid || !okScore) failed++
  console.log(
    `${okMid && okScore ? 'PASS' : 'FAIL'}  ${v.id.padEnd(22)} mid=${reading.mid.toFixed(3)} (want ${v.mid.toFixed(3)})` +
      `  score=${reading.score} (want ${v.score})` +
      `  Wq=${factors.wq.toFixed(3)} Wd=${factors.wd.toFixed(3)} Wf=${factors.wf.toFixed(3)}`,
  )
}

console.log(failed === 0 ? '\nAll review.md §R1.4 vectors reproduced.' : `\n${failed} vector(s) failed.`)
process.exit(failed === 0 ? 0 : 1)
