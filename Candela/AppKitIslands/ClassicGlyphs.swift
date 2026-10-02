import AppKit

/// The line-art glyphs the classic box draws. macOS still ships the originals as
/// PDFs in its own on-screen-display helper; they are loaded when present and
/// SF Symbols stand in when a release drops them, so the style degrades to a
/// near glyph rather than to nothing.
@MainActor
enum ClassicGlyphs {
  private static let resources = "/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/"
  private static var cache: [String: NSImage] = [:]

  static func image(for kind: HUDType) -> NSImage {
    let name = fileName(for: kind)
    if let cached = cache[name] { return cached }
    let image = (name.isEmpty ? nil : NSImage(contentsOfFile: resources + name)) ?? fallbackImage(for: kind) ?? NSImage()
    image.isTemplate = true
    cache[name] = image
    return image
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
    let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .thin)
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  }
}
