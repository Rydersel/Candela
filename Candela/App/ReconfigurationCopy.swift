import CandelaKit
import SwiftUI

/// The one sentence every claimant says when the gate refuses it,
/// written once so the features cannot spell one statement several ways.
///
/// Names the feature holding the gate rather than saying "busy": "finish that
/// first" is actionable.
///
/// Deliberately silent about WHY the holder still holds it. The gate is taken
/// for the reconfiguration itself as well as for an unanswered preview (a mirror
/// break holds it with nothing outstanding), so a sentence promising a question
/// waiting somewhere would be false for part of the window it is shown in.
enum ReconfigurationCopy {
  /// No `default:` arm: a new claimant is a compile error here rather than a
  /// generic sentence.
  static func blocked(by claimant: ReconfigurationClaimant) -> LocalizedStringKey {
    switch claimant {
    case .displayModes: "Candela is already changing a display's resolution. Finish that first."
    case .mirroring: "Candela is already changing mirroring. Finish that first."
    case .rotation: "Candela is already rotating a display. Finish that first."
    case .arrangement: "Candela is already changing the display arrangement. Finish that first."
    }
  }
}
