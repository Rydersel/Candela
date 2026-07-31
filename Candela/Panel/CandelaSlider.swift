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

  private let height: CGFloat = 30
  private let strokeColor = Color.gray.opacity(0.5)
  /// Wide enough for "100%" at 11 pt with monospaced digits, so the capsule
  /// never resizes as the number changes width.
  private let readoutWidth: CGFloat = 34

  private var stops: [Double] { snapsToZero ? SliderSnap.stops : SliderSnap.stopsWithoutZero }

  var body: some View {
    HStack(spacing: 8) {
      track
        .frame(height: height)
      if showsPercent {
        Text(SliderSnap.percentText(value))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: readoutWidth, alignment: .trailing)
          // The row is one accessibility element and already publishes this
          // number as its value — reading it twice is noise.
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(SliderSnap.percentText(value))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: value = SliderSnap.snapped(value + 0.05, enabled: snapsToStops, stops: stops)
      case .decrement: value = SliderSnap.snapped(value - 0.05, enabled: snapsToStops, stops: stops)
      @unknown default: break
      }
    }
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
          .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        Circle()
          .fill(.white)
          .shadow(color: .black.opacity(0.18), radius: 2)
          .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1))
          .frame(width: height, height: height)
          .offset(x: fillWidth - height)
        Capsule()
          .strokeBorder(strokeColor, lineWidth: 1)
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.black.opacity(0.6))
          .frame(width: height, height: height)
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
