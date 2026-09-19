import {
  formatAge,
  formatPrice,
  formatUsdCompact,
  type Legacy,
  type OsmState,
  type Reading,
  type Risk,
} from '../data'

/** Measured on the fork by the Baseline tests (docs/DEMO_SCRIPT.md §D). */
const S3 = { collateral: 43_724, minted: 312_319, badDebt: 268_595, paxg: 10 }
const S1 = { minted: 31_231 }

type Kind = 'none' | 's3' | 's1'

function killerMoment(legacy: Legacy, reading: Reading, risk: Risk): Kind {
  const ref = reading.ok ? reading.mid : 0
  if (ref > 0 && legacy.price > 0 && Math.abs(legacy.price - ref) / ref > 0.5) return 's3'
  if (legacy.valid && legacy.ageHours > 24 && risk.state === 'RED') return 's1'
  return 'none'
}

export function LegacyPanel({
  legacy,
  reading,
  osm,
  risk,
}: {
  legacy: Legacy
  reading: Reading
  osm: OsmState
  risk: Risk
}) {
  const kind = killerMoment(legacy, reading, risk)

  return (
    <section className="panel legacy-panel">
      <header className="panel-h">
        <h2>Legacy OSM vs OracleGuard</h2>
        <span className="muted">same consumers · same ABI · different answers</span>
      </header>

      <div className="versus">
        <div className="vs-col vs-legacy">
          <div className="vs-title">Legacy OSM</div>
          <div className="vs-price mono">{formatPrice(legacy.price)}</div>
          <dl className="vs-dl">
            <div>
              <dt>peek() valid</dt>
              <dd className={legacy.valid ? 'bad-yes' : ''}>
                {legacy.valid ? 'VALID' : 'invalid'}
                {legacy.valid && legacy.ageHours > 2 && <span className="muted"> (even now)</span>}
              </dd>
            </div>
            <div>
              <dt>age</dt>
              <dd className="mono">{formatAge(legacy.ageHours * 3600)}</dd>
            </div>
            <div>
              <dt>staleness check</dt>
              <dd className="bad-yes">none</dd>
            </div>
            <div>
              <dt>sources</dt>
              <dd>1 (Chainlink)</dd>
            </div>
          </dl>
          <p className="muted vs-note">
            Serves its last price forever: `has = true` regardless of age, so `Spotter.poke()`
            accepts it and every vault is valued at it.
          </p>
        </div>

        <div className="vs-col vs-guard">
          <div className="vs-title">OracleGuard</div>
          <div className="vs-price mono">{formatPrice(osm.cur)}</div>
          <dl className="vs-dl">
            <div>
              <dt>confidence</dt>
              <dd className="mono">{reading.ok ? `${reading.score} / 100` : 'no quorum'}</dd>
            </div>
            <div>
              <dt>state</dt>
              <dd className={`state-word state-${risk.state.toLowerCase()}`}>
                {risk.state}
                {risk.guard ? ' · 🛡️' : ''}
              </dd>
            </div>
            <div>
              <dt>OSM status</dt>
              <dd>
                {osm.status} <span className="muted">· {formatAge(osm.ageSec)}</span>
              </dd>
            </div>
            <div>
              <dt>sources</dt>
              <dd>
                {reading.nInliers} of 4 counted
              </dd>
            </div>
          </dl>
          <p className="muted vs-note">
            Staleness and disagreement are visible and acted on: `Vat.line` tightens, repayments and
            liquidations keep working.
          </p>
        </div>
      </div>

      {kind === 's3' && (
        <div className="killer">
          <div className="killer-tag">S3 · feed compromise</div>
          <div className="killer-body">
            <span className="killer-bad">
              Legacy: {S3.paxg} PAXG ({formatUsdCompact(S3.collateral)}) minted{' '}
              {formatUsdCompact(S3.minted)} → {formatUsdCompact(S3.badDebt)} bad debt
            </span>
            <span className="killer-good">OracleGuard: blocked — the ×10 feed is an outlier</span>
          </div>
        </div>
      )}

      {kind === 's1' && (
        <div className="killer">
          <div className="killer-tag">S1 · stale feed</div>
          <div className="killer-body">
            <span className="killer-bad">
              Legacy: {legacy.ageHours.toFixed(0)}h-old price still "VALID" →{' '}
              {formatUsdCompact(S1.minted)} rwaUSD minted against it
            </span>
            <span className="killer-good">
              OracleGuard: RED — new debt reverts `Vat/ceiling-exceeded`, repayments still work
            </span>
          </div>
        </div>
      )}
    </section>
  )
}
