import Foundation

/// The published mode path's post-commit verdict. `CGCompleteDisplayConfiguration`
/// has been measured returning `.success` over a request it did not honour, so
/// the mode read back decides, not the return code. Pure, so it tests without a
/// display. It answers what the desktop scans out, not how it reaches the glass:
/// a mode bound to the wrong wire timing reads clean here.
enum ModeApplyVerification {
  enum Verdict: Equatable {
    case honoured
    case unhonoured
  }

  /// Geometry via `matchesGeometry`, never `ioModeID`: the id is positional and
  /// the enumeration collapses duplicates (42 buckets on the Dell), so equal
  /// geometry under two ids is the same achieved state. A nil `achieved` is
  /// unhonoured: a mode that cannot be read is not one that landed. The
  /// half-hertz tolerance absorbs CoreGraphics' float noise (59.997 for 60) and
  /// so also calls NTSC 59.94 a 60; stored-mode matching makes the same trade.
  static func verdict(requested: DisplayMode, achieved: DisplayMode?) -> Verdict {
    guard let achieved, achieved.matchesGeometry(of: requested) else { return .unhonoured }
    return .honoured
  }
}
