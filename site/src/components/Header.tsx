import { navigation } from '../content/copy'
import './Header.css'

export function Header({ homeHref = '#top', faqHref = '#faq' }: { homeHref?: string; faqHref?: string }) {
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
            <a className="site-nav-link" href={faqHref}>
              {navigation.faq}
            </a>
            <a className="site-nav-link" href="/github?placement=header">
              {navigation.github}
            </a>
            <button className="site-nav-download" type="button" disabled>
              {navigation.download}
            </button>
          </div>
        </nav>
      </header>
    </>
  )
}
