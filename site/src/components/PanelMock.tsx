import type { ReactNode } from 'react'
import { useReveal } from '../useReveal.ts'

function Slider({ pct, left, right }: { pct: number; left: ReactNode; right: ReactNode }) {
  return (
    <div className="row slider">
      {left}
      <div className="track">
        <div className="fill" style={{ width: `${pct}%` }} />
        <div className="knob" style={{ left: `${pct}%` }} />
      </div>
      {right}
    </div>
  )
}

export default function PanelMock() {
  const ref = useReveal<HTMLElement>()
  return (
    <section id="panel" className="wrap reveal" ref={ref}>
      <div className="stage">
        <div className="glowbed" aria-hidden="true" />
        <div
          className="mock"
          role="img"
          aria-label="The Candela menu bar panel: brightness and volume sliders, HiDPI resolution list, and an HDR toggle"
        >
          <div className="menubar">
            <span className="mb-left">{''}&ensp;Candela</span>
            <span className="mb-right">
              <span className="mb-icon active">
                <svg viewBox="0 0 64 64" width="14" height="14">
                  <path d="M32 14c5 7 9 11 9 17a9 9 0 1 1-18 0c0-6 4-10 9-17z" fill="none" stroke="currentColor" strokeWidth="4" />
                </svg>
              </span>
              <span className="mb-time">Wed 9:41 AM</span>
            </span>
          </div>
          <div className="dropdown">
            <div className="row head"><span>MSI MAG 341C</span><span className="chev">›</span></div>
            <div className="row label">Brightness</div>
            <Slider
              pct={72}
              left={<svg className="s-ic" viewBox="0 0 16 16" width="13" height="13"><circle cx="8" cy="8" r="3.2" fill="currentColor" /></svg>}
              right={
                <svg className="s-ic" viewBox="0 0 16 16" width="15" height="15">
                  <circle cx="8" cy="8" r="3" fill="currentColor" />
                  <g stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
                    <path d="M8 1.2v2M8 12.8v2M1.2 8h2M12.8 8h2M3.2 3.2l1.4 1.4M11.4 11.4l1.4 1.4M12.8 3.2l-1.4 1.4M4.6 11.4l-1.4 1.4" />
                  </g>
                </svg>
              }
            />
            <div className="row label">Volume</div>
            <Slider
              pct={45}
              left={<svg className="s-ic" viewBox="0 0 16 16" width="13" height="13"><path d="M2 6h3l4-3v10L5 10H2z" fill="currentColor" /></svg>}
              right={
                <svg className="s-ic" viewBox="0 0 16 16" width="15" height="15">
                  <path d="M2 6h3l4-3v10L5 10H2z" fill="currentColor" />
                  <path d="M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.5a6 6 0 0 1 0 9" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
                </svg>
              }
            />
            <div className="divider" />
            <div className="row label">Resolution</div>
            <div className="row option on"><span className="check">✓</span>3440 × 1440&ensp;<span className="tag">HiDPI</span></div>
            <div className="row option"><span className="check" />2752 × 1152&ensp;<span className="tag">HiDPI</span></div>
            <div className="row option"><span className="check" />2560 × 1080&ensp;<span className="tag">HiDPI</span></div>
            <div className="divider" />
            <div className="row toggle-row"><span>HDR</span><span className="switch on"><span className="dot" /></span></div>
          </div>
        </div>
      </div>
    </section>
  )
}
