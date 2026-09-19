import { effectsFor, type Risk } from '../data'

/**
 * Mentor review R3: "clearly specify what GREEN/YELLOW/RED actually changes".
 * This renders the review.md §R3 table row for the state we are in right now.
 */
export function StateEffects({ risk }: { risk: Risk }) {
  const rows = effectsFor(risk.state, risk.guard, risk.debtUsd)

  return (
    <section className="panel effects-panel">
      <header className="panel-h">
        <h2>What this state changes</h2>
        <span className="muted">
          {risk.state}
          {risk.guard ? ' + guard' : ''} · only Vat.line and Dog.hole are ever written
        </span>
      </header>
      <ul className={`effects state-tint-${risk.state.toLowerCase()}`}>
        {rows.map((r) => (
          <li key={r.label}>
            <span className="eff-label">{r.label}</span>
            <span className={`eff-val eff-${r.tone}`}>{r.value}</span>
          </li>
        ))}
      </ul>
      <p className="muted foot">
        Trigger: {risk.reason}. Downgrades are instant; an upgrade needs 3 healthy syncs ≥ 10 min
        apart.
      </p>
    </section>
  )
}
