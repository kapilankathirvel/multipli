import type { LogEvent } from '../data'

function clock(t: number): string {
  return new Date(t).toLocaleTimeString('en-GB', { hour12: false })
}

export function EventLog({ events }: { events: LogEvent[] }) {
  return (
    <section className="panel log-panel">
      <header className="panel-h">
        <h2>Event log</h2>
        <span className="muted">Poke · PokeSkipped · Quarantined · StateChanged · Guard · Synced</span>
      </header>
      <ol className="log">
        {events.length === 0 && <li className="muted">No events yet.</li>}
        {events.map((e) => (
          <li key={e.id}>
            <time>{clock(e.t)}</time>
            <span className={`ev ev-${e.name}`}>{e.name}</span>
            <span className="detail">{e.detail}</span>
          </li>
        ))}
      </ol>
    </section>
  )
}
