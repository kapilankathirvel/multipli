import { ConfidenceGauge } from './components/ConfidenceGauge'
import { EventLog } from './components/EventLog'
import { LegacyPanel } from './components/LegacyPanel'
import { ScenarioBar } from './components/ScenarioBar'
import { SourcesTable } from './components/SourcesTable'
import { StateBadge } from './components/StateBadge'
import { StateEffects } from './components/StateEffects'
import { VatPanel } from './components/VatPanel'
import { useOracle } from './useOracle'

export default function App() {
  const snap = useOracle()

  if (!snap) {
    return (
      <div className="shell boot">
        <p>Arming Oracle War Room…</p>
      </div>
    )
  }

  return (
    <div className="shell">
      <header className="top">
        <div className="brand">
          <div className="mark" aria-hidden />
          <div>
            <div className="title">Oracle War Room</div>
            <div className="sub">OracleGuard · rwaUSD · ilk paxg</div>
          </div>
        </div>
        <div className="top-meta">
          <span className={`mode mode-${snap.mode}`}>{snap.mode}</span>
          <span className="muted">
            poll 2s · updated{' '}
            {new Date(snap.updatedAt).toLocaleTimeString('en-GB', { hour12: false })}
          </span>
        </div>
      </header>

      {snap.error && (
        <div className="banner-err">
          Live RPC failed — showing last mock snapshot. {snap.error}
        </div>
      )}

      <ScenarioBar mode={snap.mode} />

      <div className="grid">
        <SourcesTable sources={snap.sources} />
        <ConfidenceGauge reading={snap.reading} factors={snap.factors} />
        <StateBadge osm={snap.osm} risk={snap.risk} />
        <VatPanel risk={snap.risk} />
        <StateEffects risk={snap.risk} />
        <LegacyPanel
          legacy={snap.legacy}
          reading={snap.reading}
          osm={snap.osm}
          risk={snap.risk}
        />
        <EventLog events={snap.events} />
      </div>
    </div>
  )
}
