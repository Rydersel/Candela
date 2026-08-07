import CandelaKit
import SwiftUI

// The panel's slider rows, promoted out of `PanelView` (T12 review, D29 rule 4)
// so that `snapsToZero` is DERIVED in one place. Every surface that shows a
// display's sliders — the menu bar and the settings hero — constructs these,
// never a bare `CandelaSlider` bound to a controller: a third construction site
// passing `snapsToZero` by hand is exactly how a muting row would one day snap
// to 0 and hardware-mute the display over VCP 0x8D.

/// Bridges the controller (source of truth) to the slider's binding.
/// setBrightness is synchronous and coalesces hardware writes, so drag
/// streams are safe to feed directly.
struct DisplaySliderRow: View {
  let controller: BrightnessController
  let displayName: String
  let snapsToStops: Bool
  let showsPercent: Bool
  /// Overrides the default "<name> brightness". The hero passes its safety
  /// sentence through here (a11y contract 3: the sentence travels in the
  /// control's LABEL); the panel passes nothing.
  var accessibilityLabel: String?
  /// Keyboard/VoiceOver floor above black-screen (a11y contract 7). nil (the
  /// panel) leaves adjustment behaviour unchanged; a drag can always reach 0.
  var keyboardFloor: Double?

  var body: some View {
    CandelaSlider(
      value: Binding(
        get: { controller.brightness },
        set: { controller.setBrightness($0) }
      ),
      accessibilityLabel: accessibilityLabel ?? "\(displayName) brightness",
      snapsToStops: snapsToStops,
      showsPercent: showsPercent,
      keyboardFloor: keyboardFloor
    )
  }
}

/// Volume/contrast row: the same capsule slider as brightness, one visual
/// language for every value in the section.
///
/// Muted volume renders as 0 with a slashed speaker — `isMuted` and a genuine
/// value of 0 are distinct states (T10 handoff) and the icon is what tells
/// them apart, since the knob sits at the leading edge either way. The stored
/// value survives being muted: dragging up from 0 unmutes and lands on the
/// dragged value through the controller's mute-companion logic.
struct ValueSliderRow: View {
  let controller: DDCValueController
  let systemImage: String
  let accessibilityLabel: String
  let snapsToStops: Bool
  let showsPercent: Bool
  /// Substituted while muted; nil for commands that never mute (contrast).
  var mutedSystemImage: String?

  /// Volume is the command whose 0 means "mute". Having a muted glyph IS the
  /// definition of that here — contrast has none and never mutes.
  private var mutesAtZero: Bool { mutedSystemImage != nil }
  private var isMuted: Bool { controller.isMuted && mutesAtZero }

  var body: some View {
    CandelaSlider(
      value: Binding(
        get: { isMuted ? 0 : controller.value },
        set: { controller.setValue($0) }
      ),
      systemImage: isMuted ? (mutedSystemImage ?? systemImage) : systemImage,
      accessibilityLabel: isMuted ? "\(accessibilityLabel), muted" : accessibilityLabel,
      snapsToStops: snapsToStops,
      // D29: never let snapping pull a volume drag onto 0, which the engine
      // treats as a hardware mute (VCP 0x8D). Contrast keeps the 0 stop.
      snapsToZero: !mutesAtZero,
      showsPercent: showsPercent
    )
  }
}
