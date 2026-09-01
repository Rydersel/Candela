import { trust } from '../content/copy'
// .reveal's styles live in DeepSections.css, shared with the four deep
// sections, and useReveal.ts holds the scroll observer that arms them;
// Closing.css carries only this register's own classes.
import { useReveal } from '../useReveal'
import './Closing.css'

// SR6, the one place the honest details live: local-only data, the published
// idle cost, open source forever, and the private-API dependence. Four claims
// carrying equal weight, so they are set as one ledger rather than as cards
// with anything singled out; the private-API row is the same size as the rest
// on purpose. The heading reveals, the claims do not: they are running prose,
// and the deep sections already ruled that prose never scrolls in invisible.
export function Trust() {
  const head = useReveal<HTMLHeadingElement>()

  return (
    <section id="trust" className="closing trust">
      <div className="closing-inner closing-rule-top">
        <h2 className="closing-h2 reveal" ref={head}>
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
