import { useEffect } from 'react'
import { Hero } from './components/Hero'
import { GlanceBand } from './components/GlanceBand'
import { SectionControls } from './components/SectionControls'
import { SectionSizes } from './components/SectionSizes'
import { SectionSetup } from './components/SectionSetup'
import { SectionProtection } from './components/SectionProtection'
import { SectionCheckup } from './components/SectionCheckup'
import { SectionMore } from './components/SectionMore'
import { Trust } from './components/Trust'
import { Faq } from './components/Faq'
import { Footer } from './components/Footer'

export default function App() {
  // Opening a deep link (/#verifies) must land instantly. The browser cannot
  // be trusted with it on an SPA: the target does not exist at parse time, so
  // its own fragment anchoring either never fires or re-anchors late with a
  // visible glide. So the app places the viewport itself, at mount, under the
  // default instant behavior, and only then arms smooth scrolling for in-page
  // anchor clicks (theme.css holds the matching rule), after the load event
  // plus a settling delay so any late browser re-anchor is still instant and
  // a no-op.
  useEffect(() => {
    const id = window.location.hash.slice(1)
    if (id) document.getElementById(id)?.scrollIntoView({ behavior: 'instant', block: 'start' })

    let timer = 0
    const arm = () => {
      timer = window.setTimeout(() => {
        document.documentElement.classList.add('smooth-anchors')
      }, 300)
    }
    if (document.readyState === 'complete') arm()
    else window.addEventListener('load', arm, { once: true })
    return () => {
      window.removeEventListener('load', arm)
      window.clearTimeout(timer)
    }
  }, [])

  return (
    <>
      <main>
        <Hero />
        <GlanceBand />
        <SectionControls />
        <SectionSizes />
        <SectionSetup />
        <SectionProtection />
        <SectionCheckup />
        <SectionMore />
        <Trust />
        <Faq />
      </main>
      {/* Outside main: a footer nested in main is not a contentinfo landmark. */}
      <Footer />
    </>
  )
}
