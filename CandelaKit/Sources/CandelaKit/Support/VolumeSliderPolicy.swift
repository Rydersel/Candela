/// Does the panel's volume slider accept input for this display? (D24.)
///
/// Deliberately NOT a function of CoreAudio. "macOS sees no output device with
/// this display's name" cannot be told apart from "this link carries no audio
/// while the panel's speakers run off another input" (DVI/VGA, some adapters,
/// a monitor fed by a second source), and the failure is asymmetric: a false
/// grey removes a working control with no visible reason, a false enable costs
/// one pointless slider. `AudioRoutingPolicy.displayHasAudioSink` still exists
/// and is still tested — see the note Task 18 leaves on it: it has no
/// production caller in v1 and is retained deliberately.
public enum VolumeSliderPolicy {
  public static func isEnabled(override: AudioSinkOverride, volumeSupport: VCPSupport) -> Bool {
    switch override {
    case .forceNone:
      false
    case .forcePresent:
      true
    case .auto:
      // The ONLY automatic grey: the monitor's capabilities string parsed
      // cleanly and does not list the feature. Unknown resolves to enabled.
      volumeSupport != .unsupported
    }
  }

  /// Why the slider is refusing input, for the panel's tooltip. `nil` when it
  /// is enabled: a working control has nothing to explain.
  ///
  /// Lives beside `isEnabled` so the two cannot drift. A tooltip that outlives
  /// the condition it describes is worse than none, and these are the same
  /// switch read twice.
  ///
  /// **Two different facts reach here and the old tooltip collapsed them.** It
  /// said "<name> reports no volume control over DDC" for every grey, so a
  /// user who had turned the slider off themselves was told their monitor had
  /// refused, which sends them to check a cable. On a write-only panel it was
  /// false twice over: that display reports nothing at all, and D24 resolves
  /// its unknown to ENABLED, so the only way it could grey was the override
  /// the sentence denied. Found on hardware 2026-08-10, Checkpoint 1 item 81.
  public static func disabledReason(
    displayName: String, override: AudioSinkOverride, volumeSupport: VCPSupport
  ) -> String? {
    guard !isEnabled(override: override, volumeSupport: volumeSupport) else { return nil }
    switch override {
    case .forceNone:
      return "The volume slider for \(displayName) is set to always off."
    case .auto:
      return "\(displayName) lists no volume command in its description."
    case .forcePresent:
      // Unreachable: forcePresent always enables, so the guard above returned.
      // Stated rather than defaulted so a new case is a compile error here.
      return nil
    }
  }
}
