import CoreGraphics
import SwiftUI
import Testing

/// ImageRenderer can move the footer's SF Symbols down one pixel between the
/// initial capture and later captures. On macOS 26.7 this reproduced in the
/// complete app suite, but not in a cold isolated test. The glyphs' alpha totals
/// were unchanged, and translating the first glyph crop down one pixel made it
/// identical to the next. A large channel delta therefore did not imply a color
/// change. Disabling animations and fixing the icon height did not remove it.
///
/// The framework trigger remains unknown. These comparisons explicitly discard
/// one capture; they do not assert that the first capture is deterministic or
/// establish whether the running menu ever shows this renderer artifact.
@Suite("Panel render determinism") @MainActor
struct PanelRenderDeterminismTests {
  @Test func warmedPanelRendersAgree() throws {
    let view = PanelView().environment(TestFixtures.appModel())
    _ = try render(view)
    let first = try render(view)
    let second = try render(view)
    #expect(try delta(first, second) <= 4)
  }

  /// A deliberate movement must still fail the comparison. The noise allowance
  /// cannot hide a positional change like the one that prompted this probe.
  @Test func theComparisonDetectsMovedContent() throws {
    let view = PanelView().environment(TestFixtures.appModel())
    _ = try render(view)
    let reference = try render(view)
    let moved = try render(view.offset(y: 1))
    #expect(try delta(reference, moved) >= 64)
  }

  private func render(_ view: some View) throws -> CGImage {
    try #require(ImageRenderer(content: view).cgImage)
  }

  private func delta(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
    try #require(lhs.width == rhs.width && lhs.height == rhs.height)
    let a = try rgba(lhs)
    let b = try rgba(rhs)
    return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
  }

  /// Compare a defined pixel format, excluding provider padding and unspecified
  /// color-space differences between CGImages.
  private func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }
}
