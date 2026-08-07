import type { ReactNode } from 'react'
import { useReveal } from '../useReveal.ts'

type Feature = { glyph: ReactNode; title: string; copy: string }

const stroke = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.6 } as const

const FEATURES: Feature[] = [
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <rect x="2" y="4" width="20" height="13" rx="2" {...stroke} />
        <path d="M9 21h6M12 17v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        <path d="M6.5 10.5l2.5 2.5 4.5-4.5" {...stroke} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ),
    title: 'Any resolution. Really.',
    copy: "macOS offers a handful of scaled sizes — and makes 4K monitors choose between too small and blurry. Candela unlocks any resolution on any display: Retina-sharp HiDPI at the size you actually want, at the panel's full refresh rate.",
  },
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <circle cx="12" cy="12" r="4" {...stroke} />
        <g stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
          <path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2" />
        </g>
      </svg>
    ),
    title: 'Real brightness & volume',
    copy: "Controls the monitor's own hardware over DDC/CI — the real backlight, the real speakers. And software dimming keeps going below the hardware floor.",
  },
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <rect x="2" y="5" width="13" height="10" rx="2" {...stroke} />
        <rect x="11" y="10" width="11" height="8" rx="2" {...stroke} strokeDasharray="2.5 2.5" />
      </svg>
    ),
    title: 'Virtual displays',
    copy: "Create displays out of thin air: headless setups, streaming and recording targets, and the machinery behind sharp scaling on displays macOS won't help.",
  },
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <rect x="2" y="7" width="9" height="7" rx="1.5" {...stroke} />
        <rect x="14" y="4" width="7" height="12" rx="1.5" {...stroke} />
        <path d="M6 18a6 6 0 0 0 10-2" {...stroke} strokeLinecap="round" />
        <path d="M16.5 14.5l-.6 2.3 2.3-.6" {...stroke} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ),
    title: 'Arrange, mirror, rotate',
    copy: 'A drag-to-arrange canvas, saved layouts that restore themselves, and mirroring and rotation — without a trip to System Settings.',
  },
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <path d="M12 3l7 2.5v5c0 4.8-3 8.6-7 10.5-4-1.9-7-5.7-7-10.5v-5z" {...stroke} strokeLinejoin="round" />
        <path d="M9 11.5l2.2 2.2 4-4" {...stroke} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ),
    title: 'Built for OLED',
    copy: 'Auto-hide for the menu bar and Dock, plus care features that protect your panel from static UI burn-in.',
  },
  {
    glyph: (
      <svg className="glyph" viewBox="0 0 24 24">
        <path d="M8.5 6.5L3 12l5.5 5.5M15.5 6.5L21 12l-5.5 5.5" {...stroke} strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    ),
    title: '100% free, 100% open',
    copy: 'Every feature, free forever. No Pro tier, no license key, no upsell. MIT-licensed and developed in the open on GitHub.',
  },
]

function Card({ glyph, title, copy }: Feature) {
  const ref = useReveal<HTMLDivElement>()
  return (
    <div className="card reveal" ref={ref}>
      {glyph}
      <h3>{title}</h3>
      <p>{copy}</p>
    </div>
  )
}

export default function FeatureGrid() {
  return (
    <section id="features" className="wrap">
      <div className="grid">
        {FEATURES.map((f) => (
          <Card key={f.title} {...f} />
        ))}
      </div>
    </section>
  )
}
