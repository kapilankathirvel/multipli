import { borrowStatus, effectsFor, formatUsdCompact, type Mode, type Risk } from '../data'

const COPY = {
  open: 'new borrowing open',
  limited: 'new borrowing limited',
  frozen: 'new borrowing frozen',
} as const

const KEEP = new Set(['Borrow new rwaUSD', 'Repay debt', 'New liquidations', 'Spotter.mat'])

/**
 * Vat · paxg in plain words. "debt" is all rwaUSD currently borrowed against PAXG; the
 * "debt ceiling" (Vat.line) is the most that may be outstanding; "room" is what can still
 * be borrowed. OracleGuard's only borrowing lever is that ceiling.
 */
export function BorrowPanel({
  risk,
  vat,
  mode,
}: {
  risk: Risk
  vat: { debtUsd: number; lineUsd: number }
  mode: Mode
}) {
  const status = borrowStatus(risk)
  const room = Math.max(0, risk.lineUsd - vat.debtUsd)
  const pct = Math.min(100, (vat.debtUsd / Math.max(risk.lineUsd, 1)) * 100)
  const rows = effectsFor(risk.state, risk.guard, vat.debtUsd).filter((r) => KEEP.has(r.label))

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Borrowing against PAXG</h2>
        <span className={`pill pill-${status}`}>{COPY[status]}</span>
      </header>

      <div className="nums">
        <div>
          <div className="kicker">debt</div>
          <div className="mono big">{formatUsdCompact(vat.debtUsd)}</div>
          <div className="muted small">rwaUSD borrowed now</div>
        </div>
        <div>
          <div className="kicker">debt ceiling</div>
          <div className="mono big">{formatUsdCompact(risk.lineUsd)}</div>
          <div className="muted small">max allowed (Vat.line)</div>
        </div>
        <div>
          <div className="kicker">room</div>
          <div className="mono big">{formatUsdCompact(room)}</div>
          <div className="muted small">can still be borrowed</div>
        </div>
      </div>
      <div className="track" aria-label="debt versus ceiling">
        <div className="fill fill-debt" style={{ width: `${pct}%` }} />
      </div>
      {mode === 'mainnet' && (
        <p className="muted small note">
          Real Vat on mainnet today: debt {formatUsdCompact(vat.debtUsd)}, ceiling{' '}
          {formatUsdCompact(vat.lineUsd)}. The ceiling above is what OracleGuard would set in this
          state: debt + $250k (GREEN), debt + $50k (YELLOW), debt (RED).
        </p>
      )}

      <ul className="effects">
        {rows.map((r) => (
          <li key={r.label}>
            <span>{r.label === 'Spotter.mat' ? 'Collateral ratio (Spotter.mat)' : r.label}</span>
            <span className={`tone-${r.tone}`}>{r.value}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
