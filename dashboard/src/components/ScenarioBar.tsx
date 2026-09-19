import { useEffect, useState } from 'react'
import type { Mode } from '../data'
import { SCENARIOS, getRunner, shortError, type ScenarioId } from '../scenarios'

export function ScenarioBar({ mode }: { mode: Mode }) {
  const [busy, setBusy] = useState<ScenarioId | null>(null)
  const [hover, setHover] = useState<string | null>(null)
  const [status, setStatus] = useState<string>(
    mode === 'mainnet'
      ? 'Scenarios inject a fault on top of the real feeds. Hover a button to see what it does.'
      : 'Buttons send transactions to the local fork. Hover a button to see what it does.',
  )
  const [failed, setFailed] = useState(false)

  // fork mode: connect and snapshot now, so `Reset` returns to the post-spell state
  // rather than to whatever the chain looked like at the first click
  useEffect(() => {
    getRunner()
      .prepare()
      .catch((err: unknown) => {
        setFailed(true)
        setStatus(shortError(err))
      })
  }, [])

  async function fire(id: ScenarioId) {
    setBusy(id)
    setFailed(false)
    setStatus(`running ${id}…`)
    try {
      setStatus(await getRunner().run(id))
    } catch (err) {
      setFailed(true)
      setStatus(shortError(err))
    } finally {
      setBusy(null)
    }
  }

  const group = (kinds: string[]) =>
    SCENARIOS.filter((s) => kinds.includes(s.kind)).map((s) => (
      <button
        key={s.id}
        type="button"
        aria-label={`${s.label}: ${s.hint}`}
        className={`btn btn-${s.kind}`}
        disabled={busy !== null}
        onClick={() => void fire(s.id)}
        onMouseEnter={() => setHover(`${s.label}: ${s.hint}`)}
        onMouseLeave={() => setHover(null)}
        onFocus={() => setHover(`${s.label}: ${s.hint}`)}
        onBlur={() => setHover(null)}
      >
        {busy === s.id ? '…' : s.label}
      </button>
    ))

  return (
    <section className="scenarios">
      <div className="btn-group">
        <span className="kicker">scenarios</span>
        {group(['reset', 'danger'])}
      </div>
      <div className="btn-group">
        <span className="kicker">step by hand</span>
        {group(['step'])}
      </div>
      <p className={`scenario-status${failed && !hover ? ' tone-bad' : ''}`}>{hover ?? status}</p>
    </section>
  )
}
