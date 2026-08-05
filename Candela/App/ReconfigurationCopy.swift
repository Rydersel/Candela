import CandelaKit
import SwiftUI

/// The one sentence every claimant says when the four-way gate refuses it
/// (AR12), written once so four features cannot end up spelling one statement
/// four ways.
///
/// It names the feature that is holding the gate rather than saying "busy":
/// "finish that first" is actionable, and the user's next move is on a different
/// display from the one they just clicked.
///
/// Deliberately silent about WHY the holder still holds it. The gate is taken
/// for the length of the reconfiguration itself as well as for an unanswered
/// preview — a mirror break holds it with nothing outstanding at all — so a
/// sentence promising a question waiting somewhere would be false for part of
/// the window it is shown in.
enum ReconfigurationCopy {
  /// No `default:` arm — a fifth claimant is a compile error here rather than a
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
