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
    acceptsKey(
      isKeyboardDisabled: isKeyboardDisabled, override: override, writtenRegister: volumeSupport
    )
  }

  /// May a MUTE key act on this display?
  ///
  /// Same rule, asked about the register the key would actually write, because
  /// which register that is depends on the display's mute strategy.
  /// `enableMuteUnmute` sends VCP 0x8D and never writes the volume register, so
  /// 0x8D's own verdict decides. Without it (the default) mute degrades to a
  /// volume-register write of 0, silence is 0x62's job, and 0x62's verdict is
  /// the one that applies. A display advertising mute but not volume keeps its
  /// mute key under the dedicated strategy; a single 0x62 gate would have taken
  /// it away.
  ///
  /// `usesDedicatedMuteCommand` is the STRATEGY IN FORCE, not the raw pref:
  /// `usesDedicatedMuteCommand(prefEnabled:override:muteSupport:)` computes it,
  /// and on a display that denies 0x8D the answer is false because the write
  /// degrades to the volume register. Passing the pref instead would judge the
  /// key on a register the write will not touch.
  ///
  /// Refusing here does NOT put unmuting out of reach, which is what D29 rule 3
  /// demands of any gate near this register. Every route back drives the
  /// controller directly and consults no capability verdict: the display's own
  /// mute toggle, the hardware-control toggle, the settings reset, and the
  /// stranded-mute banner.
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
  /// The pref asks for the dedicated command; the display's own capabilities
  /// string can refuse it, under the same D24 rule that greys the slider, one
  /// register over. A refusal DEGRADES this display to the strategy every
  /// display without a dedicated mute command already uses, which is why this
  /// answers "which register" rather than "may we mute": a mute the app
  /// records and no register carries is the phantom state D24 exists to
  /// prevent, not a safer outcome than muting.
  ///
  /// The verdict gates the MUTE direction only. Every unmute is ungated
  /// wherever it is written, because the verdict comes off a string the
  /// display supplied and can arrive after the mute did: a display muted over
  /// 0x8D while the probe was still pending must not have its way back decided
  /// by the verdict that landed since (D29 rule 3).
  ///
  /// One definition for the engine's mute writes and for the mute key's gate,
  /// so a keypress and a slider crossing cannot disagree about the register.
  public static func usesDedicatedMuteCommand(
    prefEnabled: Bool, override: AudioSinkOverride, muteSupport: VCPSupport
  ) -> Bool {
    prefEnabled && isEnabled(override: override, volumeSupport: muteSupport)
  }

  /// Why the mute this display will actually take is not the one its settings
  /// row promises. `nil` when the row is telling the truth, which is every cell
  /// where the strategy in force equals the pref.
  ///
  /// The row draws the PREF, and the pref is only a request: `.forceNone` and
  /// the display's own denial of 0x8D each demote it to the volume-register
  /// mute, leaving the row reading On over an engine that will write 0x62. The
  /// guard calls `usesDedicatedMuteCommand` rather than restating its rule, so
  /// the caption appears in exactly the cells the engine degrades in and cannot
  /// outlive its cause: the same delegation `disabledReason` uses for the slider.
  ///
  /// TWO causes, worded apart, because the slider's tooltip already paid for
  /// collapsing them (Checkpoint 1 item 81): a user who set the slider to always
  /// off and is told their monitor refused goes to check a cable.
  ///
  /// `commandIsAvailable` is the volume command's own availability, which
  /// `toggleMute` guards on under either strategy. False means no mute is
  /// written at all, so there is no register to name, and the row's own
  /// unavailable sentence (SO5) is what applies instead.
  ///
  /// The consequence is worded as the LEVEL the degrade reaches and not as a
  /// register value, because the register value is not knowable from here: the
  /// degrade goes out through `rawValue(for: 0)`, so a volume floor writes that
  /// floor and Invert writes the top of the range. "All the way down" is true of
  /// every one of them, and it is the only claim a person setting a floor cannot
  /// falsify.
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
  /// `acceptsVolumeKeys` answers who a press ACTS on, and the tap has to decide
  /// what to swallow before any of that is known. Arming asks everything that
  /// makes a press IMPOSSIBLE here and nothing that makes it a deliberate no-op,
  /// because a watched key is CONSUMED: watching one on the account of a display
  /// that cannot take it leaves the key dead in both directions, reaching neither
  /// this app nor macOS.
  ///
  /// So the per-display keyboard switch is left out, and it is the only thing
  /// left out: a display whose keyboard control the user turned off swallows its
  /// press (R1), the same as it does for brightness, and must keep the keys
  /// watched.
  ///
  /// `commandIsAvailable` is `DDCValueController.isAvailable` for the volume
  /// command, which is the engine's own gate: false when the per-command On
  /// switch is off, or when the display is forced to software dimming and gets no
  /// DDC volume traffic at all. It is passed in rather than re-derived from prefs
  /// so that the tap and the controller cannot come to different conclusions
  /// about the same wire. It outranks both the capability verdict and the user's
  /// override, neither of which can make a switched-off wire carry a write.
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
  /// `commandIsAvailable` is the VOLUME command's availability under both mute
  /// strategies, and that is not an approximation: `toggleMute` runs on the
  /// volume controller and guards on its `isAvailable` even when the wire it
  /// writes is 0x8D. Switching the volume command off takes the mute key with it.
  ///
  /// `usesDedicatedMuteCommand` is the STRATEGY IN FORCE, computed by
  /// `usesDedicatedMuteCommand(prefEnabled:override:muteSupport:)`, exactly as
  /// `acceptsMuteKey` takes it. Passing the raw pref would arm this key on the
  /// verdict for a register the write does not touch: on a display that denies
  /// 0x8D and takes 0x62, the engine degrades the mute to the volume register,
  /// so the tap must watch the key rather than hand it to macOS.
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
  /// question: D24's rule (a clean denial refuses, no evidence allows, the
  /// user's override outranks both) is per command, not specific to 0x62.
  /// Delegating rather than restating is what keeps ONE copy of that rule for
  /// the slider and both key families.
  private static func acceptsKey(
    isKeyboardDisabled: Bool, override: AudioSinkOverride, writtenRegister: VCPSupport
  ) -> Bool {
    !isKeyboardDisabled && isEnabled(override: override, volumeSupport: writtenRegister)
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
