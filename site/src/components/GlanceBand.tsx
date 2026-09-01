import { glance, glanceLabel } from '../content/copy'
import './GlanceBand.css'

// The five-second read: every key feature, one line each, on one drawn rail,
// each linking to its deep section. Most visitors never scroll past this, so
// it is the whole app in miniature. Still a rail with stations, never a card
// grid; the numbering went with the old loop structure.
export function GlanceBand() {
  return (
    <nav className="glance" aria-label={glanceLabel}>
      {/* role restated because the global list-style reset drops implicit list
          semantics in Safari/VoiceOver. */}
      <ul className="glance-loop" role="list">
        {glance.map((beat) => (
          <li className="glance-beat" key={beat.id}>
            <a className="glance-link" href={`#${beat.id}`}>
              <span className="glance-title">{beat.title}</span>
              <span className="glance-line">{beat.line}</span>
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}
