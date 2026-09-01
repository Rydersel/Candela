import { sizes, sizesFigure } from '../content/copy'
import { useReveal } from '../useReveal'
import { ProofList } from './ProofList'
import './DeepSections.css'

// The measured figure leads, followed by two short receipts. The visual keeps
// five useful examples from the Dell's larger measured mode set.
export function SectionSizes() {
  const head = useReveal<HTMLDivElement>()
  const figure = useReveal<HTMLElement>()
  const maxExampleWidth = Math.max(
    ...sizesFigure.examples.map((size) => Number.parseInt(size, 10)),
  )

  return (
    <section id="sizes" className="deep sizes">
      <div className="sizes-inner">
        <div className="deep-head reveal" ref={head}>
          <div className="deep-station"><span className="deep-station-pulse" /></div>
          <h2 className="deep-h2">{sizes.h2}</h2>
          <p className="deep-lead">{sizes.lead}</p>
        </div>
        <div className="sizes-stage">
          <figure
            className="sizes-figure reveal"
            ref={figure}
            aria-labelledby="sizes-figure-caption"
          >
            <div className="sizes-reveal">
              <div className="sizes-summary">
                <span className="sizes-summary-count">{sizesFigure.sizeCount}</span>
                <p className="sizes-summary-label">{sizesFigure.hiddenNote}</p>
                <p className="sizes-summary-stat">{sizesFigure.stat}</p>
              </div>
              <div className="sizes-scale">
                {/* role restated because the global list-style reset drops
                    implicit list semantics in Safari/VoiceOver. */}
                <ul
                  className="sizes-hidden-list"
                  aria-label={sizesFigure.hiddenListLabel}
                  role="list"
                >
                  {sizesFigure.examples.map((size) => {
                    const width = Number.parseInt(size, 10)

                    return (
                      <li className="sizes-hidden-item" key={size}>
                        <span className="sizes-hidden-size">{size}</span>
                        <span
                          className="sizes-hidden-rule"
                          style={{ width: `${(width / maxExampleWidth) * 100}%` }}
                          aria-hidden="true"
                        />
                      </li>
                    )
                  })}
                </ul>
                <p className="sizes-scale-foot">{sizesFigure.foot}</p>
              </div>
            </div>
            <figcaption className="sizes-caption" id="sizes-figure-caption">
              {sizesFigure.caption}
            </figcaption>
          </figure>
          <ProofList items={sizes.proofs} className="sizes-proof-list" />
        </div>
      </div>
    </section>
  )
}
