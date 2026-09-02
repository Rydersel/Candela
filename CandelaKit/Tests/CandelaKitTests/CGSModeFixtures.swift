import Foundation

@testable import CandelaKit

/// Captured from real hardware on 2026-08-06, macOS 26.6.1 (25G76).
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

  // The exact-2:1 family. All pass gates 1-5 and differ only in refresh, which is what
  // the wire-timing guard judges them on. The glass verdicts below were measured on the
  // panel, not assumed.

  /// id 109 @ 120 Hz. MEASURED BROKEN: scanned out at 2560x1440, desktop
  /// pillarboxed with the rightmost ~880 logical columns cropped away.
  static let magRevealedNativeAt2x = CGSModeDescriptor(
    modeNumber: 109, flags: 0x0020_0001,
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 6880, pixelHeight: 2880, refreshHz: 120, density: 2.0
  )

  /// id 110 @ 100 Hz. MEASURED CORRECT: OSD read 3440x1440 @ 100, full panel.
  static let magRevealedNativeAt2x100 = CGSModeDescriptor(
    modeNumber: 110, flags: 0x0020_0001,
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 6880, pixelHeight: 2880, refreshHz: 100, density: 2.0
  )

  /// id 111 @ 75 Hz. MEASURED BROKEN: OSD read 1280x1024 @ 75. The prediction case,
  /// called broken from the timing inventory before it was ever applied.
  static let magRevealedNativeAt2x75 = CGSModeDescriptor(
    modeNumber: 111, flags: 0x0020_0001,
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 6880, pixelHeight: 2880, refreshHz: 75, density: 2.0
  )

  /// id 114 @ 60 Hz. MEASURED CORRECT: full panel.
  static let magRevealedNativeAt2x60 = CGSModeDescriptor(
    modeNumber: 114, flags: 0x0020_0001,
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 6880, pixelHeight: 2880, refreshHz: 60, density: 2.0
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

  /// 300x400 is REAL. An intuited 320px floor rejected it.
  static let dellSmallButReal = CGSModeDescriptor(
    modeNumber: 310, flags: 0x0020_0001,
    logicalWidth: 300, logicalHeight: 400,
    pixelWidth: 600, pixelHeight: 800, refreshHz: 60, density: 2.0
  )

  /// The Dell's only exact-2:1 rung, at 75 Hz, a refresh the panel advertises no
  /// native-width timing for. Never engaged on hardware; the guard predicts it would
  /// scan out wrong.
  static let dellRevealedNativeAt2x = CGSModeDescriptor(
    modeNumber: 272, flags: 0x0020_0001,
    logicalWidth: 2160, logicalHeight: 3840,
    pixelWidth: 4320, pixelHeight: 7680, refreshHz: 75, density: 2.0
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
  /// The shape the wire-timing guard turns on: the panel's native-width timings are
  /// 175/144/100/60 (framebuffer 3440x1440), and CoreGraphics also publishes 120 Hz modes,
  /// but only at the narrower 2560x1440 framebuffer. ids 22 and 67 are here so a guard
  /// asking only "does any mode run at this refresh?" admits the rung that crops the desktop.
  static func magExistingCG() -> [DisplayMode] {
    [
      // Native-width family — framebuffer == the panel's own 3440x1440.
      DisplayMode(
        ioModeID: 69, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true),
      DisplayMode(
        ioModeID: 70, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 144, isNative: true),
      DisplayMode(
        ioModeID: 71, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 100, isNative: true),
      DisplayMode(
        ioModeID: 72, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 60, isNative: true),
      // Same native framebuffer at 2x — a HiDPI member of the same family, so
      // the guard must key on the FRAMEBUFFER and not on the logical size.
      DisplayMode(
        ioModeID: 50, logicalWidth: 1720, logicalHeight: 720,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true),
      // 120 Hz exists on this panel — at a NARROWER framebuffer only.
      DisplayMode(
        ioModeID: 67, logicalWidth: 2560, logicalHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440, refreshHz: 120, isNative: false),
      DisplayMode(
        ioModeID: 22, logicalWidth: 1280, logicalHeight: 720,
        pixelWidth: 2560, pixelHeight: 1440, refreshHz: 120, isNative: false),
      DisplayMode(
        ioModeID: 12, logicalWidth: 2560, logicalHeight: 1080,
        pixelWidth: 2560, pixelHeight: 1080, refreshHz: 60, isNative: false),
    ]
  }

  /// The Dell's native-width family (rotated 270°, so native is 2160x3840). No 75 Hz
  /// anywhere in the advertised timings, which is what makes its single 2:1 rung suspect.
  static func dellExistingCG() -> [DisplayMode] {
    [60.0, 59.9, 50.0, 30.0, 120.0].enumerated().map { index, rate in
      DisplayMode(
        ioModeID: Int32(160 + index), logicalWidth: 2160, logicalHeight: 3840,
        pixelWidth: 2160, pixelHeight: 3840, refreshHz: rate, isNative: true)
    }
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
