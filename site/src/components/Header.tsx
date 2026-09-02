import { navigation } from '../content/copy'
import './Header.css'

// placement tags this header's two actions with the section they were clicked
// from, so guide traffic is countable apart from the landing page's.
export function Header({
  homeHref = '#top',
  faqHref = '#faq',
  placement = 'header',
}: {
  homeHref?: string
  faqHref?: string
  placement?: 'header' | 'guide'
}) {
  return (
    <>
      <a className="skip-link" href="#content">
        {navigation.skip}
      </a>
      <header className="site-header">
        <nav className="site-nav" aria-label={navigation.label}>
          <a className="site-brand" href={homeHref}>
            {navigation.brand}
          </a>
          <div className="site-nav-links">
            <a className="site-nav-link" href="/guides/">
              {navigation.guides}
            </a>
            <a className="site-nav-link" href={faqHref}>
              {navigation.faq}
            </a>
            <a className="site-nav-link" href={`/github?placement=${placement}`}>
              {navigation.github}
            </a>
            <a className="site-nav-download" href={`/download?placement=${placement}`}>
              {navigation.download}
            </a>
          </div>
        </nav>
      </header>
    </>
  )
}
