import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import os

/// Per-cell luminance of a display's wallpaper, for the exposure model's
/// uncovered-area backdrop (EM3).
///
/// App-target island: `NSWorkspace` and ImageIO stay out of Kit, which only
/// ever receives the 240 floats (EM6). Reading the wallpaper needs no
/// permission at all; the file is the user's own setting, not screen content.
///
/// Two approximations, both deliberate:
/// - The image is stretched to the grid rather than aspect-filled the way the
///   desktop draws it. At 24x10 the difference is a fraction of a cell, and
///   the comparison is the instrument that judges whether it matters.
/// - A dynamic (appearance-aware) wallpaper decodes to its first variant.
///   Appearance still keys the cache, so a flip recomputes and the log below
///   records it, which is what the hardware pass observes.
@MainActor
final class WallpaperLuminanceSource {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  /// Small enough to decode in microseconds, large enough that the grid draw
  /// area-averages real structure rather than a handful of pixels.
  private static let thumbnailMaxPixels = 64

  private struct CacheKey: Equatable {
    var url: URL
    var appearanceIsDark: Bool
    var displaySize: CGSize
    var rotation: DisplayRotation
  }

  /// One entry per display, so a scheduled-rotation wallpaper cannot grow the
  /// cache without bound over a multi-week soak.
  private var cache: [CGDirectDisplayID: (key: CacheKey, cells: [Double])] = [:]

  /// Panel-physical wallpaper luminance for `displayID`, or nil when the
  /// display has no resolvable screen or the wallpaper cannot be read. Nil is
  /// the model's cue to fall back to the appearance prior (EM5); a zero grid
  /// would instead assert a black wallpaper that was never observed.
  func panelGrid(
    for displayID: CGDirectDisplayID, appearanceIsDark: Bool,
    through transform: PanelSpaceTransform
  ) -> [Double]? {
    guard let screen = Self.screen(for: displayID),
      let url = NSWorkspace.shared.desktopImageURL(for: screen)
    else {
      Self.reportRecompute(displayID: displayID, readable: false, appearanceIsDark: appearanceIsDark)
      cache.removeValue(forKey: displayID)
      return nil
    }

    let key = CacheKey(
      url: url, appearanceIsDark: appearanceIsDark,
      displaySize: transform.displaySize, rotation: transform.rotation)
    if let cached = cache[displayID], cached.key == key { return cached.cells }

    let cells = Self.computeGrid(url: url, through: transform)
    Self.reportRecompute(
      displayID: displayID, readable: cells != nil, appearanceIsDark: appearanceIsDark)
    if let cells {
      cache[displayID] = (key, cells)
    } else {
      cache.removeValue(forKey: displayID)
    }
    return cells
  }

  private static func computeGrid(url: URL, through transform: PanelSpaceTransform) -> [Double]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
      // EXIF orientation applied at decode, or a rotated photo wallpaper lands
      // in the grid sideways.
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    // The sampler's own orientation rule and EOTF math, on purpose: the model
    // and the measurement must disagree only about content, never about how
    // pixels become luminance.
    let (cols, rows) = LuminanceReduction.requestedSize(
      displayWidth: Int(transform.displaySize.width),
      displayHeight: Int(transform.displaySize.height))
    // macOS fills the display with the wallpaper and crops the overflow;
    // `meanLuminance` stretches. Without this the model reads a squashed
    // wallpaper, worst on a rotated panel where the aspects differ most.
    let filled = LuminanceReduction.cropToFill(
      image, aspect: transform.displaySize.width / transform.displaySize.height)
    guard let grid = LuminanceReduction.meanLuminance(of: filled, cols: cols, rows: rows) else {
      return nil
    }
    return transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
  }

  /// Logged only on recompute, so a stable wallpaper costs one line rather
  /// than one per sample. The Screen Recording preflight is asserted inside
  /// the line itself: the claim this feature exists to prove is that these
  /// inputs stay readable with the grant absent, and a log line that does not
  /// carry the grant state cannot prove it.
  private static func reportRecompute(
    displayID: CGDirectDisplayID, readable: Bool, appearanceIsDark: Bool
  ) {
    log.info("""
    exposure model: wallpaper \(readable ? "readable" : "unreadable", privacy: .public) \
    for display \(displayID, privacy: .public) \
    appearanceDark=\(appearanceIsDark, privacy: .public) \
    screenRecordingPreflight=\(CGPreflightScreenCaptureAccess(), privacy: .public)
    """)
  }

  private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { screen in
      let key = NSDeviceDescriptionKey("NSScreenNumber")
      return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
    }
  }
}
