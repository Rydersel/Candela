import Foundation

/// Why a locked display was NOT hardware-dimmed.
///
/// Typed and recorded rather than swallowed (DT30 rule (a)): lock dim shipped
/// once as a mechanism that reported success while nothing reached the panel
/// [MEASURED 2026-08-07]. A skip no surface can name is the same defect again.
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

/// Whether a locked display can be dimmed on the leg driving it, decided from
/// the SAME `BrightnessPath` the diagnostics section renders.
///
/// The dim is a MULTIPLIER of whatever the user set, never an absolute target,
/// so ruling D (locking never brightens) is a property of the arithmetic rather
/// than a comparison someone has to remember to write.
public enum LockDimPolicy {
  /// The multiplier for a given dim brightness, the IDENTITY by construction:
  /// the setting is "how bright to leave the display" and the multiplier is the
  /// fraction of the user's brightness to keep.
  ///
  /// A named seam rather than inlined: the range clamp lives here, and it was
  /// NOT the identity before the setting was inverted (it returned `1 - level`,
  /// when the number meant overlay opacity).
  public static func factor(forBrightness brightness: Double) -> Double {
    min(max(brightness, OledDimConfig.brightnessRange.lowerBound),
        OledDimConfig.brightnessRange.upperBound)
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
      // so a dim that stays above the band moves nothing at all.
      guard brightness * factor < dimsBelow else { return .skip(.outsideSoftwareBand) }
      return .dim(factor: factor)
    case .native, .hardware, .combined, .software:
      // `.native` included deliberately: live HDR locks the DDC brightness
      // register, but the native leg carries brightness there, so an HDR display
      // dims through DisplayServices rather than being skipped.
      return .dim(factor: factor)
    }
  }
}
