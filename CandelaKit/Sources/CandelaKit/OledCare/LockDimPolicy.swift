import Foundation

/// Why a locked display was NOT hardware-dimmed.
///
/// Typed, and recorded rather than swallowed, for the reason DT30 rule (a) gives
/// and for the reason this feature exists at all: lock dim shipped once already
/// as a mechanism that reported success while nothing reached the panel (the
/// overlay measurement of 2026-08-07). A skip that no surface can name is the
/// same defect wearing a different mechanism.
public enum LockDimSkip: Equatable, Sendable {
  /// `BrightnessPath.unavailable`: no leg carries this display's brightness, so
  /// there is nothing to turn down.
  case nothingDrivesBrightness
  /// Combined dimming with its DDC half turned off, where BOTH the current
  /// value and the dim target sit in the band the software leg holds flat at 1.
  /// The write would be accepted and change nothing.
  case outsideSoftwareBand
  /// The display is already at or below what the dim would ask for: a factor of
  /// 1, or a display already at 0.
  case alreadyAtTarget
}

public enum LockDimDecision: Equatable, Sendable {
  case dim(factor: Double)
  case skip(LockDimSkip)
}

/// Whether a locked display can actually be dimmed on the leg that is driving
/// it, decided from the SAME `BrightnessPath` the diagnostics section renders.
///
/// Pure, so the decision is testable without a panel; the coordinator performs
/// it and records the skip. The dim itself is a MULTIPLIER of whatever the user
/// set, never an absolute target: spec ruling D (locking never brightens) is
/// then a property of the arithmetic instead of a comparison someone has to
/// remember to write.
public enum LockDimPolicy {
  /// `level` is the OLED care dim level, the same 0.1...0.9 the idle dim uses.
  /// As an overlay it was an opacity; on the wire it is how much brightness to
  /// take away, which is the same sentence about the same number.
  public static func factor(forLevel level: Double) -> Double {
    1 - min(max(level, OledDimConfig.levelRange.lowerBound),
            OledDimConfig.levelRange.upperBound)
  }

  public static func decide(
    path: BrightnessPath, brightness: Double, factor: Double
  ) -> LockDimDecision {
    guard factor < 1, brightness > 0 else { return .skip(.alreadyAtTarget) }
    switch path {
    case .unavailable:
      return .skip(.nothingDrivesBrightness)
    case let .softwareOnly(_, _, dimsBelow):
      // `combinedSplit` hands the software leg a flat 1 at or above the band,
      // and the DDC submit this path is named for never happens. A dim that
      // stays above the band therefore moves nothing at all.
      guard brightness * factor < dimsBelow else { return .skip(.outsideSoftwareBand) }
      return .dim(factor: factor)
    case .native, .hardware, .combined, .software:
      // `.native` included deliberately: live HDR locks the DDC brightness
      // register, but the native leg is exactly what carries brightness there,
      // so an HDR display dims through DisplayServices rather than being
      // skipped. Nothing here needs to know which of the two it got, because
      // `applyPaths` re-runs the same table when the dim is applied.
      return .dim(factor: factor)
    }
  }
}
