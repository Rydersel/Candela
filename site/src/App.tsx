import { useEffect } from 'react'
import { Hero } from './components/Hero'
import { Header } from './components/Header'
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
import { PrivacyPage } from './PrivacyPage'
import { GuidePage } from './GuidePage'
import { GuidesIndexPage } from './GuidesIndexPage'
import type { Guide } from './guides'

function LandingPage() {
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
      <Header />
      <main id="content">
        <Hero />
        <GlanceBand />
        <SectionProtection />
        <SectionCheckup />
        <SectionControls />
        <SectionSizes />
        <SectionSetup />
        <SectionMore />
        <Trust />
        <Faq />
      </main>
      {/* Outside main: a footer nested in main is not a contentinfo landmark. */}
      <Footer />
    </>
  )
}

// Only the SSR entry supplies guides. In the browser the list is empty and no
// guide path hydrates, so the guide branches are dead there on purpose.
export default function App({ pathname = '/', guides = [] }: { pathname?: string; guides?: Guide[] }) {
  const path = pathname.replace(/\/+$/, '')
  if (path === '/privacy') return <PrivacyPage />
  if (path === '/guides') return <GuidesIndexPage guides={guides} />
  const guide = guides.find((entry) => `/guides/${entry.slug}` === path)
  if (guide) return <GuidePage guide={guide} guides={guides} />
  return <LandingPage />
}
