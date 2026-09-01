import { checkup } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { ProofList } from './ProofList'
import './DeepSections.css'

// The finished report is the section's visual: the thing you keep, shown
// whole.
export function SectionCheckup() {
  return (
    <section id="checkup" className="deep checkup">
      <div className="checkup-inner">
        <div className="deep-head">
          <div className="deep-station" />
          <h2 className="deep-h2">{checkup.h2}</h2>
          <p className="deep-lead">{checkup.lead}</p>
        </div>
        <div className="checkup-grid">
          <div className="checkup-media">
            <MediaFrame asset={assets.checkupReport} className="checkup-report" />
          </div>
          <ProofList items={checkup.proofs} />
        </div>
      </div>
    </section>
  )
}
