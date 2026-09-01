import { more } from '../content/copy'
import './DeepSections.css'

// The toolbox: shipped features that earn a line each rather than a section
// each, set as a ledger with hairlines, the same shape the trust section
// uses.
export function SectionMore() {
  return (
    <section id="more" className="deep more">
      <div className="more-inner">
        <div className="deep-head">
          <div className="deep-station" />
          <h2 className="deep-h2">{more.h2}</h2>
        </div>
        {/* role restated for the same reason the trust ledger restates it. */}
        <ul className="more-list" role="list">
          {more.items.map((item) => (
            <li className="more-item" key={item.title}>
              <h3 className="more-title">{item.title}</h3>
              <p className="more-body">{item.body}</p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
