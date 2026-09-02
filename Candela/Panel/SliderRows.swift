import CandelaKit
import SwiftUI

// The panel's slider rows, so `snapsToZero` is derived in one place. Build
// sliders through these, never a bare `CandelaSlider`: a hand-passed
// `snapsToZero` lets a muting row snap to 0 and hardware-mute over VCP 0x8D.

/// `setBrightness` is synchronous and coalesces hardware writes, so drag
/// streams are safe to feed straight into it.
struct DisplaySliderRow: View {
  let controller: BrightnessController
  let displayName: String
  let snapsToStops: Bool
  let showsPercent: Bool
  /// Overrides the default "<name> brightness". The hero passes its safety
  /// sentence here, since a11y contract 3 puts it in the control's label.
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

/// Writes the dragged value to every participant. `setBrightness` coalesces per
/// display, so the fan-out costs N coalesced streams, not N times the bus traffic.
struct CombinedSliderRow: View {
  let participants: [AppModel.DisplayState]
  let snapsToStops: Bool
  let showsPercent: Bool

  var value: Double {
    CombinedBrightness.mean(participants.map(\.controller.brightness))
  }

  func setValue(_ value: Double) {
    for state in participants { state.controller.setBrightness(value) }
  }

  var body: some View {
    CandelaSlider(
      value: Binding(get: { value }, set: { setValue($0) }),
      accessibilityLabel: "All displays brightness",
      snapsToStops: snapsToStops,
      showsPercent: showsPercent
    )
  }
}

/// Volume/contrast row, on the same capsule slider as brightness.
///
/// Muted volume renders as 0 with a slashed speaker: `isMuted` and a real 0 are
/// distinct states and only the icon separates them. The stored value survives
/// a mute, so dragging up from 0 unmutes and lands on the dragged value.
struct ValueSliderRow: View {
  let controller: DDCValueController
  let systemImage: String
  let accessibilityLabel: String
  let snapsToStops: Bool
  let showsPercent: Bool
  /// Substituted while muted; nil for commands that never mute (contrast).
  var mutedSystemImage: String?

  /// A muted glyph is the definition of "0 means mute" here: contrast has none
  /// and never mutes.
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
      // Never let snapping pull a volume drag onto 0, which the engine
      // treats as a hardware mute (VCP 0x8D). Contrast keeps the 0 stop.
      snapsToZero: !mutesAtZero,
      showsPercent: showsPercent
    )
  }
}

extension View {
  /// Reveals a greyed panel control's reason on hover, drawn by us.
  ///
  /// The panel cannot use a tooltip [MEASURED 2026-08-11]: nothing inside its
  /// `NSMenu` tracking session delivers one, not SwiftUI's `.help`, not
  /// `NSView.toolTip`, and not on an enabled control either. `.onHover` does
  /// fire, including from an overlay applied after the `.disabled` it sits on.
  ///
  /// The caption's height is reserved whenever a reason exists and only the text
  /// fades; letting it appear would re-lay-out every row below as the pointer
  /// crossed a dead control. It stays readable to VoiceOver at zero opacity,
  /// since a keyboard user has no other route to the reason.
  ///
  /// `staysLive` is for a row that carries a reason without being greyed. The
  /// overlay the greyed case uses would swallow that row's drags.
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
            // Applied after the caller's `.disabled`, so it still hit-tests.
            // Swallowing hover is free here: the control underneath is inert.
            Color.clear.contentShape(Rectangle()).onHover { hovering = $0 }
          }
        }
      if let reason {
        Text(verbatim: reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .opacity(hovering ? 1 : 0)
          // Outside the `Motion` vocabulary on purpose: that set covers state a
          // person changed. 0.12 s because the pointer can cross several
          // controls in a second and anything slower trails behind it.
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovering)
      }
    }
  }
}
