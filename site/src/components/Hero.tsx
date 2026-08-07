import appIcon from '../assets/candela-icon.svg'

export default function Hero() {
  return (
    <section id="hero" className="wrap">
      <div className="app-mark" aria-hidden="true">
        <img src={appIcon} width={88} height={88} alt="" />
      </div>
      <h1>
        The display control<br className="h1br" /> macOS forgot to ship.
      </h1>
      <p className="sub">
        Retina-sharp scaling at any resolution, real hardware brightness and volume, virtual
        displays — everything your external monitor should have come with. Free and open source.
      </p>
      <div className="cta">
        <a className="btn btn-primary" href="https://github.com/Rydersel/Candela/releases/latest">Download for macOS</a>
        <a className="btn btn-quiet" href="https://github.com/Rydersel/Candela">View on GitHub</a>
      </div>
      <p className="fineprint">Free &amp; open source&ensp;·&ensp;macOS 14+&ensp;·&ensp;Apple Silicon</p>
    </section>
  )
}
