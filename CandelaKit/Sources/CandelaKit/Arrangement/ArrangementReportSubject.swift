import Foundation

/// What an arrangement report card is actually reporting, which is what has to title
/// it.
///
/// Two of the card's branches are DIVERGENCE branches: the layout offered back after
/// an apply that moved the displays somewhere nobody asked for, and a restore that
/// failed the post-commit check. A single fixed "Arrangement not changed" title
/// rendered directly above "The displays did not end up where they were asked to go".
///
/// Three cases rather than two, because the middle one is genuinely UNCERTAIN and must
/// not be resolved by guessing. Pure and here rather than in the app target so the
/// precedence below has a test.
public enum ArrangementReportSubject: Sendable, Equatable {
  /// Nothing was applied: a layout refused for overlapping or stranding a display
  /// (the spring-back rule), a claim refused by the gate, a `begin` that failed without moving
  /// anything, or a saved layout declined rather than attempted.
  case nothingChanged

  /// A saved layout was attempted and did not come back.
  ///
  /// It claims nothing about where the displays ended up.
  /// `ArrangementCoordinator.apply(restored:)` reports `.failed` both for a plan it
  /// could not express as a whole, where nothing was staged, and for the post-commit
  /// check, where CoreGraphics reported success and committed a layout of its own.
  /// "Not restored" is true of both; either stronger sentence is false of one.
  case restoreFailed

  /// The machine moved, and not where it was asked to. Reached only from
  /// `noteRecoverableLayout`, which COMPARES rather than assuming, so this is the one
  /// case where a divergence is a fact rather than a possibility.
  case diverged

  /// Ordered by how strong a claim each makes about the machine. A card can carry
  /// more than one fact at a time, and the title has to be true of all of them.
  public static func of(
    hasRecoverableLayout: Bool, restoreNotice: ArrangementReapplyNotice?
  ) -> ArrangementReportSubject {
    if hasRecoverableLayout { return .diverged }
    if case .failed = restoreNotice { return .restoreFailed }
    return .nothingChanged
  }
}
