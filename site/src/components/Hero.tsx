import { useEffect, useRef, useState } from 'react'
import { brew, hero } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { HeroBackdropSwirl } from './HeroBackdropSwirl'
import candelaMark from '../assets/candela-c.svg'
import './Hero.css'

// The quiet alternate install route under the CTAs. Copies the command
// without the decorative dollar sign; the hint carries the feedback on wide
// screens, and on narrow ones a centered overlay does (Hero.css), so the
// pill never has to fit both the command and the hint at once.
function BrewInstall() {
  const [copied, setCopied] = useState(false)
  const timer = useRef(0)

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const copy = () => {
    navigator.clipboard
      .writeText(brew.cmd)
      .then(() => {
        setCopied(true)
        window.clearTimeout(timer.current)
        timer.current = window.setTimeout(() => setCopied(false), 2000)
      })
      .catch(() => {})
  }

  return (
    <button
      type="button"
      className="hero-brew"
      data-copied={copied || undefined}
      onClick={copy}
      aria-label={brew.copyLabel}
    >
      <span className="hero-brew-cmd">
        <span className="hero-brew-dollar" aria-hidden="true">
          ${' '}
        </span>
        {brew.cmd}
      </span>
      <span className="hero-brew-hint" aria-live="polite">
        {copied ? brew.copied : brew.hint}
      </span>
      <span className="hero-brew-copied" aria-hidden="true">
        {brew.copied}
      </span>
    </button>
  )
}

// First screen: the premise, the one-liner, the two actions, and the capture
// glowing out of the dark underneath them. The foss line rides with the CTA
// cluster per SR8, never below the fold and never footer-weight.
export function Hero() {
  return (
    <section className="hero">
      <HeroBackdropSwirl />
      <div className="hero-copy">
        <img className="hero-mark" src={candelaMark} alt="" width="44" height="46" />
        <h1 className="hero-h1">{hero.h1}</h1>
        <p className="hero-sub">{hero.sub}</p>
        <div className="hero-actions">
          <a className="hero-cta" href="/download">
            {hero.ctaPrimary}
          </a>
          <a className="hero-quiet" href="https://github.com/Rydersel/Candela">
            {hero.ctaSecondary}
          </a>
        </div>
        <BrewInstall />
        <p className="hero-foss">{hero.foss}</p>
      </div>
      <div className="hero-stage">
        <MediaFrame asset={assets.hero} className="hero-capture" />
      </div>
    </section>
  )
}
