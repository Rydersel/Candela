/// Pure volume-key routing decisions (D4/D8) — no CoreAudio here, so every
/// branch is unit-testable.
public enum AudioRoutingPolicy {
  /// Fork DisplayManager.normalizedName: strip parens, spaces, and digits, so
  /// "MAG 341C (2)" matches "MAG341C" and duplicate-counter suffixes vanish.
  public static func normalizedName(_ name: String) -> String {
    name.filter { !"() 0123456789".contains($0) }
  }

  /// Per-display match against the default output device. The per-display
  /// `audioDeviceNameOverride` wins over the raw display name when non-empty.
  /// Recomputed at key time, never cached at tap-arm time — fixes the fork's
  /// stale audioControlTargetDisplays cache (D4).
  public static func displayMatchesDevice(
    deviceName: String, rawDisplayName: String, nameOverride: String
  ) -> Bool {
    let target = nameOverride.isEmpty ? rawDisplayName : nameOverride
    return normalizedName(target) == normalizedName(deviceName)
  }

  /// Whether the display appears among the machine's audio output devices —
  /// i.e. whether its EDID declares an audio sink (speakers, or a headphone
  /// jack the panel drives).
  ///
  /// **Superseded, zero production callers.** Volume-slider gating now reads
  /// the DDC capabilities string (`CapabilityString` → `VolumeSliderPolicy`,
  /// D24); volume-KEY routing goes through `displayMatchesDevice`. Held in
  /// reserve, with its tests, for future audio features.
  ///
  /// Same normalized comparison and the same override precedence as
  /// `displayMatchesDevice`: a display whose audio device enumerates under an
  /// unrelated name is matched through `audioDeviceNameOverride`. An empty
  /// device list means no sink — the honest answer on a machine with no audio
  /// output at all.
  ///
  /// NOT a claim that the panel has speakers: a display with only a headphone
  /// jack declares audio too, and DDC volume genuinely drives that jack.
  public static func displayHasAudioSink(
    rawDisplayName: String, nameOverride: String, outputDeviceNames: [String]
  ) -> Bool {
    let target = normalizedName(nameOverride.isEmpty ? rawDisplayName : nameOverride)
    // A name that normalizes away entirely (all digits and parens) would
    // match every same-shaped device name — refuse rather than guess.
    guard !target.isEmpty else { return false }
    return outputDeviceNames.contains { normalizedName($0) == target }
  }

  /// The fork's tap rule (updateMediaKeyTap): watch volume keys only when DDC
  /// displays exist AND NOT (any mode with zero displays a press could act on)
  /// AND NOT (any mode other than name-matching with a default output that sets
  /// its own volume). No default output → keys stay watched (the fork's removal
  /// block sits inside `if let defaultAudioDevice`).
  ///
  /// `actionableDisplayCount` is how many displays the press could ACT on: the
  /// caller's own candidate pool for `mode`, filtered by everything that would
  /// make the press impossible on a display, which is the capability verdict
  /// (`VolumeSliderPolicy.armsVolumeKeys`/`armsMuteKey`) AND the engine's own
  /// availability switch for the register. What it leaves in is exactly what the
  /// executor would drop for a reason of its own: a keyboard-disabled display
  /// still counts, because its press is swallowed on purpose (R1). It is
  /// deliberately not "how many displays are attached". A watched key is CONSUMED
  /// by the tap, so watching it while nothing can act takes the press away from
  /// macOS too and the key does nothing at all, which is worse than either
  /// outcome the rule chooses between. One display that can act keeps the family
  /// armed for the whole rig, so a press aimed at a display that refuses is still
  /// swallowed by that display rather than sprayed at the others (R1).
  ///
  /// The no-default-output branch sits AHEAD of the count on purpose. It keeps
  /// fork parity, and it has to: in name-matching mode the pool is derived from
  /// the default output, so it is empty whenever there is none, and a count read
  /// before that branch would release the keys in that mode 100% of the time.
  /// With no output device there is also no system volume for a released key to
  /// move, so releasing would trade a dead key for a dead key.
  public static func shouldWatchVolumeKeys(
    mode: MultiKeyboardVolume,
    ddcDisplaysExist: Bool,
    actionableDisplayCount: Int,
    defaultOutput: AudioOutputDevice?
  ) -> Bool {
    guard ddcDisplaysExist else { return false }
    guard let defaultOutput else { return true }
    if mode == .audioDeviceNameMatching {
      return actionableDisplayCount > 0
    }
    return actionableDisplayCount > 0 && !defaultOutput.canSetOwnVolume
  }
}
