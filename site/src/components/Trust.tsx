import { trust } from '../content/copy'
import './Closing.css'

// The user-facing trust claims: local-only data, measured overhead, and open
// source forever. They carry equal weight along one evidence spine.
export function Trust() {
  return (
    <section id="trust" className="closing trust" aria-labelledby="trust-title">
      <div className="closing-inner">
        <h2 className="closing-h2" id="trust-title">
          {trust.h2}
        </h2>
        {/* role restated for the same reason the glance band restates it: the
            global list-style reset drops implicit list semantics in Safari. */}
        <ul className="trust-list" role="list">
          {trust.items.map((item) => (
            <li className="trust-item" key={item.title}>
              <h3 className="trust-title">{item.title}</h3>
              <p className="trust-body">{item.body}</p>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
