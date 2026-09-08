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

  /// Geometry through `matchesGeometry`, never `ioModeID`. The id is positional,
  /// and a display can be running a duplicate the enumeration collapsed (42 such
  /// buckets on the Dell), so equal geometry under two different ids is the same
  /// achieved state and an id compare would report a false miss.
  ///
  /// A nil `achieved` is unhonoured rather than a separate answer: a mode that
  /// cannot be read is not a mode that landed, and every caller does the same
  /// thing with either.
  static func verdict(requested: DisplayMode, achieved: DisplayMode?) -> Verdict {
    guard let achieved, achieved.matchesGeometry(of: requested) else { return .unhonoured }
    return .honoured
  }
}
