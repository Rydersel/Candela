import AppKit
import Testing

@Suite("Classic glyphs")
struct ClassicGlyphsTests {
  /// Every kind yields a template image, from the system's PDFs when present and
  /// from SF Symbols otherwise, so the style never draws an empty box.
  @MainActor @Test func everyKindHasATemplateGlyph() {
    for kind in [HUDType.brightness, .volume, .volumeMuted, .contrast] {
      let image = ClassicGlyphs.glyph(for: kind).image
      #expect(image.isTemplate, "\(kind)")
      #expect(image.size.width > 0, "\(kind)")
    }
  }

  @MainActor @Test func theFallbackIsAlwaysAvailable() {
    for kind in [HUDType.brightness, .volume, .volumeMuted, .contrast] {
      #expect(ClassicGlyphs.fallbackImage(for: kind) != nil, "\(kind)")
    }
  }

  /// The renderer lays the two sources out differently, so the report has to
  /// be right: contrast has no system PDF and must come back as a symbol.
  @MainActor @Test func theGlyphReportsItsSource() {
    #expect(ClassicGlyphs.glyph(for: .contrast).source == .symbol)
    let pdf = "/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/Brightness.pdf"
    if FileManager.default.fileExists(atPath: pdf) {
      #expect(ClassicGlyphs.glyph(for: .brightness).source == .systemPDF)
    }
  }
}
