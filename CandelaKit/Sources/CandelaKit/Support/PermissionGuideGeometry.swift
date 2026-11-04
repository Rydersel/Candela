import CoreGraphics
import Foundation

public enum PermissionGuideGeometry {
  /// Measured on the System Settings privacy list; the panel sits on the list edges.
  public static let listLeftInset: CGFloat = 269
  public static let listRightInset: CGFloat = 21
  public static let bottomInset: CGFloat = 10
  public static let rowOverhang: CGFloat = 8
  public static let panelHeight: CGFloat = 92

  /// Floor that rejects toolbar slivers and tooltips owned by the same process.
  private static let minimumWindowWidth: CGFloat = 300

  /// Matches on PID, never owner name: the name is localized.
  public static func settingsWindowBounds(windowList: [[String: Any]], settingsPID: pid_t?) -> CGRect? {
    guard let settingsPID else { return nil }
    for entry in windowList {
      guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid == settingsPID,
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
        let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        bounds.width > minimumWindowWidth
      else { continue }
      return bounds
    }
    return nil
  }

  /// Window-server bounds have a top-left origin; the returned frame is bottom-left (AppKit).
  public static func panelFrame(settingsWindowCG: CGRect, mainScreenHeight: CGFloat, panelHeight: CGFloat) -> CGRect {
    let x = settingsWindowCG.minX + listLeftInset - rowOverhang
    let width = settingsWindowCG.width - listLeftInset - listRightInset + rowOverhang * 2
    let y = (mainScreenHeight - settingsWindowCG.maxY) + bottomInset
    return CGRect(x: x, y: y, width: width, height: panelHeight)
  }
}
