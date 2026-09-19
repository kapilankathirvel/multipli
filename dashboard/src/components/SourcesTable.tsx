import { formatAge, formatPct, formatPrice, type Source } from '../data'

function Pill({
  on,
  onLabel,
  offLabel,
}: {
  on: boolean
  onLabel: string
  offLabel: string
}) {
  return (
    <span className={`pill ${on ? 'pill-on' : 'pill-off'}`}>
      <i className="dot" />
      {on ? onLabel : offLabel}
    </span>
  )
}

/**
 * Mentor review R1: every source shows its weight share -- the amount of confidence
 * (Wq) it carries -- and whether that share is currently counted.
 */
function Contribution({ s }: { s: Source }) {
  return (
    <div className={`contrib ${s.counts ? 'contrib-on' : 'contrib-off'}`}>
      <div className="contrib-bar">
        <div className="contrib-fill" style={{ width: `${s.share * 100}%` }} />
      </div>
      <span className="mono contrib-num">{formatPct(s.share)}</span>
      <span className="contrib-tick" title={s.counts ? 'counts towards the score' : 'excluded'}>
        {s.counts ? '✓' : '✗'}
      </span>
    </div>
  )
}

export function SourcesTable({ sources }: { sources: Source[] }) {
  const counted = sources.filter((s) => s.counts)
  const share = counted.reduce((a, s) => a + s.share, 0)

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Sources</h2>
        <span className="muted">
          {counted.length}/{sources.length} counted · {formatPct(share)} of weight
        </span>
      </header>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Feed</th>
              <th className="num">Price</th>
              <th className="num">Age</th>
              <th>Fresh</th>
              <th>Cluster</th>
              <th>Contribution</th>
            </tr>
          </thead>
          <tbody>
            {sources.map((s) => (
              <tr key={s.name} className={!s.counts ? 'row-out' : undefined}>
                <td className="name">
                  {s.name}
                  {/* whole hours: "25h" (deliberately > Chainlink's 24h heartbeat), not "1.0d" */}
                  <span className="muted weight">
                    {' '}
                    w{s.weight} · maxAge {Math.round(s.maxAgeSec / 3600)}h
                  </span>
                </td>
                <td className="num mono">{formatPrice(s.price)}</td>
                <td className="num mono">{formatAge(s.ageSec)}</td>
                <td>
                  <Pill on={s.fresh} onLabel="fresh" offLabel="stale" />
                </td>
                <td>
                  {/* a stale feed never reaches the outlier test, so don't call it an outlier */}
                  {s.fresh ? (
                    <Pill on={s.inlier} onLabel="inlier" offLabel="outlier" />
                  ) : (
                    <span className="pill pill-na">not checked</span>
                  )}
                </td>
                <td>
                  <Contribution s={s} />
                </td>
              </tr>
            ))}
            {sources.length === 0 && (
              <tr>
                <td colSpan={6} className="muted">
                  No sources configured.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <p className="muted foot">
        Contribution = this feed's weight share of the price <em>and</em> of Wq. No single feed can
        move the median (breakdown point = ½ of total weight).
      </p>
    </section>
  )
}
