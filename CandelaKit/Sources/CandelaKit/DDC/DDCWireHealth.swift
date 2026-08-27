import Foundation

/// Whether this display's DDC wire is still carrying writes, counted from what
/// the applies ACTUALLY reported.
///
/// Keyed on writes, not reads: the MAG341C answers every read with zeros and
/// honours every write, so a rule keyed on read evidence would demote the panel
/// it looks worst on.
///
/// No clock and no display in it, so the rule is tested without hardware; the
/// controller decides which applies reach it.
public struct DDCWireHealth: Sendable, Equatable {
  /// One failed write is a glitch, and a wire that drops a command still takes
  /// the next one. Three in a row with no success between them is a wire that
  /// has stopped.
  public static let failuresBeforeUnresponsive = 3

  /// Failed applies since the last success or reset. Public so a diagnostic can
  /// say how far along the count is, not just whether it finished.
  public private(set) var consecutiveFailures = 0

  public init() {}

  /// True once the wire has failed `failuresBeforeUnresponsive` applies in a
  /// row. Not latched: any reset route, or one successful apply, takes it back
  /// to false. Crisp latches for the session and needs a replug.
  public var isUnresponsive: Bool {
    consecutiveFailures >= Self.failuresBeforeUnresponsive
  }

  /// Records one apply attempt's outcome. `hdrExcluded` drops the attempt in
  /// BOTH directions: the register is locked while live HDR is engaged or
  /// settling, so a failure there is no evidence about the wire and a success
  /// would clear a count the wire had honestly earned.
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
