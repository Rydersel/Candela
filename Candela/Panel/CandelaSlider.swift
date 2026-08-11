import AppKit
import CandelaKit
import SwiftUI

/// Control-Center-style capsule slider: white fill from the leading edge, a
/// circular knob at the fill boundary, and a leading SF Symbol dimmed against
/// the fill. Drag anywhere on the capsule to set the value.
///
/// The white fill is deliberate in both appearances — Control Center's slider
/// fill is white in light and dark mode — while the track, stroke, readout and
/// surrounding chrome use adaptive styles.
///
/// IMPORTANT: the binding setter is invoked synchronously from the drag
/// gesture — no Task hops — so hardware writes stay live during a drag.
/// `SliderSnap.snapped` is pure and runs inline; it does not break that.
struct CandelaSlider: View {
  @Binding var value: Double  // 0...1
  var systemImage: String = "sun.max.fill"
  var accessibilityLabel: String = "Brightness"
  /// Quarter-stop snapping while dragging (app-level `enableSliderSnap`).
  var snapsToStops: Bool = false
  /// Whether `0` is one of the snap stops. FALSE on volume rows (D29): the
  /// engine reads volume 0 as a mute event and may write VCP 0x8D = 1, so a
  /// 3-point capture window on 0 would let a cosmetic pref hardware-mute the
  /// display. Brightness and contrast have no such meaning for 0, and keep it.
  var snapsToZero: Bool = true
  /// Trailing whole-percent readout (app-level `enableSliderPercent`).
  var showsPercent: Bool = false
  /// Lower bound for the KEYBOARD and VoiceOver routes only — a drag can still
  /// reach 0. `nil` (the panel) means no floor, so nothing about the panel's
  /// existing adjustment behaviour changes.
  var keyboardFloor: Double?

  @FocusState private var focused: Bool

  /// `.disabled(_:)` only blocks the gesture. This control draws every pixel
  /// itself, so nothing about it changed appearance and a dead slider still
  /// looked live — you could only discover it by trying to drag it. AppKit
  /// de-emphasises an unavailable control rather than merely inhibiting it
  /// (`disabledControlTextColor` is the text-side equivalent), so we do both.
  @Environment(\.isEnabled) private var isEnabled

  private let height: CGFloat = 30
  private let strokeColor = Color.gray.opacity(0.5)
  /// Wide enough for "100%" with monospaced digits, so the capsule never
  /// resizes as the number changes width — and it scales with the readout's
  /// text style, so a larger accessibility size widens the column instead of
  /// truncating the number.
  @ScaledMetric(relativeTo: .caption2) private var readoutWidth: CGFloat = 34

  /// Applied to the whole control rather than per layer. The fill, knob and
  /// glyph are tuned against each other — a black glyph sitting on a white
  /// fill — so restyling them individually would break that relationship in
  /// one appearance or the other. Uniform de-emphasis keeps the internal
  /// contrast intact while the control reads as unavailable in both.
  private var disabledDimming: Double { isEnabled ? 1 : 0.4 }

  /// Shadows go to zero when disabled rather than dimming with everything
  /// else: a shadow reads as "raised, therefore pressable" at any opacity,
  /// which is the opposite of what an unavailable control should say.
  private var shadowOpacity: Double { isEnabled ? 1 : 0 }

  private var stops: [Double] { snapsToZero ? SliderSnap.stops : SliderSnap.stopsWithoutZero }

  var body: some View {
    HStack(spacing: 8) {
      track
        .frame(height: height)
      if showsPercent {
        Text(SliderSnap.percentText(value))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: readoutWidth, alignment: .trailing)
          // The row is one accessibility element and already publishes this
          // number as its value — reading it twice is noise.
          .accessibilityHidden(true)
      }
    }
    .opacity(disabledDimming)
    // An unavailable control must not take focus and swallow the arrow keys:
    // `.disabled` inhibits the gesture, and this inhibits the keyboard route.
    .focusable(isEnabled)
    .focused($focused)
    // The track draws the ring itself. AppKit's would enclose the whole row —
    // capsule plus percentage readout — pointing at a region that is not the
    // control.
    .focusEffectDisabled()
    // `.repeat` included so holding an arrow ramps the value, which is what a
    // 5%-per-press step needs to be usable across the whole range.
    .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
      let step = press.modifiers.contains(.option) ? 0.01 : Self.step
      adjust(by: press.key == .leftArrow ? -step : step)
      return .handled
    }
    // Every pixel here is ours, so the platform has nothing to infer a role
    // from: a label, a value and an adjustable action on a custom element still
    // reached the accessibility layer as AXUnknown with no value at all (#138),
    // because SwiftUI has no "this is a slider" trait to attach. Standing in a
    // real `Slider` is the supported route to a slider role, and it replaces
    // only the accessibility tree: nothing about the drawing, the drag gesture
    // or the arrow keys goes through it.
    //
    // The percent readout beside the track keeps its own `.accessibilityHidden`
    // for the same reason as before, and the caption `panelHoverReason` draws
    // below the row is a sibling of this view, so it stays a separate element.
    .accessibilityRepresentation {
      // The label goes on twice on purpose: `.accessibilityLabel` is the one
      // that wins, and the label view underneath it means the control is still
      // named if a future SwiftUI drops the modifier across the representation
      // boundary. Measured: naming it both ways yields ONE slider element with
      // no extra children, so the redundancy costs nothing.
      Slider(value: adjustmentProxy, in: 0...1, step: Self.step) {
        Text(verbatim: accessibilityLabel)
      }
      .accessibilityLabel(accessibilityLabel)
      // Our own text, so a screen reader speaks the number the panel draws.
      // It lands in AXValueDescription, which is what VoiceOver announces;
      // AXValue stays the raw 0...1 fraction, which is what a script reads.
      .accessibilityValue(SliderSnap.percentText(value))
      // Belt and braces: an unavailable control must announce as unavailable
      // even if the environment stops at the representation's boundary.
      .disabled(!isEnabled)
    }
  }

  /// VoiceOver step, and the arrow keys' unmodified step. One constant, because
  /// the two routes moving by different amounts would be a bug nobody sees.
  private static let step: Double = 0.05

  /// The representation sets an absolute value; `adjust(by:)` is the only clamp.
  /// Converting back to a delta here keeps VoiceOver on exactly the arrow keys'
  /// path: the same snapping, the same keyboard floor, the same "Minimum"
  /// announcement, and volume's zero-free stops (D29) rather than a raw write
  /// that could land on 0 and hardware-mute the display.
  private var adjustmentProxy: Binding<Double> {
    Binding(get: { value }, set: { adjust(by: $0 - value) })
  }

  /// THE clamp: the arrow keys and the accessibility representation are both
  /// callers, so a floor cannot be honoured on one route and missed on the
  /// other.
  ///
  /// Snapping is kept for PARITY with the stepping the accessibility route
  /// already does, not as a safety measure. It protects nothing at 0:
  /// with `stopsWithoutZero` the nearest stop to 0 is 0.25, outside
  /// `tolerance`, so `snapped` hands 0 straight back exactly as a bare clamp
  /// would. Dropping it would only change how far one VoiceOver step moves a
  /// snapping slider.
  ///
  /// Order is snap-then-floor: `snapped` clamps to 0…1, then the floor goes on
  /// top, so a stop below the floor cannot pull the value under it.
  private func adjust(by delta: Double) {
    // The floor is clamped to the slider's own range: it raises the lower
    // bound, it can never push a write past 1 for the controllers downstream.
    let floor = min(max(keyboardFloor ?? 0, 0), 1)
    let next = max(floor, SliderSnap.snapped(value + delta, enabled: snapsToStops, stops: stops))
    // Only an explicit floor is worth announcing: at 0 the value itself already
    // says "0%", and announcing on a floor nobody set would change what the
    // panel says today.
    if keyboardFloor != nil, next == floor, value != floor {
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: "Minimum",
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
    }
    value = next
  }

  private var track: some View {
    GeometryReader { geo in
      let width = geo.size.width
      // The knob travels between the two capsule end-caps, so the usable
      // range is width minus one knob diameter (same math as the fork's
      // MCSliderCell bar fill).
      let travel = max(width - height, 1)
      let fillWidth = height + CGFloat(value) * travel
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.quaternary)
        Capsule()
          .fill(.white)
          .frame(width: fillWidth)
          .shadow(color: .black.opacity(0.12 * shadowOpacity), radius: 2, y: 1)
        Circle()
          .fill(.white)
          .shadow(color: .black.opacity(0.18 * shadowOpacity), radius: 2)
          .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1))
          .frame(width: height, height: height)
          .offset(x: fillWidth - height)
        Capsule()
          .strokeBorder(strokeColor, lineWidth: 1)
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.black.opacity(0.6))
          .frame(width: height, height: height)
        // OUTSIDE the capsule (negative padding), where AppKit puts a focus
        // ring — inside, it would sit on the white fill and read as part of the
        // value. It cannot disturb layout: the enclosing `GeometryReader` takes
        // its size from the parent's proposal, not from this ZStack's children.
        // Absent entirely when unfocused, so the panel's pixels are unchanged.
        // Whether a panel slider can take focus at all during NSMenu tracking
        // is UNVERIFIED — nothing here enforces that it cannot.
        if focused {
          Capsule()
            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            .padding(-2)
        }
      }
      // Full-rect hit shape so drags starting in the corner slivers outside
      // the capsule's curve still register.
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            // Map the pointer to the knob center so the knob tracks the
            // pointer exactly across the whole travel range. `snapped` also
            // clamps, in both modes — it replaces the old min/max here.
            let raw = (gesture.location.x - height / 2) / travel
            value = SliderSnap.snapped(raw, enabled: snapsToStops, stops: stops)
          }
      )
    }
  }
}
