import Foundation
import Testing
@testable import CandelaKit

/// The report card's title has to be true of the card it titles.
///
/// It was the fixed string "Arrangement not changed" over every `.report`
/// presentation, including the two branches that only exist because the machine
/// moved — so the surface built to report "a success that was not achieved" was
/// itself reporting a state the machine was demonstrably not in.
@Suite("Arrangement report subject")
struct ArrangementReportSubjectTests {
  private let error = DisplayConfigError(cgErrorCode: 1000)

  /// The refusals. Nothing was staged in any of them, which is the one thing
  /// "Arrangement not changed" is allowed to be said about.
  @Test func aCardWithNothingAppliedReportsNothingChanged() {
    #expect(ArrangementReportSubject.of(
      hasRecoverableLayout: false, restoreNotice: nil
    ) == .nothingChanged)
  }

  /// Every restore notice OTHER than `.failed` is a refusal: the layout was
  /// declined rather than attempted, so nothing moved.
  @Test(arguments: [
    ArrangementReapplyNotice.ambiguousIdentity(["a"]),
    .setDiffers(missing: ["a"], extra: ["b"]),
    .layoutNoLongerFits([.overlap(1, 2)]),
    .savedForDifferentGeometry(["a"]),
  ])
  func aDeclinedRestoreReportsNothingChanged(notice: ArrangementReapplyNotice) {
    #expect(ArrangementReportSubject.of(
      hasRecoverableLayout: false, restoreNotice: notice
    ) == .nothingChanged)
  }

  /// The uncertain branch. `apply(restored:)` reports `.failed` both for a plan
  /// it could not express (nothing staged) and for the #53 post-commit check
  /// (CoreGraphics committed a layout of its own choosing) — so this must claim
  /// neither, and in particular must not claim "not changed".
  @Test func aFailedRestoreIsItsOwnSubjectAndNotNothingChanged() {
    let subject = ArrangementReportSubject.of(
      hasRecoverableLayout: false, restoreNotice: .failed(error)
    )
    #expect(subject == .restoreFailed)
    #expect(subject != .nothingChanged)
  }

  /// The known divergence. `noteRecoverableLayout` fires only after comparing
  /// the live layout against the one from before the apply, so a recoverable
  /// layout means the machine moved — the branch whose own caption reads "The
  /// displays did not end up where they were asked to go".
  @Test func aRecoverableLayoutReportsADivergence() {
    #expect(ArrangementReportSubject.of(
      hasRecoverableLayout: true, restoreNotice: nil
    ) == .diverged)
  }

  /// A card can carry both facts, and the title has to be true of both. The
  /// known divergence is the stronger claim and wins.
  @Test func aKnownDivergenceOutranksAFailedRestore() {
    #expect(ArrangementReportSubject.of(
      hasRecoverableLayout: true, restoreNotice: .failed(error)
    ) == .diverged)
  }

  /// …and outranks a declined restore too, which would otherwise pull the title
  /// back to "nothing changed" over a machine that had moved.
  @Test func aKnownDivergenceOutranksADeclinedRestore() {
    #expect(ArrangementReportSubject.of(
      hasRecoverableLayout: true, restoreNotice: .setDiffers(missing: ["a"], extra: [])
    ) == .diverged)
  }
}
