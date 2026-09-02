import { Header } from './components/Header'
import { Footer } from './components/Footer'
import { guides as copy, hero, navigation } from './content/copy'
import { formatGuideDate, type Guide } from './guides'
import candelaMark from './assets/candela-c.svg'
import './components/Guide.css'

// The body is Markdown from this repository rendered at build time, so the
// raw HTML here is our own copy, never anything a visitor supplied.
export function GuidePage({ guide, guides }: { guide: Guide; guides: Guide[] }) {
  const more = guides.filter((entry) => entry.slug !== guide.slug)

  return (
    <>
      <Header homeHref="/" faqHref="/#faq" placement="guide" />
      <main id="content" className="guide-page">
        <article className="guide-article">
          <header className="guide-intro">
            <p className="guide-kicker">
              <a href="/guides/">{copy.h1}</a>
            </p>
            <h1>{guide.title}</h1>
            <p className="guide-meta">
              <span>
                {copy.updated} <time dateTime={guide.updated}>{formatGuideDate(guide.updated)}</time>
              </span>
            </p>
          </header>

          {guide.hero && (
            <figure className="guide-hero">
              {/* Decorative: the title above carries the meaning, so no alt text. */}
              <img src={guide.hero.src} alt="" width={guide.hero.width} height={guide.hero.height} decoding="async" fetchPriority="high" />
            </figure>
          )}

          <div className="guide-body" dangerouslySetInnerHTML={{ __html: guide.html }} />

          {/* The section's one conversion, styled after the social card. */}
          <section className="guide-try" aria-labelledby="guide-try-title">
            <p className="guide-try-brand">
              <img src={candelaMark} alt="" width="26" height="27" />
              <span>{navigation.brand}</span>
            </p>
            {/* The landing hero's line, so this card and the social card match; the full stop is the accent wick. */}
            <h2 id="guide-try-title">
              {hero.h1.replace(/\.$/, '')}
              <span className="guide-try-wick">.</span>
            </h2>
            <ul className="guide-try-pillars" role="list">
              {copy.tryPillars.map((pillar) => (
                <li key={pillar}>{pillar}</li>
              ))}
            </ul>
            <div className="guide-try-actions">
              <a className="guide-try-primary" href="/download?placement=guide">
                {hero.ctaPrimary}
              </a>
              <a className="guide-try-secondary" href="/github?placement=guide">
                {hero.ctaSecondary}
              </a>
              <span className="guide-try-foss">{hero.foss}</span>
            </div>
          </section>

          {more.length > 0 && (
            <nav className="guide-more" aria-labelledby="guide-more-title">
              <h2 id="guide-more-title">{copy.more}</h2>
              {/* role restated: the global list-style reset drops implicit list
                  semantics in Safari. */}
              <ul role="list">
                {more.map((entry) => (
                  <li key={entry.slug}>
                    <a href={entry.path}>{entry.title}</a>
                  </li>
                ))}
              </ul>
            </nav>
          )}
        </article>
      </main>
      <Footer placement="guide" />
    </>
  )
}
