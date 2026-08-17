import Foundation
@testable import CandelaKit

/// Real mode data captured 2026-08-03 from the two development panels.
/// Raw dumps: `docs/spikes/s2-resolutions/fixtures/`.
///
/// These are the two panel CLASSES W1 identified, and they behave completely
/// differently — the Dell (~163 PPI) gets a full scaled-HiDPI ladder from
/// macOS, the MAG (~110 PPI) gets nothing above its native framebuffer. Any
/// curation change must be checked against both.
enum DisplayModeFixtures {
  /// DELL U2725QE, run rotated 270°, panel native 2160×3840.
  static let dellNativePixels = (2160, 3840)

  /// One representative entry per distinct logical size, HiDPI variants only.
  /// The real list has 177 HiDPI entries; the extra ones are the same sizes at
  /// 24/25/30/50/120 Hz, which curation collapses anyway.
  static let dell: [DisplayMode] = [
    m(300, 400, 600, 800), m(360, 640, 720, 1280), m(378, 672, 756, 1344),
    m(384, 512, 768, 1024), m(400, 640, 800, 1280),
    m(432, 576, 864, 1152, hz: 75),
    m(450, 800, 900, 1600), m(480, 640, 960, 1280), m(504, 672, 1008, 1344),
    m(512, 640, 1024, 1280), m(525, 840, 1050, 1680), m(540, 960, 1080, 1920),
    m(576, 1024, 1152, 2048), m(600, 800, 1200, 1600), m(600, 960, 1200, 1920),
    m(648, 1152, 1296, 2304), m(720, 1280, 1440, 2560), m(846, 1504, 1692, 3008),
    m(900, 1600, 1800, 3200), m(945, 1680, 1890, 3360),
    m(1080, 1920, 2160, 3840, native: true),
    m(1152, 2048, 2304, 4096), m(1296, 2304, 2592, 4608),
    m(1440, 2560, 2880, 5120), m(1692, 3008, 3384, 6016),
    m(1800, 3200, 3600, 6400), m(1890, 3360, 3780, 6720),
  ]

  /// MSI MAG 341C OLED, panel native 3440×1440. Its ENTIRE HiDPI ladder — all
  /// 17 distinct logical sizes. Nothing above the native framebuffer exists.
  static let magNativePixels = (3440, 1440)

  static let mag: [DisplayMode] = [
    m(400, 300, 800, 600), m(512, 384, 1024, 768),
    m(576, 432, 1152, 864, hz: 75),
    m(640, 360, 1280, 720), m(640, 480, 1280, 960),
    m(640, 512, 1280, 1024, hz: 75),
    m(672, 504, 1344, 1008), m(720, 450, 1440, 900), m(800, 335, 1600, 670),
    m(800, 600, 1600, 1200), m(840, 525, 1680, 1050), m(860, 360, 1720, 720),
    m(960, 402, 1920, 804), m(960, 540, 1920, 1080), m(1024, 429, 2048, 858),
    m(1280, 720, 2560, 1440),
    m(1720, 720, 3440, 1440, native: true),
  ]

  /// The MAG's 1x ladder, where the rates it really offers survive. `mag`
  /// above is the HiDPI ladder and carries one rate per size, because curation
  /// collapses the rest — so nothing there can exercise a question about
  /// refresh rates at a size.
  static let magRateLadder: [DisplayMode] = [
    m(3440, 1440, 3440, 1440, hz: 175, native: true),
    m(3440, 1440, 3440, 1440, hz: 120),
    m(3440, 1440, 3440, 1440, hz: 60),
    m(2560, 1080, 2560, 1080, hz: 60),
    m(1920, 1080, 1920, 1080, hz: 120),
    m(1920, 1080, 1920, 1080, hz: 60),
  ]

  /// Built-in MacBook Pro panel, native 3024×1964. Captured 2026-08-17. Raw
  /// dump: `docs/spikes/s2-resolutions/fixtures/builtin-modes-2026-08-17.txt`.
  static let builtInNativePixels = (3024, 1964)

  /// One representative entry per distinct pixel footprint: the 132 published
  /// modes collapse to 12 once refresh rates are dropped. Prefers the HiDPI
  /// (scaled) logical variant, matching the dell and mag arrays' convention:
  /// the dump marks native=true on both rows of the 3024×1964 framebuffer
  /// (the 1x 3024×1964 row and its 1512×982 HiDPI sibling), so the fixture's
  /// native entry is the HiDPI row, same as dell's 1080×1920 and mag's
  /// 1720×720.
  static let builtIn: [DisplayMode] = [
    m(960, 600, 1920, 1200), m(1024, 640, 2048, 1280),
    m(1024, 665, 2048, 1330), m(1147, 716, 2294, 1432),
    m(1147, 745, 2294, 1490), m(1280, 800, 2560, 1600),
    m(1352, 845, 2704, 1690), m(1352, 878, 2704, 1756),
    m(1512, 945, 3024, 1890),
    m(1512, 982, 3024, 1964, native: true),
    m(1800, 1125, 3600, 2250), m(1800, 1169, 3600, 2338),
  ]

  /// Physical panel size in integer centimetres, from the shipped
  /// `Arm64DDC.physicalSizeCm` read (CoreDisplay EDID image-size keys,
  /// integer mm/10). Measured 2026-08-17 through a temporary patch, since
  /// reverted. The Dell reports its panel-native landscape size here even
  /// though it is mounted rotated 270°: the raw dump's `CGDisplayScreenSize`
  /// figures differ from these by up to 1cm, and by orientation on the Dell,
  /// because that read answers in the rotated frame instead. These Arm64DDC
  /// values are the ones production feeds into the density model.
  static let magPhysicalCm = (80, 34)
  static let dellPhysicalCm = (60, 34)
  static let builtInPhysicalCm = (30, 19)

  static func mode(
    _ id: Int32, logical: (Int, Int), pixels: (Int, Int), hz: Double = 60
  ) -> DisplayMode {
    DisplayMode(ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
                pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
                isNative: false)
  }

  /// IDs are derived from the geometry rather than handed out by a counter —
  /// a mutable `static var` is a concurrency error under Swift 6 strict
  /// checking, and a derived ID is stable across reorderings of the arrays
  /// above, which keeps test failures readable.
  ///
  /// The removed `surfaced:` parameter never fed this derivation, so dropping
  /// it leaves every fixture's `ioModeID` unchanged — which matters, because
  /// `DisplayModeCatalog` tie-breaks on `ioModeID` and the ordered assertions
  /// in `DisplayModeCatalogTests` would shift if these moved.
  private static func m(
    _ lw: Int, _ lh: Int, _ pw: Int, _ ph: Int,
    hz: Double = 60, native: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: Int32(truncatingIfNeeded: lw &* 100_003 &+ lh &* 397 &+ Int(hz)),
      logicalWidth: lw, logicalHeight: lh,
      pixelWidth: pw, pixelHeight: ph, refreshHz: hz,
      isNative: native
    )
  }
}
