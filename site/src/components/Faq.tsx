import { faq, faqH2 } from '../content/copy'
import './Closing.css'

// The summaries stay plain text rather than headings: five questions under one
// h2 is the outline a screen reader wants, and nesting h3s inside disclosure
// controls would put a heading level behind a toggle.
//
// Native <details> per item, so open and close, keyboard operation and find in
// page all work without a line of JavaScript.
export function Faq() {
  return (
    <section id="faq" className="closing faq">
      <div className="closing-inner">
        <h2 className="closing-h2">{faqH2}</h2>
        {/* role restated for the same reason the glance band restates it: the
            global list-style reset drops implicit list semantics in Safari. */}
        <ul className="faq-list" role="list">
          {faq.map((entry) => (
            <li key={entry.q}>
              <details className="faq-item">
                <summary className="faq-q">{entry.q}</summary>
                <p className="faq-a">{entry.a}</p>
              </details>
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}
