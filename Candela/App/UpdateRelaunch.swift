import Foundation
import Observation
import Sparkle

/// Sparkle's "Install and Relaunch" brings a menu-bar app back with no window,
/// which looks like an update that never happened. The exiting process marks
/// the relaunch on disk; the next launch consumes the mark and opens About.
enum UpdateRelaunch {
  static let defaultsKey = "openSettingsAfterUpdateRelaunch"
  static let previousVersionKey = "versionBeforeUpdateRelaunch"

  static func mark(in defaults: UserDefaults = .standard, version: String = AppInfo.version) {
    defaults.set(version, forKey: previousVersionKey)
    defaults.set(true, forKey: defaultsKey)
  }

  static func consume(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.bool(forKey: defaultsKey) else { return false }
    defaults.removeObject(forKey: defaultsKey)
    defaults.removeObject(forKey: previousVersionKey)
    return true
  }
}

/// Sparkle calls the hook on the main thread right before it terminates the
/// app for the relaunch; everything else stays Sparkle's default.
final class UpdateRelaunchDelegate: NSObject, SPUUpdaterDelegate {
  func updaterWillRelaunchApplication(_: SPUUpdater) {
    UpdateRelaunch.mark()
  }
}

/// Session-only feedback; consuming the relaunch mark prevents later launches
/// or Settings visits from celebrating the same update again.
@MainActor @Observable
final class UpdateCompletionState {
  struct Notice: Identifiable, Equatable {
    let id = UUID()
    let version: String
  }

  private(set) var notice: Notice?

  func consumeRelaunch(
    in defaults: UserDefaults = .standard, version: String = AppInfo.version
  ) -> Bool {
    let previous = defaults.string(forKey: UpdateRelaunch.previousVersionKey)
    guard UpdateRelaunch.consume(in: defaults) else { return false }
    // Sparkle's hook precedes installation. An aborted update may leave the
    // mark behind, so only a changed, known version earns success feedback.
    if let previous, !previous.isEmpty, previous != "?",
       !version.isEmpty, version != "?", previous != version {
      notice = Notice(version: version)
    }
    return true
  }

  func dismiss(_ id: UUID) {
    guard notice?.id == id else { return }
    notice = nil
  }

  func dismissAfterDelay(_ id: UUID, delay: Duration = .seconds(8)) async {
    do {
      try await Task.sleep(for: delay)
      try Task.checkCancellation()
      dismiss(id)
    } catch {
      // Closing or changing pages cancels the view's task.
    }
  }
}
