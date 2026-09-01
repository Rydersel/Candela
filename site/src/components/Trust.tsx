import { trust } from '../content/copy'
// .reveal's styles live in DeepSections.css, shared with the four deep
// sections, and useReveal.ts holds the scroll observer that arms them;
// Closing.css carries only this register's own classes.
import { useReveal } from '../useReveal'
import './Closing.css'

// The user-facing trust claims: local-only data, measured overhead, and open
// source forever. They carry equal weight along one evidence spine.
// The heading reveals; the claims stay visible as running evidence.
export function Trust() {
  const head = useReveal<HTMLHeadingElement>()

  return (
    <section id="trust" className="closing trust" aria-labelledby="trust-title">
      <div className="closing-inner">
        <h2 className="closing-h2 reveal" id="trust-title" ref={head}>
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
