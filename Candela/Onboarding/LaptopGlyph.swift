import SwiftUI

/// The built-in display drawn as what it is: a laptop, screen over a deck that
/// is wider than the glass, the way the machine actually closes.
///
/// Beside `DisplayGlyph` and taking the same parameters, because the built-in
/// is depicted in both surfaces the glyphs serve: the guided setup flow and the
/// settings window (SV9).
struct LaptopGlyph: View {
  /// Width over height as mounted.
  var aspect: Double
  var accent: Color
  /// Face brightness, 0...1.
  var lit: Double = 1
  var faceOverlay: AnyView?

  var body: some View {
    GeometryReader { proxy in
      let bounds = proxy.size
      // DisplayTile inverts these shares to land its glass on the arrangement
      // rect; changing them moves the built-in tile off its neighbours.
      let deckHeight = max(5, bounds.height * 0.075)
      let faceHeight = bounds.height - deckHeight
      let faceWidth = min(bounds.width * 0.86, CGFloat(aspect) * faceHeight)
      VStack(spacing: 0) {
        DisplayGlyph(
          aspect: aspect, accent: accent, lit: lit, faceOverlay: faceOverlay,
          showsStand: false, showsReflection: false
        )
        .frame(width: faceWidth, height: faceHeight, alignment: .bottom)
        deck(width: min(bounds.width, faceWidth * 1.18), height: deckHeight)
      }
      .frame(width: bounds.width, height: bounds.height, alignment: .bottom)
    }
  }

  private func deck(width: CGFloat, height: CGFloat) -> some View {
    ZStack {
      UnevenRoundedRectangle(
        topLeadingRadius: 2, bottomLeadingRadius: height * 0.55,
        bottomTrailingRadius: height * 0.55, topTrailingRadius: 2,
        style: .continuous
      )
      .fill(
        LinearGradient(
          colors: [.white.opacity(0.26), .white.opacity(0.09)],
          startPoint: .top, endPoint: .bottom)
      )
      // Thumb notch.
      Capsule()
        .fill(Color.black.opacity(0.35))
        .frame(width: width * 0.16, height: max(2, height * 0.3))
        .offset(y: -height * 0.2)
    }
    .frame(width: width, height: height)
  }
}
