/// What DDC READS from a display have proved.
///
/// There is no `isWriteOnlyPanel` flag anywhere else in this codebase. Three
/// detection sites existed and every one of them handled the condition and
/// then forgot it, leaving the knowledge in comments where no row could read
/// it. Two now publish it — `BrightnessController.refreshFromHardware` and
/// `DDCValueController.refreshFromHardware`, both through this type. The third,
/// `Arm64DDCService.readCapabilityString`, still forgets: it returns nil on a
/// failed fragment and the caller learns only that there was no capability
/// string, not whether the panel went silent or answered with nothing. Wiring
/// that one up needs a decision about what a truncated string proves, which is
/// why it is named here rather than quietly left out.
///
/// [MEASURED] The MAG 341C answers every DDC read with zeros — verified across
/// 13 timing/buffer combinations and 5 VCP codes. Silence about this is what
/// let the fork's unvalidated reads clobber saved values to 0.
///
/// Deliberately a pure value, not state on a controller-owner: `AppModel.DisplayState`
/// holds `controller`, `volume` and `contrast` as SIBLINGS, so no one object is
/// in a position to push a verdict down. Each site publishes what its own reads
/// proved and the READER folds them with `worst(_:)` — an earlier draft of the
/// spec assumed `BrightnessController` owned the `DDCValueController`s and could
/// aggregate on their behalf; it does not.
public enum DDCReadEvidence: Sendable, Equatable {
  /// No read has been attempted. The FLOOR, not a bad outcome.
  case notAttempted
  /// At least one read came back with `max > 0`. This panel answers.
  case answered
  /// Reads returned `(0, 0)` / `max == 0` — the write-only signature.
  case allZeros
  /// Reads returned nil: no reply, bad checksum, wrong opcode or wrong offset.
  case noReply

  /// Worst-wins ordering. `allZeros` outranks `noReply` because it is the more
  /// SPECIFIC finding — the panel is on the bus and talking, it just never
  /// says anything true — and that is the sentence the user needs.
  private var severity: Int {
    switch self {
    case .notAttempted: 0
    case .answered: 1
    case .noReply: 2
    case .allZeros: 3
    }
  }

  /// Worst evidence wins: one `allZeros` is never cancelled by a
  /// `notAttempted` or by a silent retry.
  ///
  /// The defect this prevents: without it, a panel that answered zeros on
  /// brightness and then went quiet on the retry would report the vaguer
  /// "no reply", losing the one observation that names the fault.
  ///
  /// SCOPE — read this before folding with it. `worse` is right WITHIN a
  /// single read pass, and across a display's sibling controllers (see
  /// `worst`). It is wrong ACROSS passes and across a successful retry: the
  /// retry loop exists precisely because DDC reads are flaky, so "attempt 1
  /// silent, attempt 2 answers" is the healthy case, and folding it
  /// monotonically publishes "this display does not reply" about a panel that
  /// just replied — a false sentence from the feature built to stop false
  /// sentences. A read that eventually succeeded is a read that succeeded, and
  /// a new pass supersedes the last one. The call sites are where that scope
  /// is enforced, so it is pinned there and not only here.
  public static func worse(_ lhs: DDCReadEvidence, _ rhs: DDCReadEvidence) -> DDCReadEvidence {
    lhs.severity >= rhs.severity ? lhs : rhs
  }

  /// Folds one display's controllers into a single verdict. Empty is
  /// `notAttempted`, not an error: a display with no controllers has proved
  /// nothing either way.
  public static func worst(_ evidences: [DDCReadEvidence]) -> DDCReadEvidence {
    evidences.reduce(.notAttempted, worse)
  }
}
