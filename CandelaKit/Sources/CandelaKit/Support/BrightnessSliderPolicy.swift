import Foundation

/// Why a brightness slider is not doing what it looks like it does.
///
/// Sibling of `VolumeSliderPolicy`'s reason pair: the sentence a surface shows
/// comes from the decision that produced it, never from the surface reading the
/// prefs itself. `VolumeSliderPolicy` got there first, after one hardcoded
/// sentence blamed the display for every grey.
public enum BrightnessSliderPolicy {
  /// Says what the slider IS doing before what stopped: the first thing to know
  /// is that the control still works.
  public static let wireUnresponsiveReason =
    "Dimming in software: this display stopped answering brightness commands."

  /// The caption for a display whose wire stopped answering, or nil.
  ///
  /// The PATH decides, so a command the user turned off is not blamed on the
  /// display (the wire-degradation ordering). The verdict is needed for one
  /// arm: in pure-DDC configuration the demotion answers the same full-range
  /// software leg force-software selects, so the path cannot tell those two
  /// apart.
  public static func compactDegradedReason(
    path: BrightnessPath, isWireUnresponsive: Bool
  ) -> String? {
    switch path {
    case .softwareOnly(_, .ddcUnresponsive, _), .unavailable(.ddcUnresponsiveWithNoSoftwareLeg):
      wireUnresponsiveReason
    case .software:
      isWireUnresponsive ? wireUnresponsiveReason : nil
    case .native, .hardware, .combined, .softwareOnly, .unavailable:
      nil
    }
  }
}
