import SwiftUI

/// Control-Center-style capsule slider: full-width white fill from the left,
/// leading SF Symbol, drag anywhere on the capsule to set the value.
struct CandelaSlider: View {
  @Binding var value: Double  // 0...1
  var systemImage: String = "sun.max.fill"

  private let height: CGFloat = 32

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(.white)
          .frame(width: max(height, value * width))
          .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.black.opacity(0.6))
          .frame(width: height, height: height)
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            value = min(max(gesture.location.x / width, 0), 1)
          }
      )
    }
    .frame(height: height)
  }
}
