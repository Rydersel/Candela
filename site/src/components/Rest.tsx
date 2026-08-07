import { useReveal } from '../useReveal.ts'

const ITEMS = [
  'Contrast control',
  'HDR toggle',
  'Brightness & volume keys that follow your pointer',
  'Per-display mute',
  'Presets & profiles with hotkeys',
  'Command-line interface',
  'Shortcuts actions',
  'URL scheme',
  'Color adjustments',
  'KVM input switching',
  'Display power over DDC',
  'Picture-in-picture',
  'Soft disconnect',
  'Diagnostics view',
  'Launch at login',
  'Safe Mode',
]

export default function Rest() {
  const ref = useReveal<HTMLElement>()
  return (
    <section id="everything" className="wrap reveal" ref={ref}>
      <h2>And the rest</h2>
      <ul className="rest">
        {ITEMS.map((item) => (
          <li key={item}>{item}</li>
        ))}
      </ul>
    </section>
  )
}
