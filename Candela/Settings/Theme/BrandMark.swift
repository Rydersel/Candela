import SwiftUI

/// The app icon's C reduced to a tintable vector, so it can take the
/// destination accent. The full icon cannot.
struct BrandMark: View {
  var tint: Color

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      // Stroke weight tuned to sit beside bold rounded text as a letter.
      let line = side * 0.24
      let ring = side - line
      let radius = ring / 2
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      // Aperture matches the app icon's, a quarter of the ring. Any less and
      // the mark reads as an O at wordmark size.
      let dotAngle = Angle.degrees(-49)
      let dotCenter = CGPoint(
        x: center.x + radius * CGFloat(cos(dotAngle.radians)),
        y: center.y + radius * CGFloat(sin(dotAngle.radians)))
      ZStack {
        Circle()
          .trim(from: 0.155, to: 0.865)
          .stroke(
            tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
          .frame(width: ring, height: ring)
          .position(center)
        Circle()
          .fill(Color.white.opacity(0.95))
          .frame(width: side * 0.27, height: side * 0.27)
          .position(dotCenter)
          .shadow(color: tint.opacity(0.9), radius: side * 0.10)
      }
    }
    .accessibilityHidden(true)
  }
}
