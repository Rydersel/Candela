import type { CSSProperties } from 'react'
import displayWin from '../assets/captures/hero/display.webp'
import healthWin from '../assets/captures/hero/health.webp'
import heatmapWin from '../assets/captures/hero/heatmap.webp'
import menubarWin from '../assets/captures/hero/menubar.webp'
import sunriseBg from '../assets/captures/hero/sunrise-bg.webp'
import './HeroComposition.css'

// The hero composed in the page rather than exported as one picture: four
// window captures (each at its own 2x, no baked shadow) on a desktop, placed
// on a fixed 12:7 stage by percentage, so every window keeps crisp text, gets
// its own hairline and shadow, and can be moved without a re-export.
//
// Positions restate the approved composition (2026-09-01) as fractions of a
// 2000 by 1166 layout: left, top, width.
const layers = [
  { key: 'display', src: displayWin, w: 2080, h: 1524, left: 3.7, top: 4, width: 58, alt: "A display's own page in Candela's settings: the MAG 341C OLED at 3440 by 1440, 175 Hz, enrolled in OLED Care, with its brightness and volume levels." },
  { key: 'health', src: healthWin, w: 2080, h: 1524, left: 45.2, top: 28.3, width: 51.3, alt: 'The Health pane: exposure thumbnails, hours and hottest-area figures for two displays, and the measurement switches.' },
  { key: 'heatmap', src: heatmapWin, w: 1120, h: 1136, left: 1.2, top: 53.8, width: 25.8, alt: 'The Heat Map window for the MAG 341C OLED: where the display has been lit, hottest area 2.4 times the average.' },
  { key: 'menubar', src: menubarWin, w: 560, h: 1152, left: 84.5, top: 1, width: 15, alt: 'The menu-bar controls: brightness for every display, volume and resolution per display, keep display awake.' },
] as const

export function HeroComposition() {
  return (
    <div
      className="hero-comp"
      role="img"
      aria-label="Candela's settings, heat map and menu-bar controls arranged as a desk of windows over a macOS desktop."
      style={{ '--hero-comp-bg': `url(${sunriseBg})` } as CSSProperties}
    >
      {layers.map((l, i) => (
        // The slot owns the arrival animation so the image's own box stays
        // free of transforms.
        <div
          key={l.key}
          className={`hero-comp-slot hero-comp-slot-${l.key}`}
          style={{ left: `${l.left}%`, top: `${l.top}%`, width: `${l.width}%`, animationDelay: `${0.15 + i * 0.09}s` }}
        >
          <img
            className="hero-comp-win"
            src={l.src}
            width={l.w}
            height={l.h}
            alt={l.alt}
            loading="eager"
            fetchPriority="high"
            decoding="async"
          />
        </div>
      ))}
      <span className="hero-comp-ring" aria-hidden="true" />
    </div>
  )
}
