import { controls } from '../content/copy'
import { assets } from '../content/assets'
import { MediaFrame } from './MediaFrame'
import { useReveal } from '../useReveal'
import './DeepSections.css'

// The first feature section: centered head over the panel walkthrough at
// full content width (the recording carries its own zooms, so it gets the
// stage, not a column), with the prose reading as a spread below it.
export function SectionControls() {
  const head = useReveal<HTMLDivElement>()
  const stage = useReveal<HTMLDivElement>()

  return (
    <section id="controls" className="deep controls">
      <div className="controls-inner">
        <div className="deep-head deep-head-center reveal" ref={head}>
          <div className="deep-station"><span className="deep-station-pulse" /></div>
          <h2 className="deep-h2">{controls.h2}</h2>
          <p className="deep-lead">{controls.lead}</p>
        </div>
        <div className="controls-stage reveal" ref={stage}>
          <MediaFrame asset={assets.panelFlow} className="controls-flow" />
        </div>
        <div className="controls-body deep-body">
          {controls.body.map((paragraph) => (
            <p key={paragraph}>{paragraph}</p>
          ))}
        </div>
      </div>
    </section>
  )
}
