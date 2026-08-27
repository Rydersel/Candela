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

extension View {
  /// Reveals a greyed panel control's reason on hover, drawn by us.
  ///
  /// The panel cannot use a tooltip. [MEASURED 2026-08-11, #130] Nothing inside
  /// the `NSMenu` tracking session the panel runs in delivers one: not SwiftUI's
  /// `.help`, not `NSView.toolTip`, and not on an ENABLED control either (the
  /// MAG's HDR button, whose `.help` has never once appeared). So this is not a
  /// workaround for `.disabled`; a tooltip is simply not available here.
  ///
  /// `.onHover` DOES fire in the panel, including from an overlay applied after
  /// the `.disabled` it sits on, which is what makes a self-drawn caption
  /// possible where the system one is not.
  ///
  /// The line's height is RESERVED whenever a reason exists, and only the text
  /// fades. Letting it appear would re-lay-out every row below it in that
  /// display's section as the pointer crossed a control nobody can use, and the
  /// panel already moves enough when a disclosure opens. Nothing is reserved for
  /// a live control, so a panel with nothing greyed is pixel-identical to before.
  ///
  /// Left readable to VoiceOver at zero opacity on purpose: hover is a pointer
  /// affordance, and the reason is the one thing a keyboard user cannot
  /// otherwise get from this surface.
  ///
  /// `staysLive` is for a row that carries a reason WITHOUT being greyed (the
  /// degraded brightness slider). The overlay the greyed case uses would
  /// swallow that row's drags, so a live row is watched through the content.
  func panelHoverReason(_ reason: String?, staysLive: Bool = false) -> some View {
    modifier(PanelHoverReason(reason: reason, staysLive: staysLive))
  }
}

private struct PanelHoverReason: ViewModifier {
  let reason: String?
  let staysLive: Bool
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      content
        .onHover { isHovering in
          // Gated on the write rather than the tracking, so a live row with
          // nothing to say behaves exactly as it did before this modifier.
          guard staysLive, reason != nil else { return }
          hovering = isHovering
        }
        .overlay {
          if reason != nil, !staysLive {
            // Applied after the caller's `.disabled`, so it is outside that
            // subtree and still hit-tests. Swallowing the hover costs nothing:
            // the control underneath is inert whenever a reason exists. A live
            // row takes the branch above, where swallowing would cost the drag.
            Color.clear.contentShape(Rectangle()).onHover { hovering = $0 }
          }
        }
      if let reason {
        Text(verbatim: reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .opacity(hovering ? 1 : 0)
          // A hover fade, deliberately outside the `Motion` vocabulary: that set
          // covers state a person changed, and this is per-surface feel on a
          // pointer affordance, guarded here on its own. 0.12 s is kept because
          // the pointer can cross several controls in a second and anything
          // slower trails behind it. nil under Reduce Motion, so the reason
          // appears at once instead of fading.
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
      }
    }
  }
}
