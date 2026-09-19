import { borrowStatus, formatUsdCompact, type Risk } from '../data'

const COPY: Record<ReturnType<typeof borrowStatus>, string> = {
  open: 'new borrowing: open',
  limited: 'new borrowing: limited',
  frozen: 'new borrowing: frozen',
}

export function VatPanel({ risk }: { risk: Risk }) {
  const status = borrowStatus(risk)
  const cap = Math.max(risk.lineUsd, 1)
  const debtPct = Math.min(100, (risk.debtUsd / cap) * 100)
  const headroom = Math.max(0, risk.lineUsd - risk.debtUsd)

  return (
    <section className="panel">
      <header className="panel-h">
        <h2>Vat · paxg</h2>
        <span className={`borrow borrow-${status}`}>{COPY[status]}</span>
      </header>
      <div className="vat-nums">
        <div>
          <div className="kicker">debt</div>
          <div className="mono big">{formatUsdCompact(risk.debtUsd)}</div>
        </div>
        <div>
          <div className="kicker">line</div>
          <div className="mono big">{formatUsdCompact(risk.lineUsd)}</div>
        </div>
        <div>
          <div className="kicker">headroom</div>
          <div className="mono big">{formatUsdCompact(headroom)}</div>
        </div>
      </div>
      <div className="bar" aria-label="debt versus line">
        <div className="bar-debt" style={{ width: `${debtPct}%` }} />
      </div>
      <p className="muted">
        Repayments always work. Controllers only tighten <em>new</em> debt via{' '}
        <code>Vat.line</code>.
      </p>
    </section>
  )
}
