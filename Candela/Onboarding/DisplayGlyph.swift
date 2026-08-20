import SwiftUI

/// A display drawn as a lit object (OB10): true mounted aspect ratio, glass
/// gradient face, specular edge light, stand and a soft floor reflection.
/// The continuity device of the whole flow; every set piece is built from
/// these, sized by context.
struct DisplayGlyph: View {
  /// Width over height as mounted (the rotated Dell is < 1).
  var aspect: Double
  var accent: Color
  /// 0...1 outline trace for the scan reveal; 1 everywhere else.
  var trace: Double = 1
  /// Face brightness, 0...1. The care demo dims this.
  var lit: Double = 1
  /// Optional overlay rendered inside the face (the care demo's bands, a
  /// size label, a check).
  var faceOverlay: AnyView?
  var showsStand: Bool = true
  var showsReflection: Bool = true

  var body: some View {
    GeometryReader { proxy in
      let bounds = proxy.size
      let standHeight: CGFloat = showsStand ? bounds.height * 0.12 : 0
      let reflectionHeight: CGFloat = showsReflection ? bounds.height * 0.18 : 0
      let faceArea = CGSize(
        width: bounds.width,
        height: max(1, bounds.height - standHeight - reflectionHeight))
      let face = faceSize(in: faceArea)
      VStack(spacing: 0) {
        screen(size: face)
          .frame(width: faceArea.width, height: faceArea.height, alignment: .bottom)
        if showsStand {
          stand(faceWidth: face.width, height: standHeight)
        }
        if showsReflection {
          screen(size: face, isReflection: true)
            .frame(height: reflectionHeight, alignment: .top)
            .clipped()
        }
      }
    }
  }

  private func faceSize(in area: CGSize) -> CGSize {
    let byWidth = CGSize(width: area.width, height: area.width / aspect)
    if byWidth.height <= area.height { return byWidth }
    return CGSize(width: area.height * aspect, height: area.height)
  }

  @ViewBuilder
  private func screen(size: CGSize, isReflection: Bool = false) -> some View {
    let corner = min(size.width, size.height) * 0.045 + 3
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    ZStack {
      shape
        .fill(
          LinearGradient(
            colors: [
              accent.opacity(0.42 * lit + 0.04),
              accent.opacity(0.10 * lit + 0.02),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
          )
        )
      // Specular pass across the glass.
      shape
        .fill(
          LinearGradient(
            colors: [.white.opacity(0.16 * lit), .clear, .white.opacity(0.03 * lit)],
            startPoint: .top, endPoint: .bottom
          )
        )
      if let faceOverlay, !isReflection {
        faceOverlay
          .clipShape(shape)
      }
      shape
        .trim(from: 0, to: trace)
        .stroke(
          LinearGradient(
            colors: [.white.opacity(0.75), accent.opacity(0.55), .white.opacity(0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
          ),
          lineWidth: 1.5
        )
        .shadow(color: accent.opacity(0.5), radius: 6)
    }
    .frame(width: size.width, height: size.height)
    .scaleEffect(y: isReflection ? -1 : 1)
    .opacity(isReflection ? 0.14 : 1)
    .mask(
      // Reflections fade with distance from the stand.
      Group {
        if isReflection {
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)
        } else {
          Color.black
        }
      }
    )
  }

  private func stand(faceWidth: CGFloat, height: CGFloat) -> some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(
          LinearGradient(
            colors: [.white.opacity(0.22), .white.opacity(0.06)],
            startPoint: .top, endPoint: .bottom
          )
        )
        .frame(width: max(6, faceWidth * 0.07), height: height * 0.62)
      Capsule()
        .fill(Color.white.opacity(0.18))
        .frame(width: max(20, faceWidth * 0.26), height: max(2.5, height * 0.14))
    }
    .frame(height: height)
  }
}
