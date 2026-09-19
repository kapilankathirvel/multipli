import { formatAge, formatPct, formatPrice, type Reading, type Source } from '../data'

function status(s: Source): { label: string; cls: string; tip: string } {
  if (!s.fresh && s.price === 0) return { label: 'no data', cls: 'bad', tip: 'the read failed' }
  if (!s.fresh) return { label: 'stale', cls: 'bad', tip: `older than its ${formatAge(s.maxAgeSec)} max age` }
  if (!s.inlier) return { label: 'outlier', cls: 'bad', tip: 'too far from the median, ignored' }
  return { label: 'counted', cls: 'ok', tip: 'fresh and agrees with the others' }
}

export function SourcesTable({ sources, reading }: { sources: Source[]; reading: Reading }) {
  const counted = sources.filter((s) => s.counts)
  const share = counted.reduce((a, s) => a + s.share, 0)
  const spread = reading.mid > 0 ? ((reading.hi - reading.lo) / reading.mid) * 100 : 0

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Price sources</h2>
        <span className="muted small">
          {counted.length} of {sources.length} counted ({formatPct(share)} of the weight)
        </span>
      </header>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Source</th>
              <th className="num">Price</th>
              <th className="num">Age / max</th>
              <th>Status</th>
              <th className="num">Weight</th>
            </tr>
          </thead>
          <tbody>
            {sources.map((s) => {
              const st = status(s)
              return (
                <tr key={s.name} className={s.counts ? undefined : 'row-out'}>
                  <td>
                    <div>{s.name}</div>
                    {s.via && <div className="muted small">{s.via}</div>}
                  </td>
                  <td className="num mono">{formatPrice(s.price)}</td>
                  <td className="num mono">
                    {s.price > 0 ? formatAge(s.ageSec) : '—'}
                    <span className="muted"> / {Math.round(s.maxAgeSec / 3600)}h</span>
                  </td>
                  <td>
                    <span className={`pill pill-${st.cls}`} title={st.tip}>
                      {st.label}
                    </span>
                  </td>
                  <td className="num mono">{formatPct(s.share)}</td>
                </tr>
              )
            })}
            {sources.length === 0 && (
              <tr>
                <td colSpan={5} className="muted">
                  No sources configured.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <p className="muted small foot">
        OracleGuard price = weighted median of the counted sources:{' '}
        <span className="mono">{formatPrice(reading.mid)}</span> (spread {spread.toFixed(2)}%). No
        single source can move it: each holds under half the weight.
      </p>
    </section>
  )
}
