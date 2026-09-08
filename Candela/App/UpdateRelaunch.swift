import Foundation
import Sparkle

/// Sparkle's "Install and Relaunch" brings a menu-bar app back with no window,
/// which looks like an update that never happened. The exiting process marks
/// the relaunch on disk; the next launch consumes the mark and opens About.
enum UpdateRelaunch {
  static let defaultsKey = "openSettingsAfterUpdateRelaunch"

  static func mark(in defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: defaultsKey)
  }

  static func consume(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.bool(forKey: defaultsKey) else { return false }
    defaults.removeObject(forKey: defaultsKey)
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
