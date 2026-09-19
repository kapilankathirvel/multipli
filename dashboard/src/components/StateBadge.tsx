import type { OsmState, Risk } from '../data'
import { formatAge, formatPrice } from '../data'

export function StateBadge({ osm, risk }: { osm: OsmState; risk: Risk }) {
  return (
    <section className="panel state-panel">
      <header className="panel-h">
        <h2>Controller</h2>
        <span className="muted">
          OSM {osm.status} · age {formatAge(osm.ageSec)}
        </span>
      </header>
      <div className="state-row">
        <div className={`badge state-${risk.state.toLowerCase()}`}>
          <span className="badge-kicker">risk</span>
          <span className="badge-word">{risk.state}</span>
        </div>
        <div className={`guard ${risk.guard ? 'guard-on' : 'guard-off'}`}>
          <span className="shield" aria-hidden>
            🛡️
          </span>
          <div>
            <div className="guard-title">liquidation guard</div>
            <div className="guard-flag">{risk.guard ? 'ON · hole = 0' : 'OFF · liquidations open'}</div>
          </div>
        </div>
      </div>
      <dl className="osm-dl">
        <div>
          <dt>cur</dt>
          <dd className="mono">{formatPrice(osm.cur)}</dd>
        </div>
        <div>
          <dt>nxt</dt>
          <dd className="mono">{formatPrice(osm.nxt)}</dd>
        </div>
      </dl>
      <p className="muted foot">trigger: {risk.reason}</p>
    </section>
  )
}
