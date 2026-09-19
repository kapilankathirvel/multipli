import { P, formatAge, pointsOf, type Factors, type Reading, type Source } from '../data'

function tone(score: number): string {
  if (score >= P.greenScore) return 'green'
  if (score >= P.yellowScore) return 'yellow'
  return 'red'
}

function Row({
  label,
  max,
  factor,
  note,
}: {
  label: string
  max: number
  factor: number
  note: string
}) {
  const pts = max * factor
  return (
    <li className="term">
      <div className="term-top">
        <span>{label}</span>
        <span className="mono">
          <span className="muted">
            {max} × {factor.toFixed(2)} ={' '}
          </span>
          {pts.toFixed(1)}
        </span>
      </div>
      <div className="track">
        <div className="fill" style={{ width: `${Math.max(0, Math.min(1, factor)) * 100}%` }} />
      </div>
      <div className="muted small">{note}</div>
    </li>
  )
}

/**
 * The confidence score as a sum of points (protocol.ts scoreOf):
 *   score = 50·Wq + 30·Wd + 20·Wf − volatility penalty   (0 without quorum)
 * Every factor is recomputed from the sources on each poll; only the 50/30/20 split is fixed.
 */
export function ScoreCard({
  reading,
  factors,
  sources,
  chainScore,
}: {
  reading: Reading
  factors: Factors
  sources: Source[]
  chainScore?: number
}) {
  const w = P.scoreWeights
  const pts = pointsOf(factors)
  const counted = sources.filter((s) => s.counts)
  const sum = pts.q + pts.d + pts.f
  const t = tone(reading.score)

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Confidence score</h2>
        <span className="muted small">recomputed from the sources every poll</span>
      </header>

      <ol className="terms">
        <Row
          label="Quorum: how much of the oracle weight is usable"
          max={100 * w.q}
          factor={factors.wq}
          note={
            counted.length > 0
              ? `${counted.map((s) => s.name).join(', ')} count (fresh and agreeing)`
              : 'no source counts'
          }
        />
        <Row
          label="Agreement: how close the counted prices are"
          max={100 * w.d}
          factor={factors.wd}
          note={
            counted.length > 0
              ? `they span ${(factors.dBps / 100).toFixed(2)}%; full points at 0%, zero at ${(P.dMaxBps / 100).toFixed(0)}%`
              : 'nothing to compare'
          }
        />
        <Row
          label="Freshness: age of the newest counted price"
          max={100 * w.f}
          factor={factors.wf}
          note={
            reading.nInliers > 0
              ? `${formatAge(reading.freshestAge)} old; full points up to half the source's max age`
              : 'nothing to measure'
          }
        />
        <li className="term term-flat">
          <div className="term-top">
            <span>Volatility penalty</span>
            <span className="mono">− {P.volPenalty}</span>
          </div>
          <div className="muted small">placeholder, not implemented yet</div>
        </li>
      </ol>

      <div className="total">
        <span className="mono muted">
          {reading.ok ? `⌊${sum.toFixed(1)}⌋ − ${P.volPenalty} =` : 'fewer than 2 sources agree, so the score is'}
        </span>
        <strong className={`mono state-${t}`}>{reading.score}</strong>
      </div>

      <div className="scale" aria-label="state thresholds">
        <div className="scale-red" style={{ width: `${P.yellowScore}%` }}>
          RED &lt; {P.yellowScore}
        </div>
        <div className="scale-yellow" style={{ width: `${P.greenScore - P.yellowScore}%` }}>
          YELLOW
        </div>
        <div className="scale-green" style={{ width: `${100 - P.greenScore}%` }}>
          GREEN ≥ {P.greenScore}
        </div>
        <i className="scale-mark" style={{ left: `${reading.score}%` }} />
      </div>

      {chainScore !== undefined && chainScore !== reading.score && (
        <p className="muted small note">
          The deployed contract still multiplies the factors (score {chainScore}); it switches to
          this sum when the aggregator is updated.
        </p>
      )}
    </section>
  )
}
