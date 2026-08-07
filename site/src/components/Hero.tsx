export default function Hero() {
  return (
    <section id="hero" className="wrap">
      <div className="app-mark" aria-hidden="true">
        <svg viewBox="0 0 64 64" width="72" height="72">
          <rect x="4" y="4" width="56" height="56" rx="14" fill="#232326" stroke="rgba(255,255,255,.1)" />
          <path d="M32 15c5 7 10 11 10 18a10 10 0 1 1-20 0c0-7 5-11 10-18z" fill="none" stroke="#ffb340" strokeWidth="2.5" strokeLinejoin="round" />
          <path d="M32 28c2.5 3.5 4.5 5.5 4.5 8.5a4.5 4.5 0 1 1-9 0c0-3 2-5 4.5-8.5z" fill="#ffb340" />
        </svg>
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
