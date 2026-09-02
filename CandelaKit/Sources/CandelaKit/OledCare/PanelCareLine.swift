import Foundation

/// The caption the menu-bar panel puts under an external display's name:
///
///     OLED Care on · 178 h · hottest area 2.5×
///
/// A segment is dropped, never replaced, when its condition fails; why a
/// reading is missing belongs to the Health pane. Nil when nothing survives, so
/// the header keeps its one-line height.
public enum PanelCareLine {
  /// The separator the panel's size line already uses.
  public static let separator = " · "

  public static let enrolledSegment = "OLED Care on"

  /// - Parameters:
  ///   - enrolled: `DisplayPrefs.oledCareEnrolled` for the display.
  ///   - hours: lifetime panel hours; zero or non-finite drops the segment.
  ///   - summary: nil where the caller had no reason to read one. The hottest
  ///     segment needs `.measured` confidence, a figure, and enrollment, since
  ///     the Health pane leaves an un-enrolled display's history unstated.
  ///   - safeMode: hours only. The care loop never starts in a Safe Mode
  ///     session, so nothing produces "on" or a present-tense reading.
  public static func text(
    enrolled: Bool, hours: Double, summary: PanelHealthSummary?, safeMode: Bool
  ) -> String? {
    let hoursSegment = PanelHealthCopy.compactHours(hours)
    if safeMode { return hoursSegment }
    var segments: [String] = []
    if enrolled { segments.append(enrolledSegment) }
    if let hoursSegment { segments.append(hoursSegment) }
    if enrolled, let summary, summary.confidence == .measured,
      let relative = summary.hottestRelative,
      let multiple = PanelHealthCopy.multiple(relative)
    {
      // No "vs average" here: the Health card has the width for it, a panel
      // row with two segments ahead of it does not.
      segments.append("hottest area \(multiple)")
    }
    return segments.isEmpty ? nil : segments.joined(separator: separator)
  }
}
