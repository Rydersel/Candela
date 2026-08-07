import CandelaKit
import SwiftUI

/// The CoreGraphics code stays out of the sentence and goes in a tooltip — it
/// is diagnostic, and belongs nowhere near text someone reads while working out
/// what happened to their screen. Only a `.failed` notice has one: for a
/// substitution or an unavailable mode there is no error, and an empty tooltip
/// would suggest there was.
///
/// All that survives of `DisplayModeSection`, whose two halves were re-homed:
/// the pickers and the remember row became the hub's Display section (Task 13),
/// and its disclosure over the full mode list became `AllModesPage` (Task 14).
struct ReapplyDiagnostic: ViewModifier {
  let notice: ModeReapplyNotice

  @ViewBuilder func body(content: Content) -> some View {
    if case let .failed(error) = notice {
      content.help("CoreGraphics error \(error.cgErrorCode)")
    } else {
      content
    }
  }
}
