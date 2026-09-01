import { controls } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { ProofList } from './ProofList'
import './DeepSections.css'

// The first feature section: centered head over the panel walkthrough at
// full content width (the recording carries its own zooms, so it gets the
// stage, not a column), with three labeled receipts below it.
export function SectionControls() {
  return (
    <section id="controls" className="deep controls">
      <div className="controls-inner">
        <div className="deep-head deep-head-center">
          <div className="deep-station" />
          <h2 className="deep-h2">{controls.h2}</h2>
          <p className="deep-lead">{controls.lead}</p>
        </div>
        <div className="controls-stage">
          <MediaFrame asset={assets.panelFlow} className="controls-flow" />
        </div>
        <ProofList items={controls.proofs} className="controls-proof-list" />
      </div>
    </section>
  )
}
