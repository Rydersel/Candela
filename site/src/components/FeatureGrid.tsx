import type { ReactNode } from 'react'
import { useReveal } from '../useReveal.ts'

function Cell({ className = '', children }: { className?: string; children: ReactNode }) {
  const ref = useReveal<HTMLDivElement>()
  return (
    <div className={`cell reveal ${className}`} ref={ref}>
      {children}
    </div>
  )
}

/* Lead card: the HiDPI mode ladder, drawn as the picker it ships as. */
function ResolutionCell() {
  const modes = [
    { size: '3440 × 1440', hz: '175 Hz', on: true },
    { size: '3008 × 1260', hz: '175 Hz', on: false },
    { size: '2752 × 1152', hz: '175 Hz', on: false },
    { size: '2560 × 1080', hz: '175 Hz', on: false },
  ]
  return (
    <Cell className="wide">
      <div className="cell-copy">
        <h3>Any resolution. Really.</h3>
        <p>
          macOS offers a handful of scaled sizes — and makes 4K monitors choose between too small
          and blurry. Candela unlocks any resolution on any display: Retina-sharp HiDPI at the size
          you actually want, at the panel's full refresh rate.
        </p>
      </div>
      <div className="frag frag-modes" aria-hidden="true">
        {modes.map((m) => (
          <div key={m.size} className={`mode-row${m.on ? ' on' : ''}`}>
            <span className="mode-check">{m.on ? '✓' : ''}</span>
            <span className="mode-size">{m.size}</span>
            <span className="tag">HiDPI</span>
            <span className="mode-hz">{m.hz}</span>
          </div>
        ))}
      </div>
    </Cell>
  )
}

/* Reuses the panel mock's slider anatomy — same product, same chrome. */
function ControlCell() {
  return (
    <Cell>
      <h3>Real brightness &amp; volume</h3>
      <p>
        The monitor's own hardware, over DDC/CI — the real backlight, the real speakers. Software
        dimming keeps going below the hardware floor.
      </p>
      <div className="frag frag-sliders" aria-hidden="true">
        <div className="row slider">
          <svg className="s-ic" viewBox="0 0 16 16" width="13" height="13"><circle cx="8" cy="8" r="3.2" fill="currentColor" /></svg>
          <div className="track"><div className="fill" style={{ width: '62%' }} /><div className="knob" style={{ left: '62%' }} /></div>
          <svg className="s-ic" viewBox="0 0 16 16" width="15" height="15">
            <circle cx="8" cy="8" r="3" fill="currentColor" />
            <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
              <path d="M8 1.2v2M8 12.8v2M1.2 8h2M12.8 8h2M3.2 3.2l1.4 1.4M11.4 11.4l1.4 1.4M12.8 3.2l-1.4 1.4M4.6 11.4l-1.4 1.4" />
            </g>
          </svg>
        </div>
        <div className="row slider">
          <svg className="s-ic" viewBox="0 0 16 16" width="13" height="13"><path d="M2 6h3l4-3v10L5 10H2z" fill="currentColor" /></svg>
          <div className="track"><div className="fill" style={{ width: '38%' }} /><div className="knob" style={{ left: '38%' }} /></div>
          <svg className="s-ic" viewBox="0 0 16 16" width="15" height="15">
            <path d="M2 6h3l4-3v10L5 10H2z" fill="currentColor" />
            <path d="M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.5a6 6 0 0 1 0 9" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          </svg>
        </div>
      </div>
    </Cell>
  )
}

/* A second display drawn into existence: solid panel + dashed twin. */
function VirtualCell() {
  return (
    <Cell>
      <h3>Virtual displays</h3>
      <p>
        Create displays out of thin air: headless setups, streaming and recording targets, and the
        machinery behind sharp scaling on displays macOS won't help.
      </p>
      <div className="frag frag-canvas" aria-hidden="true">
        <div className="disp disp-solid"><span className="disp-label">MAG 341C</span></div>
        <div className="disp disp-ghost"><span className="disp-label">Virtual 1</span></div>
      </div>
    </Cell>
  )
}

/* The Displays arrangement canvas in miniature — main strip and a rotated panel. */
function ArrangeCell() {
  return (
    <Cell>
      <h3>Arrange, mirror, rotate</h3>
      <p>
        A drag-to-arrange canvas, saved layouts that restore themselves, and mirroring and rotation
        — without a trip to System Settings.
      </p>
      <div className="frag frag-canvas" aria-hidden="true">
        <div className="disp disp-solid disp-main"><span className="menustrip" /></div>
        <div className="disp disp-solid disp-portrait">
          <svg viewBox="0 0 16 16" width="12" height="12" className="rot">
            <path d="M13 8a5 5 0 1 1-1.5-3.5M11.5 1.5v3h3" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>
      </div>
    </Cell>
  )
}

/* Auto-hide, shown doing it: a menu bar mid-fade. */
function OledCell() {
  return (
    <Cell>
      <h3>Built for OLED</h3>
      <p>
        Auto-hide for the menu bar and Dock, plus care features that protect your panel from static
        UI burn-in.
      </p>
      <div className="frag frag-oled" aria-hidden="true">
        <div className="fade-bar">
          <span className="fb-item" style={{ width: 38 }} />
          <span className="fb-item" style={{ width: 22 }} />
          <span className="fb-item" style={{ width: 30 }} />
          <span className="fb-spacer" />
          <span className="fb-item" style={{ width: 14 }} />
          <span className="fb-item" style={{ width: 14 }} />
          <span className="fb-item" style={{ width: 34 }} />
        </div>
        <div className="fade-dock">
          {[0, 1, 2, 3, 4].map((i) => (
            <span key={i} className="fd-app" />
          ))}
        </div>
      </div>
    </Cell>
  )
}

/* Typographic band — the claim carries itself, no illustration needed. */
function FreeBand() {
  const ref = useReveal<HTMLDivElement>()
  return (
    <div className="cell reveal free-band" ref={ref}>
      <h3>100% free. 100% open.</h3>
      <p>
        Every feature, free forever. No Pro tier, no license key, no upsell — MIT-licensed and
        developed in the open on GitHub.
      </p>
    </div>
  )
}

export default function FeatureGrid() {
  return (
    <section id="features" className="wrap">
      <div className="bento">
        <ResolutionCell />
        <ControlCell />
        <VirtualCell />
        <ArrangeCell />
        <OledCell />
        <FreeBand />
      </div>
    </section>
  )
}
