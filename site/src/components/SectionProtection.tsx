import { protection } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { DimDemo } from './DimDemo'
import { ExposureDemo } from './ExposureDemo'
import { ProofList } from './ProofList'
import './DeepSections.css'

// The flagship, protection first: the live local dimming leads with its
// figure, the record follows as the movement underneath it, and the section
// closes on the real measured map, the proof the concepts were drawn from.
export function SectionProtection() {
  return (
    <section id="protection" className="deep protection">
      <div className="protection-head-wrap deep-head deep-head-center">
        <div className="deep-station" />
        <h2 className="deep-h2">{protection.h2}</h2>
        <p className="deep-lead">{protection.lead}</p>
      </div>
      <div className="protection-grid protection-grid-act">
        <div className="protection-media">
          <DimDemo />
        </div>
        <ProofList items={protection.actProofs} />
      </div>
      <div className="protection-grid">
        <div className="protection-pan-wrap">
          <ExposureDemo />
        </div>
        <ProofList items={protection.watchProofs} />
      </div>
      <h3 className="protection-record-title">{protection.recordTitle}</h3>
      <div className="protection-stage">
        <MediaFrame asset={assets.healthFlow} className="protection-map" />
      </div>
    </section>
  )
}
