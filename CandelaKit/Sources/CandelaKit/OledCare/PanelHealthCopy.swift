import Foundation

/// Pure copy derivations for the health surfaces.
///
/// One formatter per quantity. These lived as private statics in two views with
/// no test target, and the two grew **different** formatters for the same
/// number: 0.4 hours read "0.4 hours" in one and "24 minutes" one click away.
///
/// Returns `String`, not `LocalizedStringKey`, which is why this can live in Kit
/// at all: `OledCareCopy` stays in the app target because it returns the latter
/// and CandelaKit cannot import SwiftUI.
public enum PanelHealthCopy {

  /// A duration in hours, for any surface showing accumulated time.
  ///
  /// Minutes below the hour, one decimal below ten, whole hours above. The
  /// sub-hour case is the load-bearing one: a freshly enrolled display otherwise
  /// reads zero for its whole first hour, which looks like a stuck counter.
  ///
  /// `zeroPhrase` is the one legitimate difference between call sites. A
  /// leaderboard row that does not exist yet says "none yet"; a display's
  /// lifetime hours line says "0 hours", where the number is the subject.
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
  /// Nil rather than a placeholder glyph when there is no number: the caller
  /// decides whether to write words or drop the row, and an em dash standing in
  /// for a missing value is unreadable to VoiceOver.
  public static func multiple(_ relative: Double) -> String? {
    guard relative.isFinite, relative > 0 else { return nil }
    return String(format: "%.1f×", relative)
  }

  /// Where a cell sits on the glass, in thirds, named.
  ///
  /// Deliberately coarse: "column 17" on a 3440-wide panel is false precision,
  /// while "toward the top, right of centre" is something someone can go and
  /// look at. Takes the grid dimensions rather than reading `PanelGrid` directly
  /// so a grid change cannot silently re-map the thirds.
  public static func region(
    cell index: Int, cols: Int = PanelGrid.cols, rows: Int = PanelGrid.rows
  ) -> String? {
    guard cols > 0, rows > 0, index >= 0, index < cols * rows else { return nil }
    let col = index % cols
    let row = index / cols
    let vertical = ["toward the top", "across the middle", "toward the bottom"][
      min(2, row * 3 / rows)]
    let horizontal = ["on the left", "in the center", "on the right"][
      min(2, col * 3 / cols)]
    return "\(vertical), \(horizontal)"
  }
}
