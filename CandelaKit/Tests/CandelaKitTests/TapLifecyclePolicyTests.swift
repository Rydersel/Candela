import Testing
@testable import CandelaKit

@Suite("Media-key tap lifecycle")
struct TapLifecyclePolicyTests {
  private let brightness: Set<MediaKey> = [.brightnessUp, .brightnessDown]
  private let everything: Set<MediaKey> = [
    .brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute,
  ]

  @Test func watchingNothingAndStillWatchingNothingDoesNothing() {
    #expect(TapLifecyclePolicy.action(previous: [], next: [], grantHeld: true) == .nothing)
  }

  @Test func theFirstWatchedKeyStartsTheTap() {
    #expect(TapLifecyclePolicy.action(previous: [], next: brightness, grantHeld: true) == .start)
    #expect(TapLifecyclePolicy.action(previous: [], next: [.mute], grantHeld: true) == .start)
  }

  @Test func losingTheLastWatchedKeyStopsTheTap() {
    #expect(TapLifecyclePolicy.action(previous: brightness, next: [], grantHeld: true) == .stop)
    #expect(TapLifecyclePolicy.action(previous: everything, next: [], grantHeld: true) == .stop)
  }

  /// Equal sets included: the flag for the alternate brightness keys rides the
  /// same config and reaches the tap only through a reconfigure.
  @Test func aTapThatStaysUpIsReconfigured() {
    #expect(
      TapLifecyclePolicy.action(previous: brightness, next: everything, grantHeld: true)
        == .reconfigure)
    #expect(
      TapLifecyclePolicy.action(previous: brightness, next: brightness, grantHeld: true)
        == .reconfigure)
    #expect(
      TapLifecyclePolicy.action(previous: everything, next: [.mute], grantHeld: true)
        == .reconfigure)
  }

  @Test func nothingStartsWithoutTheGrant() {
    #expect(TapLifecyclePolicy.action(previous: [], next: brightness, grantHeld: false) == .nothing)
    #expect(TapLifecyclePolicy.action(previous: nil, next: brightness, grantHeld: false) == .nothing)
    #expect(
      TapLifecyclePolicy.action(previous: brightness, next: everything, grantHeld: false)
        == .nothing)
    #expect(
      TapLifecyclePolicy.action(previous: brightness, next: [], grantHeld: false) == .nothing)
  }

  /// No armed set at all is a tap that could not be built, not a tap watching
  /// nothing, and this path is not the one that can fix it.
  @Test func aTapThatNeverArmedIsNotRestartedFromHere() {
    #expect(TapLifecyclePolicy.action(previous: nil, next: brightness, grantHeld: true) == .nothing)
    #expect(TapLifecyclePolicy.action(previous: nil, next: [], grantHeld: true) == .nothing)
  }
}
