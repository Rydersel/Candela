import Testing
@testable import CandelaKit

/// The decision behind the one DDC write Candela makes unattended at launch
/// without the user asking for a restore. Four of the five cases are silences,
/// and a hardware pass cannot tell a silence that held from a pass that never
/// ran, so they are pinned here.
@Suite("Interrupted dim recovery")
struct InterruptedDimRecoveryTests {
  @Test func aSurvivingMarkerWithAStoredValueIsReasserted() {
    #expect(
      InterruptedDimRecovery.action(
        markerSurvived: true, dimIsLive: false, hasStoredValue: true, isSafeMode: false
      ) == .reassert)
  }

  /// Safe mode sends no unattended DDC, and consuming the marker would spend the
  /// evidence the next normal launch needs.
  @Test func safeModeLeavesTheMarkerForTheNextNormalLaunch() {
    #expect(
      InterruptedDimRecovery.action(
        markerSurvived: true, dimIsLive: false, hasStoredValue: true, isSafeMode: true
      ) == .leave)
  }

  /// This process owns the dim, so re-asserting would flash a locked screen to
  /// full brightness.
  @Test func aLiveDimIsNotAnInterruptedOne() {
    #expect(
      InterruptedDimRecovery.action(
        markerSurvived: true, dimIsLive: true, hasStoredValue: true, isSafeMode: false
      ) == .leave)
  }

  /// The restore pass never writes the assumed 1.0 default over an empty store,
  /// and a marker nobody can act on must not be re-evaluated every launch.
  @Test func aDisplayWithNothingStoredIsConsumedWithoutAWrite() {
    #expect(
      InterruptedDimRecovery.action(
        markerSurvived: true, dimIsLive: false, hasStoredValue: false, isSafeMode: false
      ) == .clearOnly)
  }

  /// Over the whole state space rather than one case: "no spurious write" is a
  /// silence, and a single case cannot prove it.
  @Test func noMarkerIsNoWorkInEveryOtherCombination() {
    let flags = [false, true]
    #expect(flags.allSatisfy { live in flags.allSatisfy { stored in flags.allSatisfy { safe in
      InterruptedDimRecovery.action(
        markerSurvived: false, dimIsLive: live, hasStoredValue: stored, isSafeMode: safe
      ) == .leave
    } } })
  }
}
