import Foundation

/// A field is one flat luminance over the whole panel, so its booking is a
/// uniform grid; the coordinator adds it for the showing's elapsed seconds.
public enum CheckupExposureBooking {
  public static func panelGrid(luminance: Double) -> [Double] {
    Array(repeating: max(0, min(1, luminance)), count: PanelGrid.cellCount)
  }

  public static func id(startedAt: Date) -> String {
    "checkup-\(Int(startedAt.timeIntervalSince1970))"
  }
}
