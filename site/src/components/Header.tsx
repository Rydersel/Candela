import { navigation } from '../content/copy'
import './Header.css'

export function Header() {
  return (
    <>
      <a className="skip-link" href="#content">
        {navigation.skip}
      </a>
      <header className="site-header">
        <nav className="site-nav" aria-label={navigation.label}>
          <a className="site-brand" href="#top">
            {navigation.brand}
          </a>
          <div className="site-nav-links">
            <a className="site-nav-link" href="#faq">
              {navigation.faq}
            </a>
            <a className="site-nav-link" href="https://github.com/Rydersel/Candela">
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
