import candelaC from '../assets/candela-c.svg'
import menubarStrip from '../assets/menubar-strip.png'
import panelWindow from '../assets/panel-window.png'

export default function Hero() {
  return (
    <section id="hero">
      <img src={candelaC} alt="" aria-hidden="true" className="hero-bgc" />
      <div className="hero-inner wrap">
        <div className="hero-copy">
          <h1>
            The display control<br className="h1br" /> macOS forgot to ship.
          </h1>
          <p className="sub">
            Candela gives your external monitor everything it should have come with — Retina-sharp
            scaling at any resolution, real hardware brightness and volume, virtual displays, and
            more. Free and open source.
          </p>
          <div className="cta">
            <a className="btn btn-primary" href="https://github.com/Rydersel/Candela/releases/latest">Download for macOS</a>
            <a className="btn btn-quiet" href="https://github.com/Rydersel/Candela">View on GitHub</a>
          </div>
          <p className="fineprint">Free &amp; open source&ensp;·&ensp;macOS 14+&ensp;·&ensp;Apple Silicon</p>
        </div>
        <div className="stage">
          <div className="glowbed" aria-hidden="true" />
          <img className="mb-strip" src={menubarStrip} width={324} height={24} alt="" aria-hidden="true" />
          <img
            className="shot"
            src={panelWindow}
            width={280}
            height={459}
            alt="The Candela menu bar panel controlling three displays, with brightness and volume sliders and per-display resolution and mirroring controls"
          />
        </div>
      </div>
    </section>
  )
}
