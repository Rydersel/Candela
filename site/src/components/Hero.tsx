import candelaC from '../assets/candela-c.svg'

export default function Hero() {
  return (
    <section id="hero" className="wrap">
      <img src={candelaC} alt="" aria-hidden="true" className="hero-bgc" />
      <h1>
        The display control<br className="h1br" /> macOS forgot to ship.
      </h1>
      <p className="sub">
        Candela gives your external monitor everything it should have come with — Retina-sharp
        scaling at any resolution, real hardware brightness and volume, virtual displays, and more.
        Free and open source.
      </p>
      <div className="cta">
        <a className="btn btn-primary" href="https://github.com/Rydersel/Candela/releases/latest">Download for macOS</a>
        <a className="btn btn-quiet" href="https://github.com/Rydersel/Candela">View on GitHub</a>
      </div>
      <p className="fineprint">Free &amp; open source&ensp;·&ensp;macOS 14+&ensp;·&ensp;Apple Silicon</p>
    </section>
  )
}
