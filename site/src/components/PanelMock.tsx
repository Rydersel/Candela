import { useReveal } from '../useReveal.ts'
import panelShot from '../assets/widget-cropped-in.png'

export default function PanelMock() {
  const ref = useReveal<HTMLElement>()
  return (
    <section id="panel" className="wrap reveal" ref={ref}>
      <div className="stage">
        <div className="glowbed" aria-hidden="true" />
        <img
          className="shot"
          src={panelShot}
          width={281}
          height={464}
          alt="The Candela menu bar panel controlling three displays, with brightness and volume sliders and per-display resolution and mirroring controls"
        />
      </div>
    </section>
  )
}
