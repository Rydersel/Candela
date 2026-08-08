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
    /// Withheld by the wire-timing guard (#110) — no native-width parent timing
    /// at this refresh, so the panel would scan it out on some other timing.
    public var noNativeParentTiming = 0

    public init() {}

    public var total: Int {
      alreadyKnown + unusable + implausible + notHiDPI + offAspect + noNativeParentTiming
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

  /// The refreshes at which this panel advertises a NATIVE-WIDTH wire timing.
  ///
  /// A mode whose framebuffer exactly equals the panel's native pixel count is
  /// scanned out with no DCP downscale, so its refresh IS an advertised
  /// native-width timing. That makes the CoreGraphics list a public-API window
  /// onto the panel's timing inventory, which is otherwise reachable only
  /// through IORegistry — and, more to the point, the DRIVEN timing is not
  /// exposed anywhere at all (#110).
  ///
  /// Empty when the panel's own timing is not in `existing`: with no evidence
  /// about what the panel advertises, the guard has nothing to admit against.
  public static func nativeParentRefreshes(
    in existing: [DisplayMode], nativePixelWidth: Int, nativePixelHeight: Int
  ) -> Set<Double> {
    guard nativePixelWidth > 0, nativePixelHeight > 0 else { return [] }
    return Set(
      existing
        .filter { $0.pixelWidth == nativePixelWidth && $0.pixelHeight == nativePixelHeight }
        .map { DisplayMode.quantizedRefresh($0.refreshHz) })
  }

  /// The one entry point. Gates run in a fixed order, and each drop is counted
  /// against the FIRST gate that rejected it — so the counts partition the
  /// input rather than double-counting it.
  ///
  /// - Parameter guardsWireTiming: the #110 guard. Not defaulted: the one
  ///   production caller and every test must say which behaviour they mean,
  ///   because the difference is whether a user can reach a mode measured to
  ///   crop a quarter of the desktop off the glass.
  public static func reveal(
    cgs: [CGSModeDescriptor],
    existing: [DisplayMode],
    nativePixelWidth: Int,
    nativePixelHeight: Int,
    guardsWireTiming: Bool
  ) -> RevelationResult {
    let knownIDs = Set(existing.map(\.ioModeID))
    let knownRefreshes = Array(Set(existing.map(\.refreshHz)))
    let nativeRefreshes = nativeParentRefreshes(
      in: existing, nativePixelWidth: nativePixelWidth, nativePixelHeight: nativePixelHeight)
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

      let refresh = DisplayMode.quantizedRefresh(
        resolveRefresh(truncated: descriptor.refreshHz, against: knownRefreshes))

      // 6. THE WIRE-TIMING GUARD (#110). Last, so it counts only modes that
      //    were otherwise worth offering.
      //
      //    A revealed mode is scaled by definition (gate 4), so the DCP must
      //    bind it to some real wire timing. MEASURED on the MAG 341C: when no
      //    native-width timing exists at the mode's refresh, it gets bound to
      //    an arbitrary same-refresh timing instead — the 120 Hz rung scanned
      //    out at 2560x1440 (desktop pillarboxed, rightmost ~880 logical
      //    columns cropped away) and the 75 Hz rung at 1280x1024.
      //
      //    NOTHING IN SOFTWARE CAN SEE THIS. `CGDisplayCopyDisplayMode`, the
      //    capture size, `CGDisplayBounds`, `backingScaleFactor` and this
      //    package's own post-commit achieved-state check are all clean in the
      //    broken state, and no IORegistry property records the driven timing
      //    (searched live while broken). Prediction is the only defence, and
      //    the keep/revert countdown is the only detector — see
      //    docs/spikes/2026-08-07-exact-2to1-camera-gate.md §1.
      //
      //    The rule was validated by PREDICTION: 75 Hz was called broken from
      //    the advertised-timing inventory before it was ever applied.
      if guardsWireTiming, !nativeRefreshes.contains(refresh) {
        counts.noNativeParentTiming += 1
        continue
      }

      revealed.append(
        DisplayMode(
          ioModeID: descriptor.modeNumber,
          logicalWidth: descriptor.logicalWidth,
          logicalHeight: descriptor.logicalHeight,
          pixelWidth: descriptor.pixelWidth,
          pixelHeight: descriptor.pixelHeight,
          refreshHz: refresh,
          // A revealed mode is a SCALED mode, never the panel's own timing.
          isNative: false,
          provenance: .coreGraphicsServices
        ))
    }

    return RevelationResult(modes: revealed, dropped: counts)
  }
}
