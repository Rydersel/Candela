import { useEffect, useRef, useState } from 'react'
import { dimDemo, mediaPause, mediaResume } from '../content/copy'
import './DimDemo.css'

// The live local dimming concept, drawn instead of recorded: a screen of 240
// cells (24 x 10, the count the app actually keeps) holding a menu bar, a
// dock, and one window that hops between two spots. The static chrome (menu
// bar, title bar, dock) eases down while the window body stays at full
// brightness; when the window moves, every region whose pixels changed lifts
// instantly, then the chrome settles again in the new spot. CSS owns the
// per-cell motion through a registered --lum property; this component only
// recomputes the 240 targets when the phase turns over.
//
// It reuses MediaFrame's shell and pause classes so the WCAG 2.2.2 stop
// control looks and behaves like every other moving frame on the page.

const COLS = 24
const ROWS = 10

type Layout = 0 | 1
const WINDOWS = [
  { c0: 2, c1: 12, r0: 2, r1: 7 },
  { c0: 11, c1: 21, r0: 3, r1: 8 },
]

// Deterministic speckle so the background and window body read as content
// rather than flat paint, without any per-visitor randomness.
function speckle(col: number, row: number): number {
  return (((col * 7 + row * 13) % 5) / 5) * 0.05
}

function cellLum(col: number, row: number, layout: Layout, settled: boolean): number {
  const win = WINDOWS[layout]
  let lum = 0.07 + speckle(col, row)
  let isStatic = false

  if (row === 0) {
    lum = 0.68
    isStatic = true
  } else if (row === ROWS - 1 && col >= 8 && col <= 15) {
    lum = 0.52
    isStatic = true
  }

  if (col >= win.c0 && col <= win.c1 && row >= win.r0 && row <= win.r1) {
    if (row === win.r0) {
      lum = 0.62
      isStatic = true
    } else {
      lum = 0.5 + speckle(col + layout * 3, row) * 2
      isStatic = false
    }
  }

  return isStatic && settled ? lum * 0.22 : lum
}

type Phase = { layout: Layout; settled: boolean }
const TIMELINE: Array<Phase & { ms: number }> = [
  { layout: 0, settled: false, ms: 2000 },
  { layout: 0, settled: true, ms: 3800 },
  { layout: 1, settled: false, ms: 2000 },
  { layout: 1, settled: true, ms: 3800 },
]

const indices = Array.from({ length: COLS * ROWS }, (_, i) => i)

export function DimDemo() {
  const [phase, setPhase] = useState<Phase>(TIMELINE[0])
  const [paused, setPaused] = useState(false)
  const pausedRef = useRef(false)
  const onScreenRef = useRef(false)
  const stepRef = useRef(0)
  const timerRef = useRef(0)
  const tickRef = useRef<() => void>(() => {})
  const figRef = useRef<HTMLElement>(null)

  // The loop runs only on screen, the same rule MediaFrame applies to the
  // videos: scrolled away, the timeline stops; scrolled back, it resumes
  // where it stood, unless the visitor's own pause outranks it.
  useEffect(() => {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
    if (reduced.matches) {
      // No animation: hold the state that carries the concept, dimmed chrome
      // beside a window at full brightness.
      setPhase({ layout: 0, settled: true })
      return
    }

    const tick = () => {
      if (pausedRef.current || !onScreenRef.current) return
      stepRef.current = (stepRef.current + 1) % TIMELINE.length
      const step = TIMELINE[stepRef.current]
      setPhase({ layout: step.layout, settled: step.settled })
      timerRef.current = window.setTimeout(tick, step.ms)
    }
    tickRef.current = tick

    const io = new IntersectionObserver(
      ([entry]) => {
        onScreenRef.current = entry.isIntersecting
        window.clearTimeout(timerRef.current)
        if (entry.isIntersecting && !pausedRef.current) {
          timerRef.current = window.setTimeout(tick, 700)
        }
      },
      { threshold: 0.2 },
    )
    if (figRef.current) io.observe(figRef.current)
    return () => {
      io.disconnect()
      window.clearTimeout(timerRef.current)
    }
  }, [])

  const toggle = () => {
    if (pausedRef.current) {
      pausedRef.current = false
      setPaused(false)
      if (onScreenRef.current) {
        timerRef.current = window.setTimeout(tickRef.current, 500)
      }
    } else {
      pausedRef.current = true
      setPaused(true)
      window.clearTimeout(timerRef.current)
    }
  }

  return (
    <div className="media-shell">
      <figure
        ref={figRef}
        className="dim-demo"
        data-settled={phase.settled || undefined}
        role="img"
        aria-label={dimDemo.figureLabel}
      >
        <div className="screen" aria-hidden="true">
        <div className="dim-grid">
          {indices.map((i) => (
            <span
              className="dim-cell"
              key={i}
              style={
                {
                  '--lum': cellLum(i % COLS, Math.floor(i / COLS), phase.layout, phase.settled),
                } as React.CSSProperties
              }
            />
          ))}
        </div>
        </div>
        <div className="screen-stand" aria-hidden="true">
          <span />
          <span />
        </div>
        <figcaption className="dim-phase" aria-hidden="true">
          {phase.settled ? dimDemo.phases.settled : dimDemo.phases.lit}
        </figcaption>
      </figure>
      <button
        type="button"
        className="media-toggle"
        data-paused={paused || undefined}
        aria-label={paused ? mediaResume : mediaPause}
        onClick={toggle}
      >
        {paused ? (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 1l7 4-7 4z" fill="currentColor" />
          </svg>
        ) : (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 1h2v8H2zM6 1h2v8H6z" fill="currentColor" />
          </svg>
        )}
      </button>
    </div>
  )
}
