import { footer, hero } from '../content/copy'
import candelaMark from '../assets/candela-c.svg'
import './Closing.css'

// Outside <main> in App.tsx so this is a real contentinfo landmark; nested in
// main it would be a plain group. The release action stays visibly held here
// as it does in the hero, while GitHub remains available.
export function Footer() {
  return (
    <footer className="closing site-footer">
      <div className="closing-inner closing-rule-top footer-inner">
        <div className="footer-brand">
          <img className="footer-mark" src={candelaMark} alt="" width="22" height="23" />
          <p className="footer-note">{footer.note}</p>
        </div>
        <div className="footer-links">
          <button className="footer-link footer-link-lit" type="button" disabled>
            {hero.ctaPrimary}
          </button>
          <a className="footer-link" href="/github?placement=footer">
            {hero.ctaSecondary}
          </a>
          <a className="footer-link" href="/privacy/">Privacy</a>
        </div>
      </div>
    </footer>
  )
}
