/// Does the panel's volume slider accept input for this display?
///
/// Deliberately NOT a function of CoreAudio. "macOS sees no output device with
/// this display's name" cannot be told apart from "this link carries no audio
/// while the panel's speakers run off another input" (DVI/VGA, some adapters,
/// a monitor fed by a second source), and the failure is asymmetric: a false
/// grey removes a working control with no visible reason, a false enable costs
/// one pointless slider. `AudioRoutingPolicy.displayHasAudioSink` is retained
/// deliberately, with no production caller.
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
  /// The capability half is `isEnabled` itself, called and not copied, so a keypress
  /// and the slider refuse together. They did not, and the key path was the one that
  /// could write a register the display says it does not implement, ACK it, and show
  /// a rising HUD for a change with nowhere to land [MEASURED, DELL U2725QE].
  ///
  /// The keyboard half is the per-display "use the keys for this display" pref. A
  /// refusal here SWALLOWS the press: the key path must not treat it as "nothing
  /// resolved" and spray every other display instead.
  public static func acceptsVolumeKeys(
    isKeyboardDisabled: Bool, override: AudioSinkOverride, volumeSupport: VCPSupport
  ) -> Bool {
    acceptsKey(
      isKeyboardDisabled: isKeyboardDisabled, override: override, writtenRegister: volumeSupport
    )
  }

  /// May a MUTE key act on this display?
  ///
  /// Same rule, asked about the register the key would actually write, which depends
  /// on the display's mute strategy. `enableMuteUnmute` sends VCP 0x8D and never
  /// touches the volume register, so 0x8D's verdict decides. Without it, mute
  /// degrades to a volume-register write of 0 and 0x62's verdict applies. A display
  /// advertising mute but not volume keeps its mute key; a single 0x62 gate would
  /// have taken it away.
  ///
  /// `usesDedicatedMuteCommand` is the STRATEGY IN FORCE, not the raw pref. On a
  /// display that denies 0x8D it is false, because the write degrades to the volume
  /// register; passing the pref would judge the key on a register nothing touches.
  ///
  /// Refusing here does NOT put unmuting out of reach. Every route back
  /// drives the controller directly and consults no capability verdict.
  public static func acceptsMuteKey(
    isKeyboardDisabled: Bool,
    override: AudioSinkOverride,
    volumeSupport: VCPSupport,
    muteSupport: VCPSupport,
    usesDedicatedMuteCommand: Bool
  ) -> Bool {
    acceptsKey(
      isKeyboardDisabled: isKeyboardDisabled,
      override: override,
      writtenRegister: usesDedicatedMuteCommand ? muteSupport : volumeSupport
    )
  }

  /// Which register a mute on this display actually lands on: its own mute
  /// command (VCP 0x8D), or the volume register driven to 0.
  ///
  /// The pref asks for the dedicated command; the display's capabilities string can
  /// refuse it, under the same rule that greys the slider. A refusal DEGRADES
  /// this display to the strategy every display without a dedicated mute command
  /// already uses, which is why this answers "which register" rather than "may we
  /// mute": a mute the app records and no register carries is the phantom state the
  /// capability-verdict rule exists to prevent.
  ///
  /// The verdict gates the MUTE direction only. Every unmute is ungated wherever it
  /// is written, because the verdict comes off a string the display supplied and can
  /// arrive after the mute did.
  ///
  /// One definition for the engine's mute writes and for the mute key's gate, so a
  /// keypress and a slider crossing cannot disagree about the register.
  public static func usesDedicatedMuteCommand(
    prefEnabled: Bool, override: AudioSinkOverride, muteSupport: VCPSupport
  ) -> Bool {
    prefEnabled && isEnabled(override: override, volumeSupport: muteSupport)
  }

  /// Why the mute this display will actually take is not the one its settings row
  /// promises. `nil` when the row is telling the truth.
  ///
  /// The row draws the PREF, and the pref is only a request: `.forceNone` and the
  /// display's own denial of 0x8D each demote it to the volume-register mute, leaving
  /// the row reading On over an engine that will write 0x62. The guard calls
  /// `usesDedicatedMuteCommand` rather than restating its rule, so the caption cannot
  /// outlive its cause.
  ///
  /// The two causes are worded apart: a user who set the slider to always off and is
  /// told their monitor refused goes to check a cable.
  ///
  /// `commandIsAvailable` is the volume command's own availability, which `toggleMute`
  /// guards on under either strategy. False means no mute is written at all, so the
  /// row's own unavailable sentence applies instead.
  ///
  /// The consequence is worded as the LEVEL the degrade reaches, not a register value:
  /// the degrade goes out through `rawValue(for: 0)`, so a volume floor writes that
  /// floor and Invert writes the top of the range. "All the way down" is true of all
  /// of them.
  public static func degradedMuteReason(
    commandIsAvailable: Bool, prefEnabled: Bool, override: AudioSinkOverride, muteSupport: VCPSupport
  ) -> String? {
    guard commandIsAvailable, prefEnabled,
          !usesDedicatedMuteCommand(
            prefEnabled: prefEnabled, override: override, muteSupport: muteSupport)
    else { return nil }
    switch override {
    case .forceNone:
      return "The volume slider for this display is set to always off, so muting turns its volume all the way down."
    case .auto:
      return "This display lists no mute command in its description, so muting turns its volume all the way down."
    case .forcePresent:
      // Unreachable: forcePresent keeps the dedicated command whatever the
      // display says, so the guard above returned. Stated rather than defaulted
      // so a new case is a compile error here.
      return nil
    }
  }

  /// Should the event tap WATCH the volume keys on this display's account?
  ///
  /// `acceptsVolumeKeys` answers who a press ACTS on; the tap decides what to swallow
  /// before any of that is known. Arming asks everything that makes a press
  /// IMPOSSIBLE here and nothing that makes it a deliberate no-op, because a watched
  /// key is CONSUMED: watching one for a display that cannot take it leaves the key
  /// dead in both directions, reaching neither this app nor macOS.
  ///
  /// So the per-display keyboard switch is left out, and it is the only thing left
  /// out: a display whose keyboard control the user turned off swallows its press
  /// the same as for brightness, and must keep the keys watched.
  ///
  /// `commandIsAvailable` is `DDCValueController.isAvailable` for the volume command:
  /// false when the per-command On switch is off, or when the display is forced to
  /// software dimming. Passed in rather than re-derived from prefs so the tap and the
  /// controller cannot disagree about the same wire. It outranks the capability
  /// verdict and the user's override, neither of which can make a switched-off wire
  /// carry a write.
  public static func armsVolumeKeys(
    commandIsAvailable: Bool, override: AudioSinkOverride, volumeSupport: VCPSupport
  ) -> Bool {
    commandIsAvailable
      && acceptsVolumeKeys(
        isKeyboardDisabled: false, override: override, volumeSupport: volumeSupport
      )
  }

  /// The same question for the mute key, asked about the register it would
  /// write. The two families arm separately because they are denied separately:
  /// a display that lists 0x8D and not 0x62 keeps its mute key while its volume
  /// keys go to macOS.
  ///
  /// `commandIsAvailable` is the VOLUME command's availability under both strategies,
  /// not an approximation: `toggleMute` runs on the volume controller and guards on
  /// its `isAvailable` even when the wire it writes is 0x8D.
  ///
  /// `usesDedicatedMuteCommand` is the STRATEGY IN FORCE, as `acceptsMuteKey` takes
  /// it. Passing the raw pref would arm this key on the verdict for a register the
  /// write does not touch: where the engine degrades a mute to the volume register,
  /// the tap must watch the key rather than hand it to macOS.
  public static func armsMuteKey(
    commandIsAvailable: Bool,
    override: AudioSinkOverride,
    volumeSupport: VCPSupport,
    muteSupport: VCPSupport,
    usesDedicatedMuteCommand: Bool
  ) -> Bool {
    commandIsAvailable
      && acceptsMuteKey(
        isKeyboardDisabled: false,
        override: override,
        volumeSupport: volumeSupport,
        muteSupport: muteSupport,
        usesDedicatedMuteCommand: usesDedicatedMuteCommand
      )
  }

  /// `isEnabled` reads its argument as the verdict for the register in
  /// question: the capability-verdict rule (a clean denial refuses, no evidence allows, the
  /// user's override outranks both) is per command, not specific to 0x62.
  /// Delegating keeps ONE copy of that rule for the slider and both key families.
  private static func acceptsKey(
    isKeyboardDisabled: Bool, override: AudioSinkOverride, writtenRegister: VCPSupport
  ) -> Bool {
    !isKeyboardDisabled && isEnabled(override: override, volumeSupport: writtenRegister)
  }

  /// Why the slider is refusing input, for the panel's tooltip. `nil` when it is
  /// enabled, and beside `isEnabled` so a tooltip cannot outlive its condition.
  ///
  /// **Two different facts reach here and the old tooltip collapsed them.** It said
  /// "<name> reports no volume control over DDC" for every grey, so a user who had
  /// turned the slider off themselves was told their monitor had refused, which sends
  /// them to check a cable. On a write-only panel it was false twice over: that
  /// display reports nothing at all, and the capability-verdict rule resolves its unknown to ENABLED, so the
  /// only way it could grey was the override the sentence denied [MEASURED].
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

  /// The same two causes, worded for the menu bar's panel.
  ///
  /// Shorter because of WHERE it renders: a 280 pt column directly under the
  /// display's own name header, so naming the display again repeats a word one row up
  /// and wraps one line onto three. The settings page keeps the long form, which does
  /// name the display, because that page can show several at once.
  ///
  /// Nil exactly when the slider is enabled, so a reason cannot outlive its grey.
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
