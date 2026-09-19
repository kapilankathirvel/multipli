import { Cell, Pie, PieChart, ResponsiveContainer } from 'recharts'
import { formatAge, formatPrice, type Factors, type Reading } from '../data'

const BANDS = [
  { name: 'red', value: 50, fill: '#f43f5e' },
  { name: 'yellow', value: 30, fill: '#eab308' },
  { name: 'green', value: 20, fill: '#34d399' },
]

function scoreFill(score: number): string {
  if (score >= 80) return '#34d399'
  if (score >= 50) return '#eab308'
  return '#f43f5e'
}

/** One factor of score = 100 · Wq · Wd · Wf (review.md §R1.2). */
function Factor({ tag, value, note }: { tag: string; value: number; note: string }) {
  return (
    <div className="factor">
      <div className="factor-top">
        <span className="factor-tag">{tag}</span>
        <span className="mono factor-val">{value.toFixed(2)}</span>
      </div>
      <div className="factor-track">
        <div className="factor-fill" style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} />
      </div>
      <div className="muted factor-note">{note}</div>
    </div>
  )
}

export function ConfidenceGauge({
  reading,
  factors,
}: {
  reading: Reading
  factors: Factors
}) {
  const needle = Math.min(100, Math.max(0, reading.score))
  const span = Math.max(reading.hi - reading.lo, 1e-6)
  const midPct = ((reading.mid - reading.lo) / span) * 100
  const product = Math.floor(100 * factors.wq * factors.wd * factors.wf)

  return (
    <section className="panel gauge-panel">
      <header className="panel-h">
        <h2>Confidence</h2>
        <span className="muted">
          {reading.ok ? `${reading.nInliers}/${reading.nFresh} inliers` : 'no quorum'} · band lo–mid–hi
        </span>
      </header>
      <div className="gauge-row">
        <div className="gauge">
          <ResponsiveContainer width="100%" height={180}>
            <PieChart>
              <Pie
                data={BANDS}
                dataKey="value"
                startAngle={180}
                endAngle={0}
                innerRadius={62}
                outerRadius={86}
                stroke="none"
                isAnimationActive={false}
              >
                {BANDS.map((b) => (
                  <Cell key={b.name} fill={b.fill} fillOpacity={0.28} />
                ))}
              </Pie>
              <Pie
                data={[
                  { v: needle, fill: scoreFill(needle) },
                  { v: 100 - needle, fill: 'transparent' },
                ]}
                dataKey="v"
                startAngle={180}
                endAngle={0}
                innerRadius={62}
                outerRadius={86}
                stroke="none"
                isAnimationActive={false}
              >
                <Cell fill={scoreFill(needle)} />
                <Cell fill="transparent" />
              </Pie>
            </PieChart>
          </ResponsiveContainer>
          <div className="gauge-label">
            <strong style={{ color: scoreFill(needle) }}>{needle}</strong>
            <span>/ 100</span>
          </div>
        </div>
        <div className="band">
          <div className="band-meta">
            <span>lo {formatPrice(reading.lo)}</span>
            <span className="gold">mid {formatPrice(reading.mid)}</span>
            <span>hi {formatPrice(reading.hi)}</span>
          </div>
          <div className="band-track">
            <div className="band-fill" />
            <div className="band-mid" style={{ left: `${midPct}%` }} />
          </div>
          <p className="muted band-note">
            GREEN ≥ 80 · YELLOW 50–79 · RED &lt; 50. Outliers sit outside 3·MAD.
          </p>
        </div>
      </div>

      <div className="formula">
        <span className="mono">score = ⌊100 · Wq · Wd · Wf⌋</span>
        <span className="mono formula-eq">
          = ⌊100 · {factors.wq.toFixed(2)} · {factors.wd.toFixed(2)} · {factors.wf.toFixed(2)}⌋ ={' '}
          <strong style={{ color: scoreFill(product) }}>{reading.ok ? product : 0}</strong>
          {!reading.ok && <span className="muted"> · quorum &lt; 2 ⇒ 0</span>}
        </span>
      </div>
      <div className="factors">
        <Factor
          tag="Wq quorum"
          value={factors.wq}
          note="weight share of the counted feeds"
        />
        <Factor
          tag="Wd agreement"
          value={factors.wd}
          note={`spread ${(factors.dBps / 100).toFixed(2)}% of 2.00% budget`}
        />
        <Factor
          tag="Wf freshness"
          value={factors.wf}
          note={
            reading.nInliers > 0
              ? `freshest inlier ${formatAge(reading.freshestAge)} old`
              : 'no inliers to measure'
          }
        />
      </div>
    </section>
  )
}
