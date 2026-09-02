import { Header } from './components/Header'
import { Footer } from './components/Footer'
import { terms } from './content/copy'
// Shared with the privacy page; a second copy of this CSS would drift.
import './components/Privacy.css'

const repoBase = 'https://github.com/Rydersel/Candela/blob/main'

export function TermsPage() {
  return (
    <>
      <Header homeHref="/" faqHref="/#faq" />
      <main id="content" className="privacy-page terms-page">
        <article className="privacy-article">
          <header className="privacy-intro">
            <p className="privacy-kicker">{terms.kicker}</p>
            <h1>{terms.h1}</h1>
            <p className="privacy-lead">{terms.lead}</p>
            <p className="privacy-effective">{terms.effective}</p>
          </header>

          <section className="privacy-section">
            <h2>{terms.who.h2}</h2>
            {terms.who.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section">
            <h2>{terms.license.h2}</h2>
            {terms.license.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section">
            <h2>{terms.hardware.h2}</h2>
            {terms.hardware.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <div className="privacy-columns">
            <section className="privacy-section">
              <h2>{terms.countOn.h2}</h2>
              <ul>{terms.countOn.items.map((item) => <li key={item}>{item}</li>)}</ul>
            </section>
            <section className="privacy-section">
              <h2>{terms.agreeTo.h2}</h2>
              <ul>{terms.agreeTo.items.map((item) => <li key={item}>{item}</li>)}</ul>
            </section>
          </div>

          <section className="privacy-section">
            <h2>{terms.updates.h2}</h2>
            {terms.updates.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section">
            <h2>{terms.warranty.h2}</h2>
            {terms.warranty.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section">
            <h2>{terms.site.h2}</h2>
            {terms.site.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section">
            <h2>{terms.changes.h2}</h2>
            {terms.changes.body.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section privacy-source">
            <p className="privacy-kicker">Public by design</p>
            <h2>Read the documents these terms point to</h2>
            <p>{terms.source}</p>
            <ul>
              <li><a href={`${repoBase}/LICENSE`}>MIT license</a></li>
              <li><a href={`${repoBase}/THIRD-PARTY-LICENSES.md`}>Third-party credits</a></li>
              <li><a href={`${repoBase}/SECURITY.md`}>Security policy</a></li>
              <li><a href="/privacy/">Privacy page</a></li>
              <li><a href={`${repoBase}/site/src/TermsPage.tsx`}>This Terms page</a></li>
            </ul>
          </section>
        </article>
      </main>
      <Footer />
    </>
  )
}
