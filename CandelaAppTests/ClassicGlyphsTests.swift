import AppKit
import Testing

@Suite("Classic glyphs")
struct ClassicGlyphsTests {
  /// Every kind yields a template image, from the system's PDFs when present and
  /// from SF Symbols otherwise, so the style never draws an empty box.
  @MainActor @Test func everyKindHasATemplateGlyph() {
    for kind in [HUDType.brightness, .volume, .volumeMuted, .contrast] {
      let image = ClassicGlyphs.image(for: kind)
      #expect(image.isTemplate, "\(kind)")
      #expect(image.size.width > 0, "\(kind)")
    }
  }

  @MainActor @Test func theFallbackIsAlwaysAvailable() {
    for kind in [HUDType.brightness, .volume, .volumeMuted, .contrast] {
      #expect(ClassicGlyphs.fallbackImage(for: kind) != nil, "\(kind)")
    }
  }
}
