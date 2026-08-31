import CandelaKit
import CoreGraphics
import Foundation
import os

/// `WindowListing` over `CGWindowListCopyWindowInfo`, the permission-free half
/// of the telemetry. It reports geometry and owning application only, never a
/// window title (OC18), so the degraded no-Screen-Recording mode still
/// attributes exposure to an app.
///
/// **Coordinate spaces, the one thing that is silently wrong if it is wrong.**
/// `kCGWindowBounds` is in the GLOBAL window-server space: one origin for every
/// display, top-left, y increasing DOWNWARDS. That is not `NSScreen.frame`,
/// which is bottom-left and would put every window on the wrong half of the
/// panel. `PanelSpaceTransform` wants display-local coordinates, so the
/// display's global origin is subtracted here; `CGDisplayBounds` reports in that
/// same flipped space, which is why it is the right thing to subtract.
///
/// The origin is read fresh on every call: a rearrangement in Displays settings
/// moves a non-primary display's origin without rebuilding anything here.
struct CGWindowListSource: WindowListing {
  /// A live handle, not persisted state: display IDs are reassigned across a
  /// replug, so the coordinator re-creates this on reconfiguration and nothing
  /// here is keyed by the ID.
  let displayID: CGDirectDisplayID

  init(displayID: CGDirectDisplayID) {
    self.displayID = displayID
  }

  func onScreenWindows() -> [WindowSnapshot] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return []
    }

    let ourPID = ProcessInfo.processInfo.processIdentifier
    let displayOrigin = CGDisplayBounds(displayID).origin

    logFieldAvailabilityOnce(info, ourPID: ourPID)

    return info.compactMap { entry in
      snapshot(from: entry, excludingPID: ourPID, relativeTo: displayOrigin)
    }
  }

  /// Once per launch: does the window server hand us owner names without a
  /// Screen Recording grant? The whole permission-free half of OLED care rests
  /// on yes, and it is platform behaviour we do not control, so this is
  /// permanent telemetry rather than a debug switch.
  ///
  /// **Read it only from an `open`-launched instance.** TCC attributes a capture
  /// check to the RESPONSIBLE process, so running the executable from a shell
  /// inherits the terminal's grant and reports `preflight=true` for a build whose
  /// own grant is revoked [MEASURED 2026-08-07, same bundle both ways].
  private func logFieldAvailabilityOnce(_ info: [[String: Any]], ourPID: Int32) {
    let first = Self.diagnosticLogged.withLock { logged -> Bool in
      if logged { return false }
      logged = true
      return true
    }
    guard first else { return }

    // Counted before `snapshot` filters, which drops a window that has no owner
    // name; counting after would report 100% by construction.
    var foreign = 0, named = 0, bounded = 0
    for entry in info {
      guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        pid != ourPID
      else { continue }
      foreign += 1
      if entry[kCGWindowOwnerName as String] as? String != nil { named += 1 }
      if entry[kCGWindowBounds as String] != nil { bounded += 1 }
    }

    Self.log.notice(
      """
      window-list field availability: screenRecordingGranted=\
      \(CGPreflightScreenCaptureAccess(), privacy: .public) \
      foreign=\(foreign, privacy: .public) \
      withOwnerName=\(named, privacy: .public) \
      withBounds=\(bounded, privacy: .public)
      """)
  }

  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  /// `OSAllocatedUnfairLock` rather than a `nonisolated(unsafe)` flag: the
  /// protocol method is not actor-isolated, and one source per display means
  /// concurrent first calls are possible.
  private static let diagnosticLogged = OSAllocatedUnfairLock(initialState: false)

  /// Windows outside this display are deliberately kept: the caller decides what
  /// intersects, and `PanelSpaceTransform` clips anything off-display to zero.
  private func snapshot(
    from entry: [String: Any], excludingPID ourPID: Int32, relativeTo displayOrigin: CGPoint
  ) -> WindowSnapshot? {
    guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
      return nil
    }
    // Our dim overlays are ordinary on-screen windows. Left in, they read as a
    // full-screen region owned by Candela covering the panel: the
    // measures-its-own-effect failure OC16 prevents, by way of the window list.
    guard ownerPID != ourPID else { return nil }

    guard let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
      let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
      let globalBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    else { return nil }

    // No owner name means no attribution. Dropping the window costs the cell to
    // whatever is behind it; inventing a label would put a fabricated app name
    // in the health view.
    guard let ownerName = entry[kCGWindowOwnerName as String] as? String, !ownerName.isEmpty else {
      return nil
    }

    let localBounds = globalBounds.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)

    return WindowSnapshot(
      windowID: windowID, ownerPID: ownerPID, ownerName: ownerName,
      bounds: localBounds, layer: layer)
  }
}
