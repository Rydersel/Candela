import { setup } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { ProofList } from './ProofList'
import './DeepSections.css'

// The guided-setup walkthrough beside the promise it demonstrates: Candela
// learns the setup it landed in and says what it found.
export function SectionSetup() {
  return (
    <section id="setup" className="deep setup">
      <div className="setup-inner">
        <div className="deep-head">
          <div className="deep-station" />
          <h2 className="deep-h2">{setup.h2}</h2>
          <p className="deep-lead">{setup.lead}</p>
        </div>
        <div className="setup-grid">
          <div className="setup-media">
            <MediaFrame asset={assets.setupFlow} className="setup-frame" />
          </div>
          <ProofList items={setup.proofs} />
        </div>
      </div>
    </section>
  )
}
