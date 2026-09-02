import CandelaKit
import CoreFoundation
import Foundation
import os

/// The one place system chrome settings are touched (only the pane's
/// toggles call the writes; enrollment suggests auto-hide and never applies it).
/// The Dock path is a pref write plus a visible Dock restart, not the spike's
/// Apple Events route, which would demand an Automation consent that must not
/// be added.
///
/// Both reads synchronize their domain first. `ChromeAutoHideController` assigns
/// from a read-back after every write and polls while the pane is open, so a
/// stale read would snap the pane's switch back over a write that landed, or
/// hide a change made in System Settings. [MEASURED 2026-08-06 with a throwaway
/// key in both domains: an in-process `CFPreferencesSetValue` reads back
/// immediately even before a synchronize, and an external `defaults write` was
/// visible on the next read; the synchronize is the guarantee rather than the
/// observed behaviour.]
///
/// A read-back proves the preference holds the requested value and nothing
/// more. It says nothing about whether the system ADOPTED it: the Dock leg
/// writes a pref another process owns and then asks that process to restart, and
/// a `killall` that never reached a running Dock leaves the pref right and the
/// screen unchanged. That gap is logged here as the `killall` exit status and is
/// still unmeasured. The menu-bar leg has the same gap and closes it by
/// broadcasting the change, which is why that post is part of the write rather
/// than an optional extra. See `broadcastMenuBarHidingChanged`.
@MainActor
final class SystemChromeWriter: ChromeWriting {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  private static let menuBarKey = "_HIHideMenuBar" as CFString
  private static let fullScreenVisibleKey = "AppleMenuBarVisibleInFullscreen" as CFString
  private static let controlCenterDomain = "com.apple.controlcenter" as CFString
  private static let autoHideOptionKey = "AutoHideMenuBarOption" as CFString
  private static let dockDomain = "com.apple.dock" as CFString
  private static let dockKey = "autohide" as CFString

  /// macOS 26 stores menu-bar auto-hiding in TWO places, so `_HIHideMenuBar`
  /// alone is not the setting. [MEASURED 2026-08-07, driving System Settings by
  /// accessibility and diffing every domain it touched.]
  ///
  /// - `_HIHideMenuBar` (global domain, Bool) is the EFFECTIVE bit: apps see it
  ///   immediately as `NSScreen.visibleFrame` gaining or losing the bar's 30 pt.
  /// - `com.apple.controlcenter AutoHideMenuBarOption` (Int) is macOS's own
  ///   RECORD of the four-way choice, read and written by the Control Center
  ///   pane: 0 Always, 1 On Desktop Only, 2 In Full Screen Only, 3 Never.
  ///
  /// Writing only the first leaves the two disagreeing: System Settings went on
  /// showing "Always" over a menu bar Candela had just restored, and any later
  /// macOS path that re-derives the effective bit from its own record hides the
  /// bar again with Candela's switch reading OFF. The writer owns both halves so
  /// they cannot drift.
  ///
  /// All of that was measured on macOS 26 alone. Support also covers 14 and 15,
  /// neither of them measurable here, so the code FEATURE-DETECTS rather than
  /// switching on the version: a wrong boundary degrades to the legacy-only
  /// behaviour every source agrees on instead of writing a guess into
  /// undocumented schema.
  ///
  /// Sourced, not measured here: on 14.4 a full `defaults read` diff across the
  /// picker changed ONLY `_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen`
  /// (Apple Support Communities thread 255637558), and 15.5 is managed through
  /// the `.GlobalPreferences` payload with those same two keys and no Control
  /// Center domain (alansiu.net, "Managing hiding the menu bar in macOS").
  ///
  /// Assumed and unverifiable here: that the Control Center key is genuinely
  /// ABSENT on 14 and 15 rather than merely undocumented (both sources argue
  /// from absence), and that wherever it IS present it carries the macOS 26
  /// meaning. Feature detection reads presence as participation, so an older
  /// macOS keeping this key with DIFFERENT semantics would be misread.
  ///
  /// Two published claims are recorded as CONTRADICTED so nobody re-imports them
  /// from the same search: that the four values run 0 Never through 3 Always
  /// (measured here as the reverse, and two other repos agree with the
  /// measurement), and that `_HIHideMenuBar` is "silently ignored on Ventura and
  /// later" (measured false; the bar follows it in both directions as long as
  /// the change is broadcast).
  private static func fullScreenHidesMenuBar() -> Bool {
    !((CFPreferencesCopyValue(fullScreenVisibleKey, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false)
  }

  /// Whatever the Control Center domain holds, undecoded. Absent and
  /// present-but-unrecognised stay distinguishable: the policy needs to tell
  /// "this macOS does not use the key" from "something wrote a shape we do not
  /// understand".
  private static func controlCenterRecord() -> ControlCenterMenuBarRecord {
    CFPreferencesAppSynchronize(controlCenterDomain)
    guard let value = CFPreferencesCopyValue(autoHideOptionKey, controlCenterDomain,
                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    else { return .absent }
    guard let option = value as? Int else { return .unreadable }
    return .option(option)
  }

  private static var osMajorVersion: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }

  /// Hidden if EITHER half says hidden, and the record only gets a vote where
  /// the write leg would also touch it. `MenuBarAutoHidePolicy` owns that for
  /// both legs so they cannot diverge: a read that consulted a record the write
  /// skips would report ON, refuse to clear it, and strand the switch.
  func readMenuBarAutoHide() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    let effective = (CFPreferencesCopyValue(Self.menuBarKey, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
    return MenuBarAutoHidePolicy.isMenuBarHidden(
      effectiveBit: effective, record: Self.controlCenterRecord(), osMajorVersion: Self.osMajorVersion)
  }

  /// The system does not watch these preferences. It reconciles when it is
  /// told to, and this is what tells it.
  ///
  /// [MEASURED 2026-08-07, both directions, against a screenshot of the real
  /// menu bar on an external display.] Writing both keys and stopping there
  /// changed NOTHING on screen: the bar stayed visible over `hide=true` and
  /// stayed gone over `hide=false`, and it snapped to the written value the
  /// instant this notification was posted. Posting it when nothing changed is a
  /// no-op, so it is safe to send unconditionally.
  ///
  /// Undocumented, like `AutoHideMenuBarOption` itself: if a macOS update ever
  /// breaks the menu bar switch, check this first.
  private static let menuBarHidingChangedNotification =
    Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")

  /// An earlier experiment missed this because its only oracle was `NSScreen`'s menu-bar
  /// inset, which no longer moves at all on a secondary display (measured 0.0
  /// with the bar plainly visible). Screenshot the bar; do not trust the inset.
  private static func broadcastMenuBarHidingChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      menuBarHidingChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
  }

  /// The branch and the ordering live in `MenuBarAutoHidePolicy.writeEffects`,
  /// so the broadcast cannot be stranded on a leg that returned early: the loop
  /// has no legs to return from.
  func writeMenuBarAutoHide(_ on: Bool) {
    let record = Self.controlCenterRecord()
    if !MenuBarAutoHidePolicy.writesControlCenterRecord(record, osMajorVersion: Self.osMajorVersion) {
      Self.log.debug("control centre menu bar record not in use on this macOS; writing the global key only")
    }
    // The full-screen half is never ours to choose, so it is read and
    // preserved. Unset means the macOS default: hidden in full screen.
    let effects = MenuBarAutoHidePolicy.writeEffects(
      desktopHides: on, fullScreenHides: Self.fullScreenHidesMenuBar(),
      record: record, osMajorVersion: Self.osMajorVersion)
    for effect in effects {
      switch effect {
      case .setEffectiveBit(let hidden):
        CFPreferencesSetValue(Self.menuBarKey, hidden ? kCFBooleanTrue : kCFBooleanFalse,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
      case .setControlCenterRecord(let option):
        CFPreferencesSetValue(Self.autoHideOptionKey, option as CFNumber,
                              Self.controlCenterDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.controlCenterDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
      case .broadcastChange:
        Self.broadcastMenuBarHidingChanged()
      }
    }
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
    // only evidence the restart was even requested of a running Dock (nonzero
    // means the pref landed and nothing adopted it), and it is collected in a
    // `terminationHandler`, NOT by waiting: `waitUntilExit()` here measured
    // [MEASURED 2026-08-06: 66 ms] of blocked main actor per toggle, and a
    // blocking child-process wait on the main actor is the shape behind the
    // Accessibility freeze. Nothing needs the wait: the read-back that follows
    // verifies the PREF, never the Dock's adoption of it.
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
