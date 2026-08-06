import Foundation

@testable import CandelaKit

/// Captured from real hardware on 2026-08-06, macOS 26.6.1 (25G76).
/// See docs/spikes/2026-08-06-cgs-mode-revelation.md.
enum CGSModeFixtures {
  // MARK: MAG 341C OLED — native 3440x1440, aspect 2.3889

  static let magNativePixels = (3440, 1440)

  /// Revealed: above-native framebuffer, aspect-correct, full refresh.
  static let magRevealed1920x804 = CGSModeDescriptor(
    modeNumber: 101, flags: 0x0020_0001,
    logicalWidth: 1920, logicalHeight: 804,
    pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175, density: 2.0
  )

  static let magRevealed2048x858 = CGSModeDescriptor(
    modeNumber: 105, flags: 0x0020_0001,
    logicalWidth: 2048, logicalHeight: 858,
    pixelWidth: 4096, pixelHeight: 1716, refreshHz: 175, density: 2.0
  )

  static let magRevealedNativeAt2x = CGSModeDescriptor(
    modeNumber: 109, flags: 0x0020_0001,
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 6880, pixelHeight: 2880, refreshHz: 120, density: 2.0
  )

  /// Legacy 4:3 at 2x — real in the CGS list, would letterbox an ultrawide.
  static let magLegacy4x3 = CGSModeDescriptor(
    modeNumber: 97, flags: 0x0020_0001,
    logicalWidth: 1600, logicalHeight: 1200,
    pixelWidth: 3200, pixelHeight: 2400, refreshHz: 175, density: 2.0
  )

  /// A 1x mode — CGS lists these too; revelation must not add them.
  static let magOneX = CGSModeDescriptor(
    modeNumber: 12, flags: 0x0000_0001,
    logicalWidth: 2560, logicalHeight: 1080,
    pixelWidth: 2560, pixelHeight: 1080, refreshHz: 60, density: 1.0
  )

  // MARK: Built-in — the refresh-truncation trap

  /// Present in CoreGraphics as ioModeID 2 at 60Hz; CGS truncates to 59.
  /// Dedup on ID must drop it; dedup on geometry+refresh would not.
  static let builtInDuplicate = CGSModeDescriptor(
    modeNumber: 2, flags: 0x0000_0001,
    logicalWidth: 960, logicalHeight: 600,
    pixelWidth: 1920, pixelHeight: 1200, refreshHz: 59, density: 2.0
  )

  // MARK: Dell U2725QE — the plausibility-calibration case

  static let dellNativePixels = (2160, 3840)

  /// 300x400 is REAL. An intuited 320px floor rejected it (S6 §6).
  static let dellSmallButReal = CGSModeDescriptor(
    modeNumber: 310, flags: 0x0020_0001,
    logicalWidth: 300, logicalHeight: 400,
    pixelWidth: 600, pixelHeight: 800, refreshHz: 60, density: 2.0
  )

  // MARK: Synthetic — what a shifted struct layout looks like

  /// Garbage from a layout shift: pixels disagree with logical x density.
  static let garbageInconsistentPixels = CGSModeDescriptor(
    modeNumber: 500, flags: 0x0000_0001,
    logicalWidth: 1920, logicalHeight: 804,
    pixelWidth: 271_845, pixelHeight: 3, refreshHz: 60, density: 2.0
  )

  static let garbageAbsurdDensity = CGSModeDescriptor(
    modeNumber: 501, flags: 0x0000_0001,
    logicalWidth: 1920, logicalHeight: 804,
    pixelWidth: 3840, pixelHeight: 1608, refreshHz: 60, density: 91_233.5
  )
}

/// CoreGraphics-side fixtures the merge dedups against.
enum RevealedModeFixtures {
  static func magExistingCG() -> [DisplayMode] {
    [
      DisplayMode(
        ioModeID: 69, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true),
      DisplayMode(
        ioModeID: 12, logicalWidth: 2560, logicalHeight: 1080,
        pixelWidth: 2560, pixelHeight: 1080, refreshHz: 60, isNative: false),
    ]
  }

  static func builtInExistingCG() -> [DisplayMode] {
    [
      DisplayMode(
        ioModeID: 66, logicalWidth: 1800, logicalHeight: 1169,
        pixelWidth: 3600, pixelHeight: 2338, refreshHz: 120, isNative: true),
      // The 59.9998 -> 60.0 case, quantized as the CG boundary does it.
      DisplayMode(
        ioModeID: 2, logicalWidth: 960, logicalHeight: 600,
        pixelWidth: 1920, pixelHeight: 1200, refreshHz: 60, isNative: false),
    ]
  }
}
