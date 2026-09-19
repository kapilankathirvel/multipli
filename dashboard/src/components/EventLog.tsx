import type { LogEvent } from '../data'

function clock(t: number): string {
  return new Date(t).toLocaleTimeString('en-GB', { hour12: false })
}

export function EventLog({ events }: { events: LogEvent[] }) {
  return (
    <details className="panel log-panel">
      <summary className="panel-h">
        <h2>Event log</h2>
        <span className="muted small">
          {events.length} events · latest: {events[0] ? `${events[0].name}` : 'none'}
        </span>
      </summary>
      <ol className="log">
        {events.length === 0 && <li className="muted">No events yet.</li>}
        {events.map((e) => (
          <li key={e.id}>
            <time className="muted">{clock(e.t)}</time>
            <span className="ev">{e.name}</span>
            <span className="muted">{e.detail}</span>
          </li>
        ))}
      </ol>
    </details>
  )
}
