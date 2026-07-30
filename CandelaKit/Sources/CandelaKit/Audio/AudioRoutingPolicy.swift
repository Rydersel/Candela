//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

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

  /// The fork's tap rule (updateMediaKeyTap): watch volume keys only when DDC
  /// displays exist AND NOT (name-matching mode with zero matches) AND NOT
  /// (any other mode with a default output that sets its own volume). No
  /// default output → keys stay watched (the fork's removal block sits inside
  /// `if let defaultAudioDevice`).
  public static func shouldWatchVolumeKeys(
    mode: MultiKeyboardVolume,
    ddcDisplaysExist: Bool,
    matchingDisplayCount: Int,
    defaultOutput: AudioOutputDevice?
  ) -> Bool {
    guard ddcDisplaysExist else { return false }
    guard let defaultOutput else { return true }
    if mode == .audioDeviceNameMatching {
      return matchingDisplayCount > 0
    }
    return !defaultOutput.canSetOwnVolume
  }
}
