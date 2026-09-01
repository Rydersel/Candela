import { footer, hero } from '../content/copy'
import candelaMark from '../assets/candela-c.svg'
import './Closing.css'

// Outside <main> in App.tsx so this is a real contentinfo landmark; nested in
// main it would be a plain group. The two links reuse the hero's own action
// labels rather than inventing footer wording, and the download one points at
// the counted /download route the same way the hero button does.
export function Footer() {
  return (
    <footer className="closing site-footer">
      <div className="closing-inner closing-rule-top footer-inner">
        <div className="footer-brand">
          <img className="footer-mark" src={candelaMark} alt="" width="22" height="23" />
          <p className="footer-note">{footer.note}</p>
        </div>
        <div className="footer-links">
          <a className="footer-link footer-link-lit" href="/download">
            {hero.ctaPrimary}
          </a>
          <a className="footer-link" href="https://github.com/Rydersel/Candela">
            {hero.ctaSecondary}
          </a>
        </div>
      </div>
    </footer>
  )
}
