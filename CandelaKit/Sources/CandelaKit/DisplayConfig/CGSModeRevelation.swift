import Foundation

/// Turns raw CGS descriptors into modes worth showing someone.
///
/// Foundation only, by design: every decision here is testable against captured
/// fixtures, and the adapter that reads the descriptors makes none of them
/// (CR8). Spec: docs/superpowers/specs/2026-08-06-cgs-mode-revelation-design.md
public enum CGSModeRevelation {
  // MARK: - Gate constants
  //
  // CALIBRATED FROM CAPTURED DATA, NOT INTUITED (CR4). The Dell publishes a
  // real 300x400 mode; a guessed 320px floor rejected it during the spike.

  public static let minimumLogicalAxis = 256
  public static let maximumLogicalAxis = 16384
  public static let minimumDensity = 0.5
  public static let maximumDensity = 4.0
  /// Native-at-2x is exactly 4x the native pixel COUNT, and it is a mode we
  /// want, so this is a ceiling that includes it rather than excludes it.
  public static let maximumNativePixelMultiple = 4
  /// A revealed mode must be HiDPI. We are not second-guessing CoreGraphics'
  /// omission of 1x modes (CR5).
  public static let minimumHiDPIDensity = 1.5
  /// Fractional tolerance against the panel's own aspect (CR6).
  public static let aspectTolerance = 0.02

  /// Why descriptors were dropped. Surfaced in diagnostics rather than
  /// discarded — a silent filter is the thing we criticise elsewhere (CR11).
  public struct DropCounts: Sendable, Equatable {
    public var alreadyKnown = 0
    public var unusable = 0
    public var implausible = 0
    public var notHiDPI = 0
    public var offAspect = 0

    public init() {}

    public var total: Int {
      alreadyKnown + unusable + implausible + notHiDPI + offAspect
    }
  }

  /// Revealed modes plus an account of what was thrown away and why.
  public struct RevelationResult: Sendable, Equatable {
    public let modes: [DisplayMode]
    public let dropped: DropCounts

    public init(modes: [DisplayMode], dropped: DropCounts) {
      self.modes = modes
      self.dropped = dropped
    }
  }

  /// Does this descriptor describe a mode that could physically exist?
  ///
  /// This is the guard against a struct-layout shift in a future macOS: a
  /// reordered struct yields values that fail these checks, so the feature
  /// degrades to "nothing revealed" instead of offering garbage modes.
  public static func isPlausible(
    _ d: CGSModeDescriptor, nativePixelWidth: Int, nativePixelHeight: Int
  ) -> Bool {
    guard nativePixelWidth > 0, nativePixelHeight > 0 else { return false }
    guard d.logicalWidth >= minimumLogicalAxis, d.logicalWidth <= maximumLogicalAxis,
      d.logicalHeight >= minimumLogicalAxis, d.logicalHeight <= maximumLogicalAxis
    else { return false }
    guard d.density >= minimumDensity, d.density <= maximumDensity else { return false }

    // The framebuffer fields must agree with logical x density, or we are not
    // reading the fields we think we are reading. +/-1 absorbs rounding only.
    let expectedWidth = Int((Double(d.logicalWidth) * d.density).rounded())
    let expectedHeight = Int((Double(d.logicalHeight) * d.density).rounded())
    guard abs(d.pixelWidth - expectedWidth) <= 1,
      abs(d.pixelHeight - expectedHeight) <= 1
    else { return false }

    let nativeCount = nativePixelWidth * nativePixelHeight
    guard d.pixelWidth > 0, d.pixelHeight > 0,
      d.pixelWidth * d.pixelHeight <= nativeCount * maximumNativePixelMultiple
    else { return false }

    return true
  }

  /// CGS reports refresh as a truncated integer, so 59.9998 arrives as 59.
  /// Showing "59 Hz" for a 60 Hz mode is a visible wart, but inventing
  /// precision we do not have is worse — so a CoreGraphics value is adopted
  /// only when it is within 1 Hz, and otherwise the integer stands (CR7).
  ///
  /// Ties break toward the larger candidate so the result is deterministic
  /// rather than dependent on set iteration order.
  public static func resolveRefresh(truncated: Int, against candidates: [Double]) -> Double {
    let target = Double(truncated)
    let near = candidates.filter { abs($0 - target) <= 1.0 }
    guard !near.isEmpty else { return target }
    return near.sorted { lhs, rhs in
      let dl = abs(lhs - target)
      let dr = abs(rhs - target)
      return dl == dr ? lhs > rhs : dl < dr
    }[0]
  }

  /// The one entry point. Gates run in a fixed order, and each drop is counted
  /// against the FIRST gate that rejected it — so the counts partition the
  /// input rather than double-counting it.
  public static func reveal(
    cgs: [CGSModeDescriptor],
    existing: [DisplayMode],
    nativePixelWidth: Int,
    nativePixelHeight: Int
  ) -> RevelationResult {
    let knownIDs = Set(existing.map(\.ioModeID))
    let knownRefreshes = Array(Set(existing.map(\.refreshHz)))
    let nativeAspect =
      nativePixelHeight > 0
      ? Double(nativePixelWidth) / Double(nativePixelHeight)
      : 0

    var counts = DropCounts()
    var revealed: [DisplayMode] = []

    for descriptor in cgs {
      // 1. Already published by CoreGraphics — dedup on ID ONLY (CR1).
      if knownIDs.contains(descriptor.modeNumber) {
        counts.alreadyKnown += 1
        continue
      }
      // 2. macOS says it is not usable for the desktop.
      if !descriptor.isUsable {
        counts.unusable += 1
        continue
      }
      // 3. Could this mode physically exist? Guards a layout shift (CR4).
      if !isPlausible(
        descriptor, nativePixelWidth: nativePixelWidth, nativePixelHeight: nativePixelHeight)
      {
        counts.implausible += 1
        continue
      }
      // 4. HiDPI only (CR5).
      if descriptor.density < minimumHiDPIDensity {
        counts.notHiDPI += 1
        continue
      }
      // 5. Aspect-correct only (CR6).
      guard nativeAspect > 0,
        abs(descriptor.aspectRatio - nativeAspect) / nativeAspect <= aspectTolerance
      else {
        counts.offAspect += 1
        continue
      }

      revealed.append(
        DisplayMode(
          ioModeID: descriptor.modeNumber,
          logicalWidth: descriptor.logicalWidth,
          logicalHeight: descriptor.logicalHeight,
          pixelWidth: descriptor.pixelWidth,
          pixelHeight: descriptor.pixelHeight,
          refreshHz: DisplayMode.quantizedRefresh(
            resolveRefresh(truncated: descriptor.refreshHz, against: knownRefreshes)),
          // A revealed mode is a SCALED mode, never the panel's own timing.
          isNative: false,
          provenance: .coreGraphicsServices
        ))
    }

    return RevelationResult(modes: revealed, dropped: counts)
  }
}
