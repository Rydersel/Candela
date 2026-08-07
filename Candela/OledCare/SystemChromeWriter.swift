import CandelaKit
import CoreFoundation
import Foundation

/// The one place system chrome settings are touched (OC10: only the pane's
/// toggles call the writes; enrollment suggests auto-hide and never applies
/// it). The Dock path is a pref write plus a visible Dock restart — NOT the
/// spike's Apple Events route, which would demand the Automation consent W3a
/// must not add.
///
/// Both reads synchronize their domain first. `ChromeAutoHideController`
/// assigns from a read-back after every write and polls `refresh()` while the
/// pane is open, so a read serving a stale value would either snap the pane's
/// switch back over a write that landed, or hide a change made in System
/// Settings. [MEASURED 2026-08-06 with a throwaway key in both domains: an
/// in-process `CFPreferencesSetValue` reads back immediately even before a
/// synchronize, and an external `defaults write` was visible on the next read;
/// the synchronize is the guarantee rather than the observed behaviour.]
@MainActor
final class SystemChromeWriter: ChromeWriting {
  private static let menuBarKey = "_HIHideMenuBar" as CFString
  private static let dockDomain = "com.apple.dock" as CFString
  private static let dockKey = "autohide" as CFString

  func readMenuBarAutoHide() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return (CFPreferencesCopyValue(Self.menuBarKey, kCFPreferencesAnyApplication,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
  }

  func writeMenuBarAutoHide(_ on: Bool) {
    CFPreferencesSetValue(Self.menuBarKey, on ? kCFBooleanTrue : kCFBooleanFalse,
                          kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    // Hardware-verification item: confirm live apply matches the spike's
    // `defaults write` evidence (NSScreen visibleFrame inset changes).
  }

  func readDockAutoHide() -> Bool {
    CFPreferencesAppSynchronize(Self.dockDomain)
    return (CFPreferencesCopyValue(Self.dockKey, Self.dockDomain,
                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
  }

  func writeDockAutoHide(_ on: Bool) {
    CFPreferencesSetValue(Self.dockKey, on ? kCFBooleanTrue : kCFBooleanFalse,
                          Self.dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(Self.dockDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["Dock"]
    try? process.run()   // the Dock restarts visibly; the pane copy says so
  }
}
