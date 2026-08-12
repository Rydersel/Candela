import Testing
@testable import CandelaKit

@Suite("Audio routing policy")
struct AudioRoutingPolicyTests {
  // MARK: - Name normalization (fork DisplayManager.normalizedName)

  @Test func normalizationStripsParensSpacesAndDigits() {
    #expect(AudioRoutingPolicy.normalizedName("MAG 341C (2)") == "MAGC")
    #expect(AudioRoutingPolicy.normalizedName("MAG341C") == "MAGC")
    #expect(AudioRoutingPolicy.normalizedName("LG UltraFine 27") == "LGUltraFine")
    #expect(AudioRoutingPolicy.normalizedName("") == "")
  }

  @Test func matchingComparesNormalizedForms() {
    #expect(AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "MAG 341C", rawDisplayName: "MAG341C (2)", nameOverride: ""
    ))
    #expect(!AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "MacBook Pro Speakers", rawDisplayName: "MAG341C", nameOverride: ""
    ))
  }

  @Test func overrideWinsOverTheRawDisplayName() {
    #expect(AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "USB DAC 2", rawDisplayName: "MAG341C", nameOverride: "USB DAC"
    ))
    // Empty override falls back to the raw name, not to "matches everything".
    #expect(!AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "USB DAC", rawDisplayName: "MAG341C", nameOverride: ""
    ))
  }

  // MARK: - Audio-sink detection (panel volume-slider gate)

  private let sinks = ["MacBook Pro Speakers", "MAG 341C OLED", "BlackHole 2ch"]

  @Test func displayWithAnEnumeratedOutputDeviceHasASink() {
    // Real pairing on the dev desk: CoreGraphics and CoreAudio both name the
    // panel "MAG 341C OLED", so the normalized forms are identical.
    #expect(AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG 341C OLED", nameOverride: "", outputDeviceNames: sinks
    ))
  }

  @Test func aSuffixMismatchNeedsTheOverride() {
    // Deliberate brittleness, inherited from `displayMatchesDevice`: matching
    // is exact on normalized forms, so a display whose audio device carries an
    // extra word reports NO sink...
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG 341C", nameOverride: "", outputDeviceNames: sinks
    ))
    // ...and `audioDeviceNameOverride` is the documented way out. This is the
    // reason detection alone is not the whole feature.
    #expect(AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG 341C", nameOverride: "MAG 341C OLED", outputDeviceNames: sinks
    ))
  }

  @Test func displayAbsentFromTheOutputListHasNoSink() {
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "LG UltraFine", nameOverride: "", outputDeviceNames: sinks
    ))
  }

  @Test func emptyOutputListMeansNoSink() {
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG341C", nameOverride: "", outputDeviceNames: []
    ))
  }

  @Test func overrideRedirectsSinkDetection() {
    // The panel enumerates under an unrelated device name.
    #expect(AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "LG UltraFine", nameOverride: "BlackHole 2ch", outputDeviceNames: sinks
    ))
    // ...and an override pointing at nothing is still a miss.
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG341C", nameOverride: "USB DAC", outputDeviceNames: sinks
    ))
  }

  @Test func nameThatNormalizesAwayNeverMatches() {
    // "(2)" normalizes to "" — without the guard it would match any device
    // name that also normalizes to empty, and report a sink that isn't there.
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "(2)", nameOverride: "", outputDeviceNames: ["(1)", "42"]
    ))
  }

  // MARK: - Tap rule (fork updateMediaKeyTap; D4)

  private let selfVolumeDevice = AudioOutputDevice(id: 1, name: "MacBook Pro Speakers", canSetOwnVolume: true)
  private let ddcOnlyDevice = AudioOutputDevice(id: 2, name: "MAG341C", canSetOwnVolume: false)

  @Test func noDisplaysMeansNoWatching() {
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: false, actionableDisplayCount: 1,
      defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func selfVolumeOutputReleasesTheKeysOutsideNameMatching() {
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: selfVolumeDevice
    ))
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .allScreens, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: selfVolumeDevice
    ))
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func nameMatchingWatchesOnlyWhenSomeDisplayMatches() {
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: selfVolumeDevice // matching mode ignores canSetOwnVolume (fork parity)
    ))
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, actionableDisplayCount: 0,
      defaultOutput: ddcOnlyDevice
    ))
  }

  /// The dead-key case. Watching a key the tap will consume while no display can
  /// act on it takes the press away from macOS as well, so the whole family goes
  /// silent. Every mode releases the keys when the count is zero, including the
  /// one whose default output cannot set its own volume.
  @Test func nothingActionableReleasesTheKeysInEveryMode() {
    for mode in [MultiKeyboardVolume.mouse, .allScreens, .audioDeviceNameMatching] {
      #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
        mode: mode, ddcDisplaysExist: true, actionableDisplayCount: 0,
        defaultOutput: ddcOnlyDevice
      ), "\(mode)")
    }
  }

  /// The count is a count of displays a press would ACT on, not of displays
  /// present: one that can act keeps the family armed for the whole rig, which is
  /// what preserves the per-display swallow (R1) for the ones that cannot.
  @Test func oneActionableDisplayIsEnoughToKeepTheKeysWatched() {
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .allScreens, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func noDefaultOutputKeepsTheKeysWatched() {
    // Fork parity: the key-removal block sits inside `if let defaultAudioDevice`.
    // Deliberately ahead of the actionable count, and it changes nothing a user
    // can feel: with no output device at all there is no system volume for a
    // released key to move, so releasing would trade a dead key for a dead key.
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, actionableDisplayCount: 0, defaultOutput: nil
    ))
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, actionableDisplayCount: 0,
      defaultOutput: nil
    ))
  }
}
