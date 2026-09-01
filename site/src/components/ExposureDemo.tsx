import { useEffect, useRef, useState } from 'react'
import { exposureDemo, mediaPause, mediaResume } from '../content/copy'
import './ExposureDemo.css'

// The record accumulating, drawn abstractly instead of panned over: the same
// 240-cell grid the dim figure uses, starting dark and warming into the
// habit pattern. Hot regions surface first, the way a menu bar's record
// outruns a corner nobody uses. The loop eases the record up, holds it, and
// starts again.

const COLS = 24
const ROWS = 10

function speckle(col: number, row: number): number {
  return (((col * 11 + row * 17) % 7) / 7) * 0.06
}

// The habit pattern the record grows into: menu bar, a parked window with
// its title bar, the dock, a faint second window.
function habitHeat(col: number, row: number): number {
  let heat = 0.06 + speckle(col, row)
  if (row === 0) heat = 0.85
  if (row === ROWS - 1 && col >= 8 && col <= 15) heat = 0.6
  if (col >= 2 && col <= 12 && row >= 2 && row <= 7) {
    heat = Math.max(heat, row === 2 ? 0.75 : 0.55 - 0.03 * Math.abs(col - 7))
  }
  if (col >= 15 && col <= 21 && row >= 3 && row <= 6) heat = Math.max(heat, 0.3)
  return heat
}

const cells = Array.from({ length: COLS * ROWS }, (_, i) => habitHeat(i % COLS, Math.floor(i / COLS)))

// Hotter cells surface earlier: each cell's record starts rising after a
// delay proportional to how cold it is.
function lumAt(heat: number, progress: number): number {
  const delay = (1 - heat) * 0.45
  const local = Math.max(0, Math.min(1, (progress - delay) / (1 - delay)))
  return heat * local
}

const STEP_MS = 260
const HOLD_STEPS = 12
const RISE_STEPS = 26

export function ExposureDemo() {
  const [progress, setProgress] = useState(0)
  const [paused, setPaused] = useState(false)
  const pausedRef = useRef(false)
  const onScreenRef = useRef(false)
  const stepRef = useRef(0)
  const timerRef = useRef(0)
  const tickRef = useRef<() => void>(() => {})
  const figRef = useRef<HTMLElement>(null)

  // Runs only on screen, the same rule MediaFrame applies to the videos:
  // scrolled away, the accumulation stops; back, it continues where it was,
  // unless the visitor's own pause outranks it.
  useEffect(() => {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
    if (reduced.matches) {
      // No animation: the finished record is the concept.
      setProgress(1)
      return
    }

    const tick = () => {
      if (pausedRef.current || !onScreenRef.current) return
      stepRef.current = (stepRef.current + 1) % (RISE_STEPS + HOLD_STEPS)
      setProgress(Math.min(1, stepRef.current / RISE_STEPS))
      timerRef.current = window.setTimeout(tick, STEP_MS)
    }
    tickRef.current = tick

    const io = new IntersectionObserver(
      ([entry]) => {
        onScreenRef.current = entry.isIntersecting
        window.clearTimeout(timerRef.current)
        if (entry.isIntersecting && !pausedRef.current) {
          timerRef.current = window.setTimeout(tick, STEP_MS)
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
        timerRef.current = window.setTimeout(tickRef.current, STEP_MS)
      }
    } else {
      pausedRef.current = true
      setPaused(true)
      window.clearTimeout(timerRef.current)
    }
  }

  return (
    <div className="media-shell">
      <figure ref={figRef} className="exposure-demo" role="img" aria-label={exposureDemo.figureLabel}>
        <div className="exposure-grid" aria-hidden="true">
          {cells.map((heat, i) => (
            <span
              className="exposure-cell"
              key={i}
              style={{ '--lum': lumAt(heat, progress) } as React.CSSProperties}
            />
          ))}
        </div>
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
