import CandelaKit
import CoreFoundation
import Foundation
import os

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
///
/// **What that read-back does and does not prove.** It proves the preference
/// now holds the requested value. It says nothing about whether the system
/// ADOPTED it — the Dock leg in particular writes a pref another process owns
/// and then asks that process to restart, and a `killall` that never reached a
/// running Dock leaves the pref right and the screen unchanged. That gap is
/// logged here (the `killall` exit status) and is a hardware-checklist item
/// (spike §6a verified the Dock through System Events, and only *named* this
/// pref+killall fallback — it was never measured). The menu-bar leg needs no
/// such item: §6a proved live apply through this exact CFPreferences triple.
@MainActor
final class SystemChromeWriter: ChromeWriting {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  private static let menuBarKey = "_HIHideMenuBar" as CFString
  private static let fullScreenVisibleKey = "AppleMenuBarVisibleInFullscreen" as CFString
  private static let controlCenterDomain = "com.apple.controlcenter" as CFString
  private static let autoHideOptionKey = "AutoHideMenuBarOption" as CFString
  private static let dockDomain = "com.apple.dock" as CFString
  private static let dockKey = "autohide" as CFString

  /// macOS 26 stores menu-bar auto-hiding in TWO places and the spec's premise
  /// that `_HIHideMenuBar` alone IS the setting is wrong.
  /// [MEASURED 2026-08-07, driving System Settings by accessibility and diffing
  /// every domain it touched.]
  ///
  /// - `_HIHideMenuBar` (global domain, Bool) is the EFFECTIVE bit: apps see it
  ///   immediately as `NSScreen.visibleFrame` gaining or losing the bar's 30 pt,
  ///   which is the only oracle the S3 spike ever checked.
  /// - `com.apple.controlcenter AutoHideMenuBarOption` (Int) is macOS's own
  ///   RECORD of the four-way choice, and it is what the Control Center settings
  ///   pane reads and writes: 0 Always, 1 On Desktop Only, 2 In Full Screen
  ///   Only, 3 Never.
  ///
  /// Writing only the first leaves the two disagreeing: System Settings went on
  /// showing "Always" over a menu bar Candela had just restored, and any later
  /// macOS path that re-derives the effective bit from its own record hides the
  /// bar again with Candela's switch reading OFF. Two records of one setting
  /// kept in agreement by nothing is the strand; the writer owns both halves so
  /// they cannot drift.
  ///
  /// The full-screen half is never ours to choose, so it is read and preserved:
  /// the option is picked from the requested desktop value AND the user's
  /// existing full-screen preference. Unset means the macOS default, which
  /// hides the bar in full screen.
  private static func fullScreenHidesMenuBar() -> Bool {
    !((CFPreferencesCopyValue(fullScreenVisibleKey, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false)
  }

  /// True when the RECORD says the bar hides on the desktop. Nil when macOS has
  /// never written one, in which case there is nothing to reconcile against.
  private static func recordedMenuBarAutoHide() -> Bool? {
    CFPreferencesAppSynchronize(controlCenterDomain)
    guard let option = CFPreferencesCopyValue(autoHideOptionKey, controlCenterDomain,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Int
    else { return nil }
    return option == 0 || option == 1
  }

  /// Hidden if EITHER half says hidden. Deliberately the pessimistic read: the
  /// switch must be ON whenever anything is hiding the bar, because turning it
  /// off is the only in-app route back and a control that reads OFF over a
  /// hidden menu bar cannot be used to recover (D29 rule 3).
  func readMenuBarAutoHide() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    let effective = (CFPreferencesCopyValue(Self.menuBarKey, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
    return effective || (Self.recordedMenuBarAutoHide() ?? false)
  }

  func writeMenuBarAutoHide(_ on: Bool) {
    CFPreferencesSetValue(Self.menuBarKey, on ? kCFBooleanTrue : kCFBooleanFalse,
                          kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    // No restart and no notification for this half: spike §6a measured this
    // exact triple applying live (MAG menu-bar inset 0 -> 30 -> 0).
    let fullScreenHides = Self.fullScreenHidesMenuBar()
    let option: Int = on ? (fullScreenHides ? 0 : 1) : (fullScreenHides ? 2 : 3)
    CFPreferencesSetValue(Self.autoHideOptionKey, option as CFNumber,
                          Self.controlCenterDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(Self.controlCenterDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
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
    // The Dock restarts visibly; the pane copy says so. The exit status is the
    // only evidence the restart was even requested of a running Dock — nonzero
    // means the pref landed and nothing adopted it — but it is collected in a
    // `terminationHandler`, NOT by waiting: `waitUntilExit()` here measured
    // [MEASURED 2026-08-06: 66 ms] of blocked main actor per toggle, and a
    // blocking child-process wait on the main actor is the shape behind #59.
    // Nothing needs the wait to have finished — the read-back that follows
    // verifies the PREF, written above, and never the Dock's adoption of it.
    //
    // The handler runs off the main actor, so it touches nothing isolated: it
    // captures one `Logger` (Sendable) and reads the status off the `Process`
    // it is handed.
    let log = Self.log
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["Dock"]
    process.terminationHandler = { finished in
      guard finished.terminationStatus != 0 else { return }
      log.warning(
        "killall Dock exited \(finished.terminationStatus, privacy: .public); autohide pref written but the Dock may not have adopted it"
      )
    }
    do {
      try process.run()
    } catch {
      log.warning(
        "killall Dock could not launch: \(error.localizedDescription, privacy: .public); autohide pref written but the Dock has not adopted it"
      )
    }
  }
}
