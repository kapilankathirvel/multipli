import { useEffect, useState } from 'react'
import { SCENARIOS, getRunner, shortError, type ScenarioId } from '../scenarios'

export function ScenarioBar({ mode }: { mode: 'mock' | 'live' }) {
  const [busy, setBusy] = useState<ScenarioId | null>(null)
  const [status, setStatus] = useState<string>(
    mode === 'mock'
      ? 'mock mode — buttons drive the simulated world'
      : 'live mode — buttons drive anvil (snapshot / warp / setPrice / poke / sync)',
  )
  const [failed, setFailed] = useState(false)

  // live mode: connect and snapshot now, so `Reset` returns to the post-spell state
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

  return (
    <section className="scenarios">
      <div className="scenario-btns">
        {SCENARIOS.map((s) => (
          <button
            key={s.id}
            type="button"
            title={s.hint}
            aria-label={`${s.label}: ${s.hint}`}
            className={`btn btn-${s.kind}${busy === s.id ? ' btn-busy' : ''}`}
            disabled={busy !== null}
            onClick={() => void fire(s.id)}
          >
            {busy === s.id ? '…' : s.label}
          </button>
        ))}
      </div>
      <p className={`scenario-status${failed ? ' scenario-failed' : ''}`}>{status}</p>
    </section>
  )
}
