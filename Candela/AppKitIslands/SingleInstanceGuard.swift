import AppKit
import CandelaKit
import os

/// Quits this copy of the app when another one is already running.
///
/// The rule it enforces: only one process drives DDC at a time. The bus has no
/// arbitration, so two copies talking to the same panel interleave their VCP
/// traffic, and from outside that looks like a monitor ignoring commands rather
/// than two apps fighting. The case that actually happens is a debug build
/// launched beside the release copy in /Applications.
///
/// The `--vd-engage` helper needs no exclusion, and the reason is ordering:
/// `VirtualDisplayHost.handleEngageHelperInvocation` runs first in `main()` and
/// exits on every path carrying the flag. A live helper also implies the live
/// parent that spawned it, which is exactly the copy this guard exists to find.
@MainActor
enum SingleInstanceGuard {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "lifecycle")

  static func terminateIfAlreadyRunning() {
    // No identifier means no enumeration, and an uncertain answer launches.
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      // A copy already on its way out is not a second DDC writer. The window this
      // covers is narrow, only the gap between the array snapshot above and this
      // read. What makes the Sparkle relaunch safe is ORDERING, not this filter:
      // the installer waits for the outgoing copy to terminate before launching
      // the replacement.
      .filter { !$0.isTerminated }
      .map {
        SingleInstancePolicy.Instance(
          processIdentifier: $0.processIdentifier, bundlePath: $0.bundleURL?.path,
          launchDate: $0.launchDate
        )
      }
    let decision = SingleInstancePolicy.decide(
      running: running, ownProcessIdentifier: NSRunningApplication.current.processIdentifier,
      ownLaunchDate: NSRunningApplication.current.launchDate
    )
    guard case let .terminate(runningBundlePath) = decision else { return }

    // Logged before the modal and exited after it, so neither depends on the alert
    // coming up. An alert nobody saw is cosmetic; a second DDC writer is not.
    log.error("""
    another copy is already running from \
    \(runningBundlePath ?? "an unreadable location", privacy: .public); quitting \
    \(Bundle.main.bundlePath, privacy: .public)
    """)
    presentAlreadyRunningAlert(runningBundlePath: runningBundlePath)
    exit(0)
  }

  private static func presentAlreadyRunningAlert(runningBundlePath: String?) {
    // The application object comes first because `NSAlert` loads its panel out of
    // the shared application, `NSApp` is still nil this early in `main()`, and
    // touching `NSApplication.shared` is what builds it. Adding a button can make
    // the alert load that panel, so the alert must not get there first. The proceed
    // path creates no application object at all: `NSRunningApplication` is a
    // LaunchServices process wrapper rather than a UI object. The activation policy
    // comes from LSUIElement in the Info.plist.
    let app = NSApplication.shared

    let alert = NSAlert()
    alert.messageText = "\(AppInfo.productName) is already running"
    // Both paths, so the person can tell a stray build from the installed copy.
    // Two identical paths mean the same bundle was launched twice.
    alert.informativeText = """
    Another copy is running from:
    \(runningBundlePath ?? "an unknown location")

    This copy will quit:
    \(Bundle.main.bundlePath)

    Only one copy of \(AppInfo.productName) can control your displays at a time.
    """
    alert.addButton(withTitle: "Quit")
    // Activating first for the same reason the safe-mode notice does: an accessory
    // app's launch-time modal otherwise opens behind whatever is frontmost.
    app.activate()
    alert.runModal()
  }
}
