import { sizes, sizesFigure } from '../content/copy'
import { useReveal } from '../useReveal'
import './DeepSections.css'

// The prose beside a measured figure: the probe's curated size list for the
// rig's ultrawide, with the five macOS-hidden sizes carrying the page's lit
// dot. A designed table of real data, deliberately not a mock screenshot.
export function SectionSizes() {
  const head = useReveal<HTMLDivElement>()
  const figure = useReveal<HTMLElement>()

  return (
    <section id="sizes" className="deep sizes">
      <div className="sizes-inner">
        <div className="deep-head reveal" ref={head}>
          <div className="deep-station"><span className="deep-station-pulse" /></div>
          <h2 className="deep-h2">{sizes.h2}</h2>
          <p className="deep-lead">{sizes.lead}</p>
        </div>
        <div className="sizes-grid">
          <div className="deep-body">
            {sizes.body.map((paragraph) => (
              <p key={paragraph}>{paragraph}</p>
            ))}
          </div>
          <figure className="sizes-figure reveal" ref={figure}>
            <div className="sizes-ladder">
              <div className="sizes-ladder-head">
                <span className="sizes-ladder-panel">{sizesFigure.panel}</span>
                <span className="sizes-ladder-stat">{sizesFigure.stat}</span>
              </div>
              {/* role restated because the global list-style reset drops
                  implicit list semantics in Safari/VoiceOver. */}
              <ul className="sizes-rows" role="list">
                {sizesFigure.rows.map((row) => (
                  <li
                    className={row.hidden ? 'sizes-row sizes-row-hidden' : 'sizes-row'}
                    key={row.size}
                  >
                    <span className="sizes-row-size">{row.size}</span>
                    {row.hidden && (
                      <span className="sizes-row-tag">{sizesFigure.hiddenNote}</span>
                    )}
                  </li>
                ))}
              </ul>
              <p className="sizes-ladder-foot">{sizesFigure.foot}</p>
            </div>
            <figcaption className="sizes-caption">{sizesFigure.caption}</figcaption>
          </figure>
        </div>
      </div>
    </section>
  )
}
