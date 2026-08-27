import Foundation

/// Why a brightness slider is not doing what it looks like it does.
///
/// The sibling of `VolumeSliderPolicy`'s reason pair, and it exists for the same
/// reason: the sentence a surface shows comes from the decision that produced
/// it, never from the surface's own reading of the prefs. D24 got there first
/// for the volume denial, where one hardcoded sentence blamed the display for
/// every grey, including the greys the user caused.
public enum BrightnessSliderPolicy {
  /// The wire's own sentence. It says what the slider IS doing before it says
  /// what stopped, because the first thing someone needs to know is that the
  /// control still works.
  public static let wireUnresponsiveReason =
    "Dimming in software: this display stopped answering brightness commands."

  /// The caption for a display whose wire stopped answering, or nil when there
  /// is nothing to say.
  ///
  /// Takes the PATH as well as the wire's verdict, and the path is what decides:
  /// a display whose brightness command the user turned off is reported as
  /// turned off (WD2's ordering), so a caption keyed on the verdict alone would
  /// blame the display for a switch a person flipped. The verdict is still
  /// needed for one arm: in pure-DDC configuration the demotion answers the
  /// full-range software leg, which is the identical path force-software
  /// selects, so nothing in the path can tell those two apart.
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
