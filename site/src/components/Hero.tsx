import { useEffect, useRef, useState } from 'react'
import { brew, hero } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { HeroBackdropSwirl } from './HeroBackdropSwirl'
import candelaMark from '../assets/candela-c.svg'
import './Hero.css'

// The quiet alternate install route under the CTAs. It reads as a measured
// install rail rather than a competing CTA or a miniature terminal window.
function BrewInstall() {
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle')
  const timer = useRef(0)

  useEffect(() => () => window.clearTimeout(timer.current), [])

  const copy = () => {
    const write = navigator.clipboard?.writeText(brew.cmd)
    if (!write) {
      setCopyState('failed')
      window.clearTimeout(timer.current)
      timer.current = window.setTimeout(() => setCopyState('idle'), 2500)
      return
    }

    write
      .then(() => {
        setCopyState('copied')
        window.clearTimeout(timer.current)
        timer.current = window.setTimeout(() => setCopyState('idle'), 2000)
      })
      .catch(() => {
        setCopyState('failed')
        window.clearTimeout(timer.current)
        timer.current = window.setTimeout(() => setCopyState('idle'), 2500)
      })
  }

  const feedback = copyState === 'copied' ? brew.copied : copyState === 'failed' ? brew.failed : brew.hint

  return (
    <button
      type="button"
      className="hero-brew"
      data-state={copyState === 'idle' ? undefined : copyState}
      onClick={copy}
      aria-label={brew.copyLabel}
    >
      <span className="hero-brew-cmd">
        <span className="hero-brew-dollar" aria-hidden="true">
          ${' '}
        </span>
        {brew.cmd}
      </span>
      <span className="hero-brew-hint" aria-hidden="true">
        {feedback}
      </span>
      <span className="sr-only" role="status" aria-live="polite">
        {copyState === 'idle' ? '' : feedback}
      </span>
    </button>
  )
}

// First screen: the premise, the one-liner, the two actions, and the capture
// glowing out of the dark underneath them. The foss line rides with the CTA
// cluster per SR8, never below the fold and never footer-weight.
export function Hero() {
  return (
    <section id="top" className="hero">
      <HeroBackdropSwirl />
      <div className="hero-copy">
        <img className="hero-mark" src={candelaMark} alt="" width="44" height="46" />
        <h1 className="hero-h1">{hero.h1}</h1>
        <p className="hero-sub">{hero.sub}</p>
        <div className="hero-actions">
          <button className="hero-cta" type="button" disabled>
            {hero.ctaPrimary}
          </button>
          <a className="hero-quiet" href="/github?placement=hero">
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
