import CandelaKit
import CoreGraphics
import Foundation

/// `WindowListing` over `CGWindowListCopyWindowInfo` — the permission-free half
/// of W3b's telemetry. It reports geometry and owning application only; it
/// never reads a window title (OC18), so the degraded no-Screen-Recording mode
/// still attributes exposure to an app.
///
/// **Coordinate spaces — the one thing that is silently wrong if it is wrong.**
/// `kCGWindowBounds` is in the *global* window-server space: one origin shared
/// by every display, top-left, y increasing **downwards**. That is NOT
/// `NSScreen.frame`, which is bottom-left with y upwards and would put every
/// window on the wrong half of the panel. `PanelSpaceTransform` wants
/// **display-local** coordinates (origin at the display's own top-left, same y
/// direction), so the display's global origin is subtracted here.
/// `CGDisplayBounds` reports in that same flipped global space, which is why it
/// is the right thing to subtract and `NSScreen` is not.
///
/// The origin is read fresh on every call rather than captured at init: a
/// rearrangement in Displays settings moves every non-primary display's origin
/// without any object here being rebuilt.
struct CGWindowListSource: WindowListing {
  /// A live handle, not persisted state — display IDs are reassigned across a
  /// replug (CLAUDE.md §3), so the coordinator owns re-creating this on
  /// reconfiguration and nothing here is keyed by the ID.
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

    return info.compactMap { entry in
      snapshot(from: entry, excludingPID: ourPID, relativeTo: displayOrigin)
    }
  }

  /// Windows outside this display are deliberately kept: the caller decides
  /// what intersects (Task 8), and `PanelSpaceTransform` clips anything that
  /// lands off-display to zero coverage regardless.
  private func snapshot(
    from entry: [String: Any], excludingPID ourPID: Int32, relativeTo displayOrigin: CGPoint
  ) -> WindowSnapshot? {
    guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
      return nil
    }
    // Our dim overlays are ordinary on-screen windows. Left in, they read as a
    // stationary full-screen region owned by Candela covering the whole panel —
    // the measures-its-own-effect failure OC16 exists to prevent, arriving
    // through the window list instead of the capture.
    guard ownerPID != ourPID else { return nil }

    guard let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
      let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
      let globalBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
    else { return nil }

    // No owner name means no attribution is possible. Dropping the window is
    // honest; inventing a label would put a fabricated app name in the health
    // view. It costs the cell to whatever is behind, which is rare and visible
    // as a wrong app rather than as a made-up one.
    guard let ownerName = entry[kCGWindowOwnerName as String] as? String, !ownerName.isEmpty else {
      return nil
    }

    let localBounds = globalBounds.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)

    return WindowSnapshot(
      windowID: windowID, ownerPID: ownerPID, ownerName: ownerName,
      bounds: localBounds, layer: layer)
  }
}
