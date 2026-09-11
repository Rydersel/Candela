import CandelaKit
import SwiftUI

/// What the stale-layout notice offers besides "OK", derived from state rather
/// than decided in a view body. Plain values rather than the coordinator, so a
/// test reaches these rules with no view standing up behind them.
struct RestoreNoticeActions {
  let notice: ArrangementReapplyNotice
  /// The remember setting. With it off the coordinator's save is a no-op, so the
  /// button would be one that cannot work.
  let isRestoringLayout: Bool
  /// An unanswered display change, or one still in flight. One flag for both: the
  /// remedy is the same and nobody can tell them apart.
  let isBusy: Bool
  /// Who refused the last save. A refusal raises no report card, so the caption
  /// is the whole of its feedback.
  let refusedBy: ReconfigurationClaimant?

  var offersSave: Bool { notice.isResolvedBySavingCurrentLayout && isRestoringLayout }
  var showsBusyCaption: Bool { offersSave && isBusy }

  /// The one sentence under the buttons, or nothing.
  ///
  /// Busy outranks a refusal where both apply: an outstanding preview refuses the
  /// save and greys the button, and the sentence has to describe the control the
  /// reader is looking at. Silent where there is no save to explain.
  var caption: LocalizedStringKey? {
    if showsBusyCaption { return ArrangementCopy.saveThisLayoutBusy }
    guard offersSave, let refusedBy else { return nil }
    return ReconfigurationCopy.blocked(by: refusedBy)
  }
}
