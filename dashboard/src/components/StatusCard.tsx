import { formatAge, formatPrice, type OsmState, type Reading, type Risk } from '../data'

const OSM_TEXT: Record<OsmState['status'], string> = {
  UNINIT: 'not initialised',
  LIVE: 'fresh: last good update under 2h ago',
  STALE: 'stale: no good update for over 2h',
  QUARANTINED: 'holding back a suspicious upward jump',
  STOPPED: 'stopped by governance',
}

/** The one-glance answer: what state are we in, why, and which price the protocol is using. */
export function StatusCard({ reading, osm, risk }: { reading: Reading; osm: OsmState; risk: Risk }) {
  const tone = risk.state.toLowerCase()
  return (
    <section className={`panel status tint-${tone}`}>
      <div className="status-top">
        <div>
          <div className="kicker">risk state</div>
          <div className={`state-word state-${tone}`}>{risk.state}</div>
        </div>
        <div className="status-score">
          <div className="kicker">confidence</div>
          <div className="mono big">
            {reading.score}
            <span className="muted"> / 100</span>
          </div>
        </div>
      </div>
      <p className="status-why">
        <span className="muted">Why: </span>
        {risk.reason}
      </p>

      <dl className="kv">
        <div>
          <dt>Liquidation guard</dt>
          <dd className={risk.guard ? 'tone-warn' : undefined}>
            {risk.guard ? '🛡️ ON: new liquidations paused (Dog.hole = 0)' : 'off: liquidations work normally'}
          </dd>
        </div>
        <div>
          <dt>Price vaults are valued at</dt>
          <dd>
            <span className="mono">{formatPrice(osm.cur)}</span>
            <span className="muted"> · next {formatPrice(osm.nxt)} in ≤ 1h</span>
          </dd>
        </div>
        <div>
          <dt>SmartOSM</dt>
          <dd>
            {osm.status} <span className="muted">· {OSM_TEXT[osm.status]} · {formatAge(osm.ageSec)} ago</span>
          </dd>
        </div>
      </dl>
    </section>
  )
}
