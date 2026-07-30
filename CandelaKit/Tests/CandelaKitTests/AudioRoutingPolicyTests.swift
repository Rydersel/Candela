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

  // MARK: - Tap rule (fork updateMediaKeyTap; D4)

  private let selfVolumeDevice = AudioOutputDevice(id: 1, name: "MacBook Pro Speakers", canSetOwnVolume: true)
  private let ddcOnlyDevice = AudioOutputDevice(id: 2, name: "MAG341C", canSetOwnVolume: false)

  @Test func noDisplaysMeansNoWatching() {
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: false, matchingDisplayCount: 0, defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func selfVolumeOutputReleasesTheKeysOutsideNameMatching() {
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, matchingDisplayCount: 0, defaultOutput: selfVolumeDevice
    ))
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .allScreens, ddcDisplaysExist: true, matchingDisplayCount: 0, defaultOutput: selfVolumeDevice
    ))
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, matchingDisplayCount: 0, defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func nameMatchingWatchesOnlyWhenSomeDisplayMatches() {
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, matchingDisplayCount: 1,
      defaultOutput: selfVolumeDevice // matching mode ignores canSetOwnVolume (fork parity)
    ))
    #expect(!AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, matchingDisplayCount: 0,
      defaultOutput: ddcOnlyDevice
    ))
  }

  @Test func noDefaultOutputKeepsTheKeysWatched() {
    // Fork parity: the key-removal block sits inside `if let defaultAudioDevice`.
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .mouse, ddcDisplaysExist: true, matchingDisplayCount: 0, defaultOutput: nil
    ))
    #expect(AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: .audioDeviceNameMatching, ddcDisplaysExist: true, matchingDisplayCount: 0, defaultOutput: nil
    ))
  }
}
