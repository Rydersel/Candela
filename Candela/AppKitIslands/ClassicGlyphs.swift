import AppKit
import CandelaKit

/// The line-art glyphs the classic box draws. macOS still ships the originals as
/// PDFs in its own on-screen-display helper; they are loaded when present and
/// SF Symbols stand in when a release drops them, so the style degrades to a
/// near glyph rather than to nothing.
@MainActor
enum ClassicGlyphs {
  /// The two are laid out differently: a PDF fills the box's glyph page, whose
  /// drawing carries its own margin, while a symbol has almost none.
  enum Source: Equatable {
    case systemPDF
    case symbol
  }

  struct Glyph {
    let image: NSImage
    let source: Source
  }

  private static let resources = "/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/"
  private static var cache: [HUDType: Glyph] = [:]

  static func glyph(for kind: HUDType) -> Glyph {
    if let cached = cache[kind] { return cached }
    let name = fileName(for: kind)
    let glyph: Glyph = if !name.isEmpty, let pdf = NSImage(contentsOfFile: resources + name) {
      Glyph(image: pdf, source: .systemPDF)
    } else {
      Glyph(image: fallbackImage(for: kind) ?? NSImage(), source: .symbol)
    }
    glyph.image.isTemplate = true
    cache[kind] = glyph
    return glyph
  }

  /// Contrast has no PDF; it always uses its symbol.
  private static func fileName(for kind: HUDType) -> String {
    switch kind {
    case .brightness: "Brightness.pdf"
    case .volume: "Volume.pdf"
    case .volumeMuted: "Mute.pdf"
    case .contrast: ""
    }
  }

  static func fallbackImage(for kind: HUDType) -> NSImage? {
    let symbol = switch kind {
    case .brightness: "sun.max"
    case .volume: "speaker.wave.3"
    case .volumeMuted: "speaker.slash"
    case .contrast: "circle.lefthalf.filled"
    }
    let config = NSImage.SymbolConfiguration(pointSize: ClassicBox.fallbackGlyphPointSize, weight: .thin)
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  }
}
