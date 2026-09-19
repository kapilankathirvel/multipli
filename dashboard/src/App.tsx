import { BorrowPanel } from './components/BorrowPanel'
import { EventLog } from './components/EventLog'
import { LegacyPanel } from './components/LegacyPanel'
import { ScenarioBar } from './components/ScenarioBar'
import { ScoreCard } from './components/ScoreCard'
import { SourcesTable } from './components/SourcesTable'
import { StatusCard } from './components/StatusCard'
import { mode } from './data'
import { useOracle } from './useOracle'

const MODE_TEXT = {
  mainnet: {
    pill: 'Mainnet data',
    line: 'Prices, debt and the legacy oracle are read from Ethereum mainnet every 6s. OracleGuard is not deployed on mainnet, so it runs in this page on top of those real numbers.',
  },
  fork: {
    pill: 'Local fork',
    line: 'Reading a local anvil copy of mainnet with OracleGuard deployed by the spell. Every number comes from the forked contracts.',
  },
} as const

export default function App() {
  const { snap, error } = useOracle()
  const m = snap?.mode ?? mode()

  return (
    <div className="shell">
      <header className="top">
        <div className="brand">
          <div className="mark" aria-hidden />
          <div>
            <div className="title">Oracle War Room</div>
            <div className="sub">OracleGuard · rwaUSD · PAXG vaults</div>
          </div>
        </div>
        <div className="top-meta">
          <span className={`mode mode-${m}`}>
            {MODE_TEXT[m].pill}
            {snap && ` · block ${snap.block.toLocaleString('en-US')}`}
          </span>
          {snap && (
            <span className="muted small">
              updated {new Date(snap.updatedAt).toLocaleTimeString('en-GB', { hour12: false })}
            </span>
          )}
        </div>
      </header>
      <p className="muted small intro">{MODE_TEXT[m].line}</p>

      {error && <div className="banner-err">{error}</div>}

      {!snap ? (
        <div className="boot">
          {error ? 'No data to show yet — see the message above.' : 'Reading the chain…'}
        </div>
      ) : (
        <>
          <ScenarioBar mode={snap.mode} />
          <div className="grid">
            <StatusCard reading={snap.reading} osm={snap.osm} risk={snap.risk} />
            <ScoreCard
              reading={snap.reading}
              factors={snap.factors}
              sources={snap.sources}
              chainScore={snap.chainScore}
            />
            <div className="span-2">
              <SourcesTable sources={snap.sources} reading={snap.reading} />
            </div>
            <BorrowPanel risk={snap.risk} vat={snap.vat} mode={snap.mode} />
            <LegacyPanel
              legacy={snap.legacy}
              reading={snap.reading}
              osm={snap.osm}
              risk={snap.risk}
              mat={snap.mat}
            />
            <div className="span-2">
              <EventLog events={snap.events} />
            </div>
          </div>
        </>
      )}
    </div>
  )
}
