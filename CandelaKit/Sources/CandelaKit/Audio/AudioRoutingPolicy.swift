/// Pure volume-key routing decisions: no CoreAudio here, so every branch
/// is unit-testable.
public enum AudioRoutingPolicy {
  /// Drops CoreAudio's duplicate-counter suffix, then whitespace and parens, so
  /// "MAG 341C (2)" matches "MAG341C".
  ///
  /// Diverges from the fork's DisplayManager.normalizedName on purpose: the fork
  /// also stripped every digit, which collapsed "MAG 341C" and "MAG 271C" to the
  /// same string and routed one panel's volume keys at the other. A trailing
  /// number that is not parenthesized is part of the model name for the same
  /// reason: "UltraFine 27" and "UltraFine 32" are two displays.
  ///
  /// The parenthesized group goes only when its contents are ALL digits, which
  /// is the shape CoreAudio's counter has. People name devices "Desk (left)" and
  /// "Desk (right)", and a rule that dropped every trailing group made those one
  /// device and routed the keys at whichever answered first.
  public static func normalizedName(_ name: String) -> String {
    var head = Substring(name)
    while head.last == " " { head = head.dropLast() }
    if head.last == ")", let open = head.lastIndex(of: "(") {
      let contents = head[head.index(after: open) ..< head.index(before: head.endIndex)]
      // `isASCII` as well as `isNumber`: the latter is true of every numeric
      // scalar Unicode knows, so a device named with Eastern Arabic or fullwidth
      // digits would lose its group and collide with its neighbour.
      if !contents.isEmpty, contents.allSatisfy({ $0.isASCII && $0.isNumber }) {
        head = head[head.startIndex ..< open]
      }
    }
    return String(head.filter { !"() ".contains($0) })
  }

  /// Per-display match against the default output device; `audioDeviceNameOverride`
  /// wins over the raw display name when non-empty. Recomputed at key time and never
  /// cached at tap-arm time, which is where the fork went stale.
  public static func displayMatchesDevice(
    deviceName: String, rawDisplayName: String, nameOverride: String
  ) -> Bool {
    let target = nameOverride.isEmpty ? rawDisplayName : nameOverride
    return normalizedName(target) == normalizedName(deviceName)
  }

  /// Whether the display enumerates as an audio output device, so its EDID declares
  /// a sink. NOT a claim that the panel has speakers: a display with only a headphone
  /// jack declares audio too, and DDC volume drives that jack.
  ///
  /// No production callers since volume-slider gating moved to the DDC capabilities
  /// string; kept with its tests.
  public static func displayHasAudioSink(
    rawDisplayName: String, nameOverride: String, outputDeviceNames: [String]
  ) -> Bool {
    let target = normalizedName(nameOverride.isEmpty ? rawDisplayName : nameOverride)
    // A name that normalizes away entirely would match every same-shaped device
    // name, so refuse rather than guess.
    guard !target.isEmpty else { return false }
    return outputDeviceNames.contains { normalizedName($0) == target }
  }

  /// Fork parity: watch the volume keys only when DDC displays exist, some display
  /// can act on the press, and (outside name-matching mode) the default output
  /// cannot set its own volume. With no default output the keys stay watched.
  ///
  /// `actionableDisplayCount` is how many displays the press could ACT on: the
  /// caller's candidate pool for `mode`, minus everything the capability verdict
  /// (`VolumeSliderPolicy`) or the engine's availability switch rules out. Not "how
  /// many displays are attached". A keyboard-disabled display still counts, because
  /// its press is swallowed on purpose, and one display that can act keeps the
  /// keys armed for the whole rig. A watched key is CONSUMED by the tap, so watching
  /// one while nothing can act takes the press away from macOS too and the key does
  /// nothing at all.
  ///
  /// The no-default-output branch sits AHEAD of the count on purpose: in
  /// name-matching mode the pool is derived from the default output, so it is empty
  /// whenever there is none, and a count read first would release the keys in that
  /// mode 100% of the time. With no output device there is no system volume for a
  /// released key to move either.
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
