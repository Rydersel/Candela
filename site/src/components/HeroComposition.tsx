import displayWin from '../assets/captures/hero/display-1280.webp'
import displayWin960 from '../assets/captures/hero/display-960.webp'
import displayWin640 from '../assets/captures/hero/display-640.webp'
import displayWin384 from '../assets/captures/hero/display-384.webp'
import healthWin from '../assets/captures/hero/health-1280.webp'
import healthWin960 from '../assets/captures/hero/health-960.webp'
import healthWin640 from '../assets/captures/hero/health-640.webp'
import healthWin384 from '../assets/captures/hero/health-384.webp'
import heatmapWin from '../assets/captures/hero/heatmap-576.webp'
import heatmapWin432 from '../assets/captures/hero/heatmap-432.webp'
import heatmapWin288 from '../assets/captures/hero/heatmap-288.webp'
import menubarWin from '../assets/captures/hero/menubar-352.webp'
import menubarWin264 from '../assets/captures/hero/menubar-264.webp'
import menubarWin176 from '../assets/captures/hero/menubar-176.webp'
import sunriseBg from '../assets/captures/hero/sunrise-bg.webp'
import sunriseBg1800 from '../assets/captures/hero/sunrise-bg-1800.webp'
import sunriseBg1200 from '../assets/captures/hero/sunrise-bg-1200.webp'
import sunriseBg800 from '../assets/captures/hero/sunrise-bg-800.webp'
import './HeroComposition.css'

// The hero composed in the page rather than exported as one picture: four
// window captures (each at its own 2x, no baked shadow) on a desktop, placed
// on a fixed 12:7 stage by percentage, so every window keeps crisp text, gets
// its own hairline and shadow, and can be moved without a re-export.
//
// Positions restate the approved composition (2026-09-01) as fractions of a
// 2000 by 1166 layout: left, top, width. Each window ships at three widths
// sized to the slot it fills (the stage caps at 68rem, so the largest is the
// slot's 2x), and `sizes` tells the browser the slot's share of the viewport
// so the pick happens before layout. The desktop is a real <img> rather than
// a CSS background so the preload scanner finds the page's largest paint in
// the prerendered HTML instead of after the stylesheet.
const STAGE_MAX_PX = 1088

const layers = [
  { key: 'display', srcSet: `${displayWin384} 384w, ${displayWin640} 640w, ${displayWin960} 960w, ${displayWin} 1280w`, src: displayWin, w: 1280, h: 929, left: 3.7, top: 4, width: 58, priority: true, alt: "A display's own page in Candela's settings: the MAG 341C OLED at 3440 by 1440, 175 Hz, enrolled in OLED Care, with its brightness and volume levels." },
  { key: 'health', srcSet: `${healthWin384} 384w, ${healthWin640} 640w, ${healthWin960} 960w, ${healthWin} 1280w`, src: healthWin, w: 1280, h: 929, left: 45.2, top: 28.3, width: 51.3, priority: false, alt: 'The Health pane: exposure thumbnails, hours and hottest-area figures for two displays, and the measurement switches.' },
  { key: 'heatmap', srcSet: `${heatmapWin288} 288w, ${heatmapWin432} 432w, ${heatmapWin} 576w`, src: heatmapWin, w: 576, h: 584, left: 1.2, top: 53.8, width: 25.8, priority: false, alt: 'The Heat Map window for the MAG 341C OLED: where the display has been lit, hottest area 2.4 times the average.' },
  { key: 'menubar', srcSet: `${menubarWin176} 176w, ${menubarWin264} 264w, ${menubarWin} 352w`, src: menubarWin, w: 352, h: 724, left: 84.5, top: 1, width: 15, priority: false, alt: 'The menu-bar controls: brightness for every display, volume and resolution per display, keep display awake.' },
] as const

function slotSizes(widthPercent: number) {
  return `(min-width: ${STAGE_MAX_PX + 64}px) ${Math.round((STAGE_MAX_PX * widthPercent) / 100)}px, ${widthPercent}vw`
}

export function HeroComposition() {
  return (
    <div
      className="hero-comp"
      role="img"
      aria-label="Candela's settings, heat map and menu-bar controls arranged as a desk of windows over a macOS desktop."
    >
      <img
        className="hero-comp-bg"
        src={sunriseBg}
        srcSet={`${sunriseBg800} 800w, ${sunriseBg1200} 1200w, ${sunriseBg1800} 1800w, ${sunriseBg} 2400w`}
        sizes={`(min-width: ${STAGE_MAX_PX + 64}px) ${STAGE_MAX_PX}px, 100vw`}
        width={2400}
        height={1400}
        alt=""
        loading="eager"
        fetchPriority="high"
        decoding="async"
      />
      <span className="hero-comp-tint" aria-hidden="true" />
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
            srcSet={l.srcSet}
            sizes={slotSizes(l.width)}
            width={l.w}
            height={l.h}
            alt={l.alt}
            loading="eager"
            fetchPriority={l.priority ? 'high' : 'auto'}
            decoding="async"
          />
        </div>
      ))}
      <span className="hero-comp-ring" aria-hidden="true" />
    </div>
  )
}
