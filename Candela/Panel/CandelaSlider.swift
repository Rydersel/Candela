import SwiftUI

/// Control-Center-style capsule slider: white fill from the leading edge, a
/// circular knob at the fill boundary, and a leading SF Symbol dimmed against
/// the fill. Drag anywhere on the capsule to set the value.
///
/// The white fill is deliberate in both appearances — Control Center's slider
/// fill is white in light and dark mode — while the track, stroke, and
/// surrounding chrome use adaptive styles.
///
/// IMPORTANT: the binding setter is invoked synchronously from the drag
/// gesture — no Task hops — so hardware writes stay live during a drag.
struct CandelaSlider: View {
  @Binding var value: Double  // 0...1
  var systemImage: String = "sun.max.fill"
  var accessibilityLabel: String = "Brightness"

  private let height: CGFloat = 30
  private let strokeColor = Color.gray.opacity(0.5)

  var body: some View {
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
            // pointer exactly across the whole travel range.
            let raw = (gesture.location.x - height / 2) / travel
            value = min(max(raw, 0), 1)
          }
      )
    }
    .frame(height: height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue("\(Int((value * 100).rounded()))%")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: value = min(value + 0.05, 1)
      case .decrement: value = max(value - 0.05, 0)
      @unknown default: break
      }
    }
  }
}
