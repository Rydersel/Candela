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

  /// May a volume or mute KEY act on this display?
  ///
  /// The capability half is `isEnabled` itself, called and not copied: a
  /// keypress and the slider refuse together or not at all. They did not, and
  /// the key path was the one that could write a register the display says it
  /// does not implement, ACK it, and show a rising HUD for a change with
  /// nowhere to land (measured on the DELL U2725QE, 2026-08-11).
  ///
  /// The keyboard half is the per-display "use the keys for this display" pref,
  /// which the slider has no equivalent of. A refusal here SWALLOWS the press:
  /// the key path must not treat it as "nothing resolved" and spray every other
  /// display instead (R1).
  public static func acceptsVolumeKeys(
    isKeyboardDisabled: Bool, override: AudioSinkOverride, volumeSupport: VCPSupport
  ) -> Bool {
    !isKeyboardDisabled && isEnabled(override: override, volumeSupport: volumeSupport)
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

  /// The same two causes, worded for the menu bar's panel (#130).
  ///
  /// Shorter because of WHERE it renders, not to save characters. The panel
  /// draws this in a 280 pt column directly under the display's own name header,
  /// so naming the display again repeats a word already on screen one row up and
  /// wraps a one-line caption onto three. The settings page keeps the long form,
  /// which does name the display, because that page can show several at once.
  ///
  /// Nil exactly when the slider is enabled, the same invariant the long form
  /// holds: the panel binds the caption's existence to this, so a reason can
  /// never outlive the grey that caused it.
  public static func compactDisabledReason(
    override: AudioSinkOverride, volumeSupport: VCPSupport
  ) -> String? {
    guard !isEnabled(override: override, volumeSupport: volumeSupport) else { return nil }
    switch override {
    case .forceNone:
      return "Volume slider set to always off."
    case .auto:
      return "This display lists no volume command."
    case .forcePresent:
      return nil
    }
  }
}
