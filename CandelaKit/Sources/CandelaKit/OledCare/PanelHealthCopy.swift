import Foundation

/// Pure copy derivations for the health surfaces.
///
/// These lived as private statics in `PanelHealthView` and `OledCarePane`,
/// where there is no test target ("a pane that needs a test has too much in
/// it"), and the two files independently grew **different** formatters for the
/// same quantity: 0.4 hours read "0.4 hours" in the pane's hours line and "24
/// minutes" in the leaderboard one click away, and zero read "0 hours" against
/// "none yet". Both carried a comment explaining why their own choice avoided a
/// stuck-counter reading, and neither knew about the other.
///
/// Returns `String`, not `LocalizedStringKey`, which is why this can live in
/// Kit at all: `OledCareCopy` stays in the app target precisely because it
/// returns the latter and CandelaKit cannot import SwiftUI.
public enum PanelHealthCopy {

  /// A duration in hours, for any surface showing accumulated time.
  ///
  /// Minutes below the hour, one decimal below ten, whole hours above. The
  /// sub-hour case is the load-bearing one: a freshly enrolled display reads
  /// zero for its whole first hour otherwise, which looks like a counter that
  /// is not running, and that misreading is what both original formatters were
  /// written around from opposite ends.
  ///
  /// `zeroPhrase` is the one legitimate difference between the two call sites.
  /// A leaderboard row that does not exist yet says "none yet"; a display's
  /// lifetime hours line says "0 hours", because there the number itself is the
  /// subject of the sentence.
  public static func hours(_ hours: Double, zeroPhrase: String = "0 hours") -> String {
    guard hours.isFinite, hours > 0 else { return zeroPhrase }
    if hours < 1 {
      let minutes = Int((hours * 60).rounded())
      if minutes < 1 { return "under a minute" }
      return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    if hours < 10 { return String(format: "%.1f hours", hours) }
    let whole = Int(hours.rounded())
    return whole == 1 ? "1 hour" : "\(whole) hours"
  }

  /// A relative exposure figure, as a multiple of the panel mean.
  ///
  /// Answers nil rather than a placeholder glyph when there is no number: the
  /// caller decides whether to write words or drop the row, and an em dash
  /// standing in for a missing value violates §6 and is unreadable to VoiceOver
  /// besides.
  public static func multiple(_ relative: Double) -> String? {
    guard relative.isFinite, relative > 0 else { return nil }
    return String(format: "%.1f×", relative)
  }

  /// Where a cell sits on the glass, in thirds, named.
  ///
  /// Deliberately coarse. The grid is 24×10 over a 3440-wide panel, so "column
  /// 17" would be a false precision; "toward the top, right of centre" is what
  /// someone can go and look at. Takes the grid dimensions rather than reading
  /// `PanelGrid` directly so a grid change cannot silently re-map the thirds.
  public static func region(
    cell index: Int, cols: Int = PanelGrid.cols, rows: Int = PanelGrid.rows
  ) -> String? {
    guard cols > 0, rows > 0, index >= 0, index < cols * rows else { return nil }
    let col = index % cols
    let row = index / cols
    let vertical = ["toward the top", "across the middle", "toward the bottom"][
      min(2, row * 3 / rows)]
    let horizontal = ["on the left", "in the centre", "on the right"][
      min(2, col * 3 / cols)]
    return "\(vertical), \(horizontal)"
  }
}
