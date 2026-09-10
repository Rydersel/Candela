import Foundation
import Testing

/// The delegate is a thin adapter over this state, because `SUAppcastItem` and
/// `SPUUserUpdateState` cannot be constructed outside Sparkle. Each test plays the
/// callback sequence the adapter would forward.
@Suite("Update reminder")
@MainActor
struct UpdateReminderTests {
  @Test func aScheduledUpdateRaisesAMarkerNamingTheVersion() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    #expect(state.marker == UpdateReminderState.Marker(version: "1.0.4"))
  }

  /// The manual check brings its own alert forward, so a marker there would
  /// announce a second time something already on screen.
  @Test func aUserInitiatedCheckRaisesNoMarker() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: true, handledByStandardDriver: true)
    #expect(state.marker == nil)
  }

  @Test func attentionClearsTheMarker() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.didReceiveUserAttention()
    #expect(state.marker == nil)
  }

  /// The error and quit-without-looking paths: the session ends with no
  /// attention ever paid, and the row still has to go away.
  @Test func aFinishedSessionClearsTheMarkerEvenWithoutAttention() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.willFinishSession()
    #expect(state.marker == nil)
  }

  /// A marker left behind after the user declined is the failure this state is
  /// built against.
  @Test func aDeclinedUpdateClearsTheMarker() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.didReceiveUserAttention()
    #expect(state.marker == nil)
    state.willFinishSession()
    #expect(state.marker == nil)
  }

  @Test func aSecondScheduledUpdateReplacesTheFirstMarker() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.willFinishSession()
    // Sparkle handling the alert itself still earns a marker: that alert went
    // up behind whatever is key, which is exactly when the row is wanted.
    state.willShowUpdate(version: "1.0.5", userInitiated: false, handledByStandardDriver: true)
    #expect(state.marker?.version == "1.0.5")
  }

  @Test func clearingTwiceIsHarmless() {
    let state = UpdateReminderState()
    state.willFinishSession()
    state.willFinishSession()
    #expect(state.marker == nil)
  }

  // MARK: - Frozen for one menu open

  /// The panel renders the row from the frozen marker, never the live one, so
  /// what the freeze copies is what a given open can show.
  @Test func freezingCopiesTheLiveMarker() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.freezeForMenuOpen()
    #expect(state.markerAtOpen == UpdateReminderState.Marker(version: "1.0.4"))
  }

  /// Sparkle's scheduled check runs on a timer with no relation to menu tracking,
  /// so a marker can arrive while the menu is open. It waits: a row appearing
  /// inside an open menu grows the panel under the cursor.
  @Test func aMarkerArrivingAfterTheFreezeWaitsForTheNextOpen() {
    let state = UpdateReminderState()
    state.freezeForMenuOpen()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    #expect(state.markerAtOpen == nil)
    state.freezeForMenuOpen()
    #expect(state.markerAtOpen == UpdateReminderState.Marker(version: "1.0.4"))
  }

  /// The other direction, and the one that shrinks the panel rather than growing
  /// it: a session finishing mid-open leaves the row where it is.
  @Test func aMarkerClearedAfterTheFreezeStaysUntilTheNextOpen() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.freezeForMenuOpen()
    state.willFinishSession()
    #expect(state.markerAtOpen == UpdateReminderState.Marker(version: "1.0.4"))
    state.freezeForMenuOpen()
    #expect(state.markerAtOpen == nil)
  }

  /// The freeze is a copy in both directions, not an accumulator: with no marker
  /// live, the next open shows no row.
  @Test func freezingWithNoMarkerClearsTheFrozenValue() {
    let state = UpdateReminderState()
    state.willShowUpdate(version: "1.0.4", userInitiated: false, handledByStandardDriver: false)
    state.freezeForMenuOpen()
    state.didReceiveUserAttention()
    state.freezeForMenuOpen()
    #expect(state.markerAtOpen == nil)
  }
}
