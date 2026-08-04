import Foundation

/// What DDC READS from a display have proved so far.
///
/// There is no `isWriteOnlyPanel` flag anywhere else in this codebase: three
/// detection sites exist (`BrightnessController.refreshFromHardware`,
/// `DDCValueController.refreshFromHardware`, `Arm64DDCService.readCapabilityString`)
/// and every one of them handles the condition and forgets it, leaving the
/// knowledge in comments where no row can read it.
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

  /// Worst evidence wins within a display: one `allZeros` is never cancelled
  /// by a later `notAttempted`.
  ///
  /// The defect this prevents: a monotonic fold is the only reason a panel that
  /// answered zeros on brightness at startup still reads as write-only after a
  /// later pass skipped the read entirely (`startupAction != .read`, HDR live,
  /// `unavailableDDC`). A plain assignment at each site would let the last
  /// no-op quietly erase the one observation that mattered.
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
