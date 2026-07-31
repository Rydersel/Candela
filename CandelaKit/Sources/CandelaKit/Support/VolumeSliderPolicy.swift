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
}
