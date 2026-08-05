import Foundation

/// What an arrangement report card is actually reporting — which is what has to
/// title it.
///
/// The card started with one fixed title, "Arrangement not changed", and two of
/// its branches are DIVERGENCE branches: the layout offered back after an apply
/// that moved the displays somewhere nobody asked for, and a restore that failed
/// the post-commit check (#53). It therefore rendered "Arrangement not changed"
/// directly above "The displays did not end up where they were asked to go" —
/// reporting a state the machine was demonstrably not in, on the one surface
/// built to report exactly that class of defect.
///
/// Three cases rather than two, because the middle one is genuinely UNCERTAIN
/// and must not be resolved by guessing. Pure and here rather than in the app
/// target so the precedence below has a test (D21).
public enum ArrangementReportSubject: Sendable, Equatable {
  /// Nothing was applied. A layout refused for overlapping or stranding a
  /// display (AR7), a claim refused by the gate (AR12), a `begin` that failed
  /// without moving anything, or a saved layout declined rather than attempted —
  /// an ambiguous identity, a different display set, origins that no longer tile.
  case nothingChanged

  /// A saved layout was attempted and did not come back.
  ///
  /// It claims nothing about where the displays ended up, deliberately:
  /// `ArrangementCoordinator.apply(restored:)` reports `.failed` both for a plan
  /// it could not express as a whole (nothing was staged) and for the #53
  /// post-commit check (CoreGraphics reported success and committed a layout of
  /// its own choosing), and the two are indistinguishable from here. "Not
  /// restored" is true of both; either stronger sentence is false of one.
  case restoreFailed

  /// The machine moved, and not where it was asked to. Reached only from
  /// `noteRecoverableLayout`, which COMPARES rather than assuming — so this is
  /// the one case where a divergence is a fact rather than a possibility.
  case diverged

  /// Ordered by how strong a claim each makes about the machine: a known
  /// divergence outranks an uncertain one, which outranks "nothing changed".
  /// A card can carry more than one fact at a time, and the title has to be true
  /// of all of them.
  public static func of(
    hasRecoverableLayout: Bool, restoreNotice: ArrangementReapplyNotice?
  ) -> ArrangementReportSubject {
    if hasRecoverableLayout { return .diverged }
    if case .failed = restoreNotice { return .restoreFailed }
    return .nothingChanged
  }
}
