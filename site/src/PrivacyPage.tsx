import { useEffect, useState } from 'react'
import { Header } from './components/Header'
import { Footer } from './components/Footer'
import { privacy } from './content/copy'
import './components/Privacy.css'

const sourceBase = 'https://github.com/Rydersel/Candela/blob/main/site'

export function PrivacyPage() {
  const [status, setStatus] = useState<string | null>(null)

  useEffect(() => {
    setStatus(new URLSearchParams(window.location.search).get('status'))
  }, [])

  return (
    <>
      <Header homeHref="/" faqHref="/#faq" />
      <main id="content" className="privacy-page">
        <article className="privacy-article">
          <header className="privacy-intro">
            <p className="privacy-kicker">Candela website</p>
            <h1>{privacy.h1}</h1>
            <p className="privacy-lead">{privacy.lead}</p>
          </header>

          {status === 'off' && <p className="privacy-status" role="status">Website analytics are off in this browser.</p>}
          {status === 'on' && <p className="privacy-status" role="status">Website analytics are on in this browser.</p>}

          <section className="privacy-control" aria-labelledby="privacy-control-title">
            <div>
              <h2 id="privacy-control-title">Your choice</h2>
              <p>{privacy.control}</p>
            </div>
            <div className="privacy-control-actions">
              <form method="post" action="/analytics/opt-out">
                <button className="privacy-button privacy-button-primary" type="submit">Opt out</button>
              </form>
              <form method="post" action="/analytics/opt-in">
                <button className="privacy-button" type="submit">Opt in</button>
              </form>
            </div>
          </section>

          <section className="privacy-section">
            <h2>What the app does</h2>
            <p>{privacy.app}</p>
          </section>

          <div className="privacy-columns">
            <section className="privacy-section">
              <h2>What the website records</h2>
              <ul>{privacy.does.map((item) => <li key={item}>{item}</li>)}</ul>
            </section>
            <section className="privacy-section">
              <h2>What it never records</h2>
              <ul>{privacy.doesNot.map((item) => <li key={item}>{item}</li>)}</ul>
            </section>
          </div>

          <section className="privacy-section">
            <h2>Retention and counting</h2>
            {privacy.retention.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
          </section>

          <section className="privacy-section privacy-source">
            <p className="privacy-kicker">Public by design</p>
            <h2>Read the complete implementation</h2>
            <p>{privacy.source}</p>
            <ul>
              <li><a href={`${sourceBase}/functions/analytics/visit.ts`}>Visit and cookie Function</a></li>
              <li><a href={`${sourceBase}/functions/analytics/opt-out.ts`}>Opt-out Function</a></li>
              <li><a href={`${sourceBase}/migrations/0001_analytics.sql`}>D1 schema</a></li>
              <li><a href={`${sourceBase}/analytics-worker/src/index.ts`}>Retention and rollup Worker</a></li>
              <li><a href={`${sourceBase}/scripts/analytics-report.mjs`}>Analytics report command</a></li>
              <li><a href={`${sourceBase}/src/PrivacyPage.tsx`}>This Privacy page</a></li>
            </ul>
          </section>
        </article>
      </main>
      <Footer />
    </>
  )
}
