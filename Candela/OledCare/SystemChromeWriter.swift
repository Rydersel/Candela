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
/// pref+killall fallback: it was never measured). The menu-bar leg has the
/// same gap and closes it the same way: its preferences are inert until the
/// change is broadcast, so that post is part of the write rather than an
/// optional extra. See `broadcastMenuBarHidingChanged`.
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
  /// # What is measured, and what is assumed (#104)
  ///
  /// Everything above was measured on macOS 26, on ONE machine. Candela's
  /// support range is macOS 14, 15 and 26 (there is no 16 through 25: Apple
  /// renumbered after Sequoia), and the other two cannot be measured here. So
  /// the version-dependent parts are recorded once, here, and marked. The code
  /// FEATURE-DETECTS rather than switching on the version, so a wrong boundary
  /// below degrades to the legacy-only behaviour that every source agrees on
  /// instead of writing a guess into undocumented schema.
  ///
  /// SOURCED, not measured here:
  /// - macOS 14 (Sonoma): a user diffed a full `defaults read` between the
  ///   picker's "Always" and "Never" positions on 14.4 and found ONLY
  ///   `_HIHideMenuBar` and `AppleMenuBarVisibleInFullscreen` changing. No
  ///   Control Center key appears.
  ///   (Apple Support Communities thread 255637558.)
  /// - macOS 15 (Sequoia): a systems-management writeup dated 2025-06-30 says
  ///   the setting is managed on 15.5 through the `.GlobalPreferences` payload
  ///   with those same two keys, and never mentions a Control Center domain.
  ///   (alansiu.net, "Managing hiding the menu bar in macOS".)
  /// - macOS 26 (Tahoe): `AutoHideMenuBarOption` is in current use and is
  ///   described by another Swift utility as "the persistent source of truth
  ///   behind the four-way picker in System Settings" while `_HIHideMenuBar`
  ///   "drives the actual behavior". A dotfile repo annotates the key as
  ///   "macOS Tahoe uses AutoHideMenuBarOption in com.apple.controlcenter".
  ///   (github.com/ZingerLittleBee/AnyDoor, github.com/MyronL/dotfiles.)
  ///
  /// ASSUMED, and unverifiable on this machine:
  /// - That the Control Center key is genuinely ABSENT on 14 and 15 rather than
  ///   merely undocumented. Both sources above are arguments from absence.
  /// - That where the key IS present on any version, it carries the macOS 26
  ///   meaning. Feature detection treats presence as proof of participation, so
  ///   an older macOS that kept this key with DIFFERENT semantics would be
  ///   misread. Nothing available here can rule that out.
  /// - That the legacy key remains the effective bit on 14 and 15. Both sources
  ///   support it, and it is why that key is written unconditionally.
  ///
  /// Two published claims are recorded as CONTRADICTED, so nobody re-imports
  /// them from the same search:
  /// - One dotfile repo maps the four values in reverse (0 Never through
  ///   3 Always). Direct measurement here says 0 Always through 3 Never, and two
  ///   other repos agree with the measurement. Sources disagree about this
  ///   mapping, which is its own argument for never inventing a value.
  /// - Another claims `_HIHideMenuBar` is "silently ignored on Ventura and
  ///   later". Measured false here: the bar follows it in both directions, as
  ///   long as the change is broadcast. Both version sources above contradict
  ///   the claim too.
  ///
  /// AnyDoor's `AppleInterfaceMenuBarHidingChangedNotification` was recorded
  /// here as a documented alternative deliberately NOT adopted, on the strength
  /// of spike §6a's "applies live". That was wrong, and it is now the write's
  /// third step: AnyDoor's report that defaults alone get reverted matches what
  /// this machine does. The version caveats above cover only WHICH KEYS get
  /// written; the broadcast is unconditional, because no evidence anywhere
  /// suggests a version where the preferences apply on their own.
  ///
  /// Owed and impossible here: a pass on a macOS 14 or 15 machine or VM. The
  /// branches themselves are covered by `MenuBarAutoHidePolicy`'s Kit tests.
  private static func fullScreenHidesMenuBar() -> Bool {
    !((CFPreferencesCopyValue(fullScreenVisibleKey, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false)
  }

  /// Whatever the Control Center domain currently holds, undecoded. Absent and
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
  /// the write leg would also touch it. `MenuBarAutoHidePolicy` owns that
  /// decision for both legs precisely so they cannot diverge: a read that
  /// consulted a record the write skips would report ON, refuse to clear it,
  /// and strand the switch (D29 rule 3).
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
  /// instant this notification was posted, with no other action. Posting it
  /// when nothing changed is a no-op, so it is safe to send unconditionally.
  ///
  /// The name follows the HIToolbox convention shared with
  /// `AppleInterfaceThemeChangedNotification`. It is undocumented, like
  /// `AutoHideMenuBarOption` itself (#104): if a macOS update ever breaks the
  /// menu bar switch, check this first.
  private static let menuBarHidingChangedNotification =
    Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")

  /// Why the S3 spike missed it: §6a's only oracle was `NSScreen`'s menu-bar
  /// inset, read by a freshly launched process after a `defaults write`. That
  /// oracle no longer moves at all on a secondary display (measured 0.0 with
  /// the bar plainly visible), and the spike never looked at the screen, so
  /// "applies live" was a conclusion about a number rather than about the menu
  /// bar. Screenshot the bar; do not trust the inset.
  private static func broadcastMenuBarHidingChanged() {
    DistributedNotificationCenter.default().postNotificationName(
      menuBarHidingChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
  }

  /// Interprets the policy's effect sequence. The branch and the ordering live
  /// in `MenuBarAutoHidePolicy.writeEffects`, so the broadcast cannot be
  /// stranded on a leg that returned early: the loop has no legs to return from.
  func writeMenuBarAutoHide(_ on: Bool) {
    let record = Self.controlCenterRecord()
    if !MenuBarAutoHidePolicy.writesControlCenterRecord(record, osMajorVersion: Self.osMajorVersion) {
      Self.log.debug("control centre menu bar record not in use on this macOS; writing the global key only")
    }
    // The full-screen half is never ours to choose, so it is read and
    // preserved. Unset means the macOS default, which hides the bar in full
    // screen.
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
