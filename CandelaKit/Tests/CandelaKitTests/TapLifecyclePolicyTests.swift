import Testing
@testable import CandelaKit

@Suite("Media-key tap lifecycle")
struct TapLifecyclePolicyTests {
  private let brightness: Set<MediaKey> = [.brightnessUp, .brightnessDown]
  private let everything: Set<MediaKey> = [
    .brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute,
  ]

  /// The ordinary rig: the grant is held and the tap can run. A cell that is
  /// about either of those says so.
  private func action(
    previous: Set<MediaKey>?,
    next: Set<MediaKey>,
    grantHeld: Bool = true,
    permanentlyUnavailable: Bool = false
  ) -> TapLifecycleAction {
    TapLifecyclePolicy.action(
      previous: previous, next: next,
      grantHeld: grantHeld, permanentlyUnavailable: permanentlyUnavailable)
  }

  @Test func watchingNothingAndStillWatchingNothingDoesNothing() {
    #expect(action(previous: [], next: []) == .nothing)
  }

  @Test func theFirstWatchedKeyStartsTheTap() {
    #expect(action(previous: [], next: brightness) == .start)
    #expect(action(previous: [], next: [.mute]) == .start)
  }

  @Test func losingTheLastWatchedKeyStopsTheTap() {
    #expect(action(previous: brightness, next: []) == .stop)
    #expect(action(previous: everything, next: []) == .stop)
  }

  /// Equal sets included: the flag for the alternate brightness keys rides the
  /// same config and reaches the tap only through a reconfigure.
  @Test func aTapThatStaysUpIsReconfigured() {
    #expect(action(previous: brightness, next: everything) == .reconfigure)
    #expect(action(previous: brightness, next: brightness) == .reconfigure)
    #expect(action(previous: everything, next: [.mute]) == .reconfigure)
  }

  @Test func nothingStartsWithoutTheGrant() {
    #expect(action(previous: [], next: brightness, grantHeld: false) == .nothing)
    #expect(action(previous: nil, next: brightness, grantHeld: false) == .nothing)
    #expect(action(previous: brightness, next: everything, grantHeld: false) == .nothing)
    #expect(action(previous: brightness, next: [], grantHeld: false) == .nothing)
  }

  /// A nil armed set is usually a start that failed for something a later one need
  /// not hit, so the next edge that wants keys tries again.
  @Test func aTapThatFailedToArmIsRetriedOnTheNextEdge() {
    #expect(action(previous: nil, next: brightness) == .start)
    #expect(action(previous: nil, next: [.mute]) == .start)
    // Still nothing to watch, so still nothing to build.
    #expect(action(previous: nil, next: []) == .nothing)
  }

  /// The one failure a retry cannot fix; without the latch every reconfigure and
  /// menu close would retry and re-log, forever.
  @Test func aPermanentlyUnavailableTapIsNeverRetried() {
    #expect(action(previous: nil, next: brightness, permanentlyUnavailable: true) == .nothing)
    #expect(action(previous: [], next: brightness, permanentlyUnavailable: true) == .nothing)
    #expect(action(previous: nil, next: [], permanentlyUnavailable: true) == .nothing)
    // The app cannot reach this pairing: the latch is set only where a start
    // failed, and that state records no watched set. Answered anyway.
    #expect(
      action(previous: brightness, next: everything, permanentlyUnavailable: true) == .nothing)
  }
}
