import {
  formatAge,
  formatPrice,
  formatUsdCompact,
  type Legacy,
  type OsmState,
  type Reading,
  type Risk,
} from '../data'

/** The vault size used for the "what could be borrowed" numbers (same as the Baseline tests). */
const VAULT_PAXG = 10

type Kind = 'none' | 's3' | 's1'

function killerMoment(legacy: Legacy, reading: Reading, risk: Risk): Kind {
  const ref = reading.ok ? reading.mid : 0
  if (ref > 0 && legacy.price > 0 && Math.abs(legacy.price - ref) / ref > 0.5) return 's3'
  if (legacy.valid && legacy.ageHours > 24 && risk.state === 'RED') return 's1'
  return 'none'
}

/**
 * Same question to both oracles. The banner numbers are derived, not typed in:
 * max borrow = collateral value at the oracle price / Spotter.mat.
 */
export function LegacyPanel({
  legacy,
  reading,
  osm,
  risk,
  mat,
}: {
  legacy: Legacy
  reading: Reading
  osm: OsmState
  risk: Risk
  mat: number
}) {
  const kind = killerMoment(legacy, reading, risk)
  const maxBorrowLegacy = (VAULT_PAXG * legacy.price) / mat
  const collateral = VAULT_PAXG * reading.mid

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Legacy OSM vs OracleGuard</h2>
        <span className="muted small">what Multipli uses today vs with OracleGuard</span>
      </header>

      <div className="versus">
        <div className="vs vs-legacy">
          <div className="kicker">legacy OSM (today)</div>
          <div className="mono big">{formatPrice(legacy.price)}</div>
          <ul className="small">
            <li>
              reports <strong className="tone-bad">{legacy.valid ? 'VALID' : 'invalid'}</strong> at{' '}
              {formatAge(legacy.ageHours * 3600)} old
            </li>
            <li>no staleness check, 1 source (Chainlink)</li>
          </ul>
        </div>
        <div className="vs vs-guard">
          <div className="kicker">OracleGuard</div>
          <div className="mono big">{formatPrice(osm.cur)}</div>
          <ul className="small">
            <li>
              <strong className={`state-${risk.state.toLowerCase()}`}>{risk.state}</strong>, score{' '}
              {reading.score} {risk.guard && '· 🛡️'}
            </li>
            <li>
              {reading.nInliers} sources counted, {osm.status} ({formatAge(osm.ageSec)})
            </li>
          </ul>
        </div>
      </div>

      {kind === 's3' && (
        <div className="killer">
          <div className="kicker">S3 · compromised feed</div>
          <div className="tone-bad">
            Legacy: {VAULT_PAXG} PAXG worth {formatUsdCompact(collateral)} can borrow{' '}
            {formatUsdCompact(maxBorrowLegacy)}, leaving{' '}
            {formatUsdCompact(Math.max(0, maxBorrowLegacy - collateral))} of bad debt
          </div>
          <div className="tone-ok">OracleGuard: the ×10 feed is an outlier and is ignored</div>
        </div>
      )}

      {kind === 's1' && (
        <div className="killer">
          <div className="kicker">S1 · stale feed</div>
          <div className="tone-bad">
            Legacy: a {legacy.ageHours.toFixed(0)}h-old price is still "VALID", so {VAULT_PAXG} PAXG can
            still borrow {formatUsdCompact(maxBorrowLegacy)}
          </div>
          <div className="tone-ok">OracleGuard: RED. New debt is blocked, repayments still work</div>
        </div>
      )}
    </section>
  )
}
