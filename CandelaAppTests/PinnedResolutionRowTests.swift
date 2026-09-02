import CandelaKit
import Testing

// The second line under "Remember this resolution".
//
// Three states, and the middle one is the reason this is a named function
// rather than an `if let` in `body`: "remembering is on and nothing is pinned"
// is reachable by Forget and by a turn-on whose seeding pin declined, and a
// state that renders nothing is indistinguishable from the toggle failing.
@Suite("Pinned resolution row") @MainActor
struct PinnedResolutionRowTests {
  private static let pin = DisplayModeDescriptor(
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175
  )

  @Test func nothingIsShownWhileRememberingIsOff() {
    #expect(RememberResolutionRow.pinnedRow(isRemembering: false, stored: nil) == .hidden)
  }

  /// A pin left behind by a previous opt-in stays out of sight while the
  /// toggle is off: it is not applied in that state, and a row describing a
  /// restore that will not happen is worse than no row.
  @Test func aLeftoverPinIsNotShownWhileRememberingIsOff() {
    #expect(RememberResolutionRow.pinnedRow(isRemembering: false, stored: Self.pin) == .hidden)
  }

  @Test func rememberingWithNothingPinnedSaysSo() {
    #expect(RememberResolutionRow.pinnedRow(isRemembering: true, stored: nil) == .empty)
  }

  @Test func aPinnedModeIsNamed() {
    #expect(RememberResolutionRow.pinnedRow(isRemembering: true, stored: Self.pin) == .pinned(Self.pin))
  }
}
