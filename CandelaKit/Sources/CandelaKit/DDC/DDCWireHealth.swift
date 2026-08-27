import Foundation

/// Whether this display's DDC wire is still carrying writes, counted from what
/// the applies ACTUALLY reported.
///
/// The sibling of `DDCReadEvidence`, and deliberately keyed on the other half
/// of the wire. Read evidence cannot answer this question at all: the MAG341C
/// answers every read with zeros and honours every write, so a rule keyed on
/// reads would demote the panel it looks worst on. Writes are the only signal
/// that separates a wire from a corpse.
///
/// A pure value type with no clock and no display in it, so the rule is stated
/// once and tested without hardware; the controller owns the instance and
/// decides which applies reach it.
public struct DDCWireHealth: Sendable, Equatable {
  /// Three, matching the count a display gets before anything about it changes.
  /// One failed write is a glitch, and a wire that drops a single command still
  /// takes the next one; three in a row with no success between them is a wire
  /// that has stopped.
  public static let failuresBeforeUnresponsive = 3

  /// Failed applies since the last success or reset. Published so a diagnostic
  /// can say how far along the count is rather than only whether it finished.
  public private(set) var consecutiveFailures = 0

  public init() {}

  /// True once the wire has failed `failuresBeforeUnresponsive` applies in a
  /// row. Not latched: any of the reset routes, or one successful apply, takes
  /// it back to false. That is the whole difference from Crisp's version of
  /// this idea, which demotes for the rest of the session and can only be
  /// undone by unplugging the display.
  public var isUnresponsive: Bool {
    consecutiveFailures >= Self.failuresBeforeUnresponsive
  }

  /// Records one apply attempt's outcome.
  ///
  /// `hdrExcluded` drops the attempt entirely, in BOTH directions, which is
  /// what "not counted at all" has to mean: while live HDR is engaged or its
  /// settle window is open, the display routes native and the register is
  /// locked, so neither a failure nor a success there is evidence about the
  /// wire. Counting the failures is the specific thing Crisp gets wrong, and
  /// counting the successes would be the same error wearing the opposite sign:
  /// an HDR-window success would clear a count the wire had honestly earned.
  public mutating func noteApply(succeeded: Bool, hdrExcluded: Bool) {
    guard !hdrExcluded else { return }
    if succeeded {
      consecutiveFailures = 0
    } else {
      consecutiveFailures += 1
    }
  }

  /// Back to trusted, so the next writes decide again.
  public mutating func reset() {
    consecutiveFailures = 0
  }
}
