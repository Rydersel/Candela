import SwiftUI

/// The flow's own success mark: a ring that traces itself in, then the
/// check stroke drawing through it. Same flat-glow language as
/// `DisplayGlyph`; no assets. Reduce Motion shows it complete.
struct AnimatedCheckmark: View {
  var accent: Color

  @State private var ring: CGFloat = 0
  @State private var check: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle()
        .trim(from: 0, to: ring)
        .stroke(
          LinearGradient(
            colors: [accent, accent.opacity(0.5)],
            startPoint: .topLeading, endPoint: .bottomTrailing
          ),
          style: StrokeStyle(lineWidth: 5, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
      CheckStroke()
        .trim(from: 0, to: check)
        .stroke(
          Color.white,
          style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
        )
    }
    .shadow(color: accent.opacity(0.45), radius: 12)
    .onAppear {
      guard !reduceMotion else {
        ring = 1
        check = 1
        return
      }
      withAnimation(.easeOut(duration: 0.55).delay(0.1)) { ring = 1 }
      withAnimation(.easeOut(duration: 0.35).delay(0.62)) { check = 1 }
    }
    .accessibilityHidden(true)
  }
}

private struct CheckStroke: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + 0.28 * rect.width, y: rect.minY + 0.54 * rect.height))
    path.addLine(to: CGPoint(x: rect.minX + 0.44 * rect.width, y: rect.minY + 0.70 * rect.height))
    path.addLine(to: CGPoint(x: rect.minX + 0.73 * rect.width, y: rect.minY + 0.38 * rect.height))
    return path
  }
}
