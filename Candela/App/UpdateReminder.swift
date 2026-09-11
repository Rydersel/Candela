import Foundation
import Observation
import OSLog
import Sparkle

/// What a scheduled update leaves behind for the menu-bar panel to say out loud.
/// Pure and observable so the delegate below stays a thin adapter: `SUAppcastItem`
/// and `SPUUserUpdateState` cannot be constructed in a test.
@MainActor @Observable
final class UpdateReminderState {
  struct Marker: Equatable {
    let version: String
  }

  private(set) var marker: Marker?

  /// The marker as it stood when the current menu open began, and the only one
  /// the panel renders.
  ///
  /// Content that appears inside an already-open `NSMenu` grows it and clips the
  /// footer off the bottom. What was measured is the keep-awake caption, which did
  /// exactly that [MEASURED 2026-08-19]; the update row is layout-bearing the same
  /// way, so reaching it is an inference, not a second measurement.
  ///
  /// Sparkle's scheduled check runs on a timer unrelated to menu tracking, so
  /// without a freeze the row could arrive mid-open. A marker that arrives after
  /// the freeze waits for the next open, and Sparkle keeps the update either way.
  private(set) var markerAtOpen: Marker?

  /// Copies the live marker into the frozen one, so the row cannot arrive or
  /// leave for the life of one open.
  ///
  /// Called from `menuWillOpen`, which AppKit posts BEFORE the menu is displayed,
  /// so the value the panel renders is settled before anything is on screen; an
  /// `onAppear` snapshot could not manage that. It does not order this write
  /// against `NSMenu` sizing the item view, so whether the first open after a
  /// marker arrives lays out at the new size is a rig check, not a guarantee.
  func freezeForMenuOpen() {
    markerAtOpen = marker
  }

  /// Every transition is logged because the panel is the only surface that shows
  /// this and no script can drive the panel. `.info` rather than `.debug`, since
  /// `log show` does not persist debug.
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "updates")

  /// `handledByStandardDriver` is deliberately not consulted. If Sparkle ever
  /// shows a scheduled update itself, that alert went up behind whatever is
  /// key, which is precisely when a marker is still the right announcement.
  func willShowUpdate(version: String, userInitiated: Bool, handledByStandardDriver _: Bool) {
    // A manual check brings its own alert forward, so a marker there would
    // announce a second time something already on screen.
    guard !userInitiated else { return }
    marker = Marker(version: version)
    Self.log.info("update.reminder marker=set version=\(version, privacy: .public)")
  }

  func didReceiveUserAttention() {
    clear(reason: "attention")
  }

  func willFinishSession() {
    clear(reason: "sessionFinished")
  }

  /// Never conditional on anything: a marker that outlives its update session
  /// is the failure mode this state is built against.
  private func clear(reason: String) {
    marker = nil
    Self.log.info("update.reminder marker=cleared reason=\(reason, privacy: .public)")
  }
}

/// Turns Sparkle's gentle-reminder callbacks into the state above. Sparkle holds
/// its user-driver delegate weakly, so `UpdaterModel` owns this.
///
/// `SPUStandardUserDriverDelegate` is the one protocol in this header set not
/// annotated `NS_SWIFT_UI_ACTOR`, so its requirements import as nonisolated even
/// though the standard user driver calling them is main-actor: the
/// `@preconcurrency` conformance takes the runtime check rather than asserting an
/// isolation the header never declared.
@MainActor
final class UpdateReminderDelegate: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
  private let reminder: UpdateReminderState

  init(reminder: UpdateReminderState) {
    self.reminder = reminder
    super.init()
  }

  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// False unconditionally: a scheduled update never takes the screen here.
  /// Sparkle's own example returns `immediateFocus` instead, but Candela is
  /// `LSUIElement` with no window to focus into, so that alert opens behind
  /// whatever is key, which is the defect this row replaces. The header is
  /// explicit that this is never called for a user-initiated check, so Check for
  /// Updates is untouched.
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _: SUAppcastItem, andInImmediateFocus _: Bool
  ) -> Bool {
    false
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    reminder.willShowUpdate(
      version: update.displayVersionString,
      userInitiated: state.userInitiated,
      handledByStandardDriver: handleShowingUpdate)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate _: SUAppcastItem) {
    reminder.didReceiveUserAttention()
  }

  func standardUserDriverWillFinishUpdateSession() {
    reminder.willFinishSession()
  }
}
