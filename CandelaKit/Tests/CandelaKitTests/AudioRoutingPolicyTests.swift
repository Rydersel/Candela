import Testing
@testable import CandelaKit

@Suite("Audio routing policy")
struct AudioRoutingPolicyTests {
  // MARK: - Name normalization

  @Test func normalizationDropsTheDuplicateSuffixAndKeepsDigits() {
    #expect(AudioRoutingPolicy.normalizedName("MAG 341C (2)") == "MAG341C")
    #expect(AudioRoutingPolicy.normalizedName("MAG341C") == "MAG341C")
    #expect(AudioRoutingPolicy.normalizedName("LG UltraFine 27") == "LGUltraFine27")
    #expect(AudioRoutingPolicy.normalizedName("") == "")
  }

  /// Only an all-digit group is a counter: "(left)" and "(right)" are two devices.
  @Test func aParenthesizedWordIsPartOfTheNameAndOnlyACounterIsDropped() {
    #expect(AudioRoutingPolicy.normalizedName("Desk (left)") == "Deskleft")
    #expect(AudioRoutingPolicy.normalizedName("Desk (right)") == "Deskright")
    #expect(
      AudioRoutingPolicy.normalizedName("Desk (left)")
        != AudioRoutingPolicy.normalizedName("Desk (right)")
    )
    #expect(!AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "Desk (left)", rawDisplayName: "Desk (right)", nameOverride: ""
    ))
    // Mixed contents are not a counter either.
    #expect(AudioRoutingPolicy.normalizedName("Studio (2b)") == "Studio2b")
    #expect(AudioRoutingPolicy.normalizedName("Studio ()") == "Studio")
    // CoreAudio's counter is ASCII; `isNumber` alone would drop Eastern Arabic
    // digits too.
    #expect(AudioRoutingPolicy.normalizedName("Desk (٢)") == "Desk٢")
    #expect(
      AudioRoutingPolicy.normalizedName("Desk (٢)")
        != AudioRoutingPolicy.normalizedName("Desk (٣)")
    )
  }

  /// A bare trailing number is part of the model name.
  @Test func aBareTrailingNumberIsPartOfTheModelName() {
    #expect(AudioRoutingPolicy.normalizedName("UltraFine 27") == "UltraFine27")
    #expect(AudioRoutingPolicy.normalizedName("UltraFine 32") == "UltraFine32")
    #expect(!AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "UltraFine 27", rawDisplayName: "UltraFine 32", nameOverride: ""
    ))
  }

  /// The old digit strip turned every "MAG n41C" into "MAGC".
  @Test func sameFamilyPanelsDoNotCollide() {
    #expect(AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "MAG 341C (2)", rawDisplayName: "MAG341C", nameOverride: ""
    ))
    #expect(!AudioRoutingPolicy.displayMatchesDevice(
      deviceName: "MAG 271C", rawDisplayName: "MAG 341C", nameOverride: ""
    ))
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
      deviceName: "USB DAC (2)", rawDisplayName: "MAG341C", nameOverride: "USB DAC"
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
    // Matching is exact on normalized forms, so a display whose audio device carries
    // an extra word reports no sink...
    #expect(!AudioRoutingPolicy.displayHasAudioSink(
      rawDisplayName: "MAG 341C", nameOverride: "", outputDeviceNames: sinks
    ))
    // ...and `audioDeviceNameOverride` is the documented way out.
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

  // MARK: - Tap rule (fork updateMediaKeyTap)

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

  /// The dead-key case: watching a key the tap consumes while no display can act on it
  /// takes the press away from macOS too, so the whole family goes silent. Every mode
  /// releases the keys at a zero count.
  @Test func nothingActionableReleasesTheKeysInEveryMode() {
    for mode in [MultiKeyboardVolume.mouse, .allScreens, .audioDeviceNameMatching] {
      #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
        mode: mode, ddcDisplaysExist: true, actionableDisplayCount: 0,
        defaultOutput: ddcOnlyDevice
      ), "\(mode)")
    }
  }

  /// The count is of displays a press would act on, not displays present: one that can
  /// act keeps the family armed, which preserves the per-display swallow for the rest.
  @Test func oneActionableDisplayIsEnoughToKeepTheKeysWatched() {
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .allScreens, ddcDisplaysExist: true, actionableDisplayCount: 1,
      defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func noDefaultOutputKeepsTheKeysWatched() {
    // Fork parity: the key-removal block sits inside `if let defaultAudioDevice`. With
    // no output device there is no system volume for a released key to move anyway.
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, actionableDisplayCount: 0, defaultOutput: nil
    ))
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, actionableDisplayCount: 0,
      defaultOutput: nil
    ))
  }
}
