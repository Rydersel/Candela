import { setup } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { useReveal } from '../useReveal'
import './DeepSections.css'

// The guided-setup walkthrough beside the promise it demonstrates: Candela
// learns the setup it landed in and says what it found.
export function SectionSetup() {
  const head = useReveal<HTMLDivElement>()
  const media = useReveal<HTMLDivElement>()

  return (
    <section id="setup" className="deep setup">
      <div className="setup-inner">
        <div className="deep-head reveal" ref={head}>
          <div className="deep-station"><span className="deep-station-pulse" /></div>
          <h2 className="deep-h2">{setup.h2}</h2>
          <p className="deep-lead">{setup.lead}</p>
        </div>
        <div className="setup-grid">
          <div className="setup-media reveal" ref={media}>
            <MediaFrame asset={assets.setupFlow} className="setup-frame" />
          </div>
          <div className="deep-body">
            {setup.body.map((paragraph) => (
              <p key={paragraph}>{paragraph}</p>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
