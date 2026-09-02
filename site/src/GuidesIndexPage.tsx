import { Header } from './components/Header'
import { Footer } from './components/Footer'
import { guides as copy } from './content/copy'
import { formatGuideDate, type Guide } from './guides'
import './components/Guide.css'

export function GuidesIndexPage({ guides }: { guides: Guide[] }) {
  return (
    <>
      <Header homeHref="/" faqHref="/#faq" placement="guide" />
      <main id="content" className="guide-page">
        <div className="guide-article">
          <header className="guide-intro">
            <p className="guide-kicker">{copy.kicker}</p>
            <h1>{copy.h1}</h1>
            <p className="guide-lead">{copy.lead}</p>
          </header>
          {/* role restated: the global list-style reset drops implicit list
              semantics in Safari. */}
          <ul className="guide-list" role="list" aria-label={copy.listLabel}>
            {guides.map((guide) => (
              <li key={guide.slug}>
                <a className="guide-list-link" href={guide.path}>
                  <h2>{guide.title}</h2>
                  <p>{guide.description}</p>
                  <p className="guide-list-meta">
                    {copy.updated} <time dateTime={guide.updated}>{formatGuideDate(guide.updated)}</time>
                  </p>
                </a>
              </li>
            ))}
          </ul>
        </div>
      </main>
      <Footer placement="guide" />
    </>
  )
}
