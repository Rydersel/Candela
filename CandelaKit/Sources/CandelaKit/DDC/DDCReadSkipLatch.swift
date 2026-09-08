/// When a display's DDC reads stop being worth attempting.
///
/// A read pass on a panel that gives nothing back holds the wire for the whole
/// retry ladder, which is the menu-close stall a person feels, so such a panel
/// is asked once per plug. Two consecutive passes of the SAME nothing, not one:
/// bus contention, the probe holding the wire and another panel entering HDR
/// all produce one bad pass on a display that answers on the next, and the
/// Dell has answered silence on a plug-in pass and right after a mode change.
/// Zeros and silence are different findings, so one of each is contention, not
/// a run: taking them as a pair flipped the MAG from "Write-only" to "Not
/// answering" on a single bad pass.
///
/// Counts passes, never attempts. Also decides when silence becomes a VERDICT:
/// a frame, zeros or a refusal publish at once, silence only on the pass that
/// trips the latch.
struct DDCReadSkipLatch: Sendable, Equatable {
  static let latchAfter = 2

  /// Which nothing the current run is made of, so a run is only ever the same
  /// finding repeating. nil once a pass has answered.
  private var runningNonAnswer: DDCReadEvidence?
  private(set) var consecutiveNonAnswers = 0

  /// Whether the next pass should skip the wire entirely.
  var skipsRead: Bool { consecutiveNonAnswers >= Self.latchAfter }

  /// Records one pass and answers whether the caller should PUBLISH it, in one
  /// call so no site can ask before recording. `notAttempted` is not a pass and
  /// changes nothing. A frame, zeros or a refusal supersede at once; silence only
  /// once it has happened twice running, and a different pass in between breaks
  /// the run.
  ///
  /// A refusal counts toward the skip even though it is an answer: it is the
  /// panel's settled word about that register, so re-asking spends the wire on a
  /// question already answered. It publishes on its first pass for the same
  /// reason zeros do, being the panel's own word rather than a busy bus.
  @discardableResult
  mutating func record(_ evidence: DDCReadEvidence) -> Bool {
    switch evidence {
    case .noReply, .allZeros, .refused:
      if runningNonAnswer == evidence {
        // Capped so a long-silent panel cannot count past the latch.
        consecutiveNonAnswers = min(consecutiveNonAnswers + 1, Self.latchAfter)
      } else {
        // A different finding starts its own run; one of each is contention.
        runningNonAnswer = evidence
        consecutiveNonAnswers = 1
      }
      return evidence != .noReply || skipsRead
    case .answered:
      runningNonAnswer = nil
      consecutiveNonAnswers = 0
      return true
    case .notAttempted:
      return false
    }
  }

  /// Anything that may have changed the panel's mind: wake, reconfiguration,
  /// rebind, an HDR window closing. Clears the skip only: the read pass runs
  /// before the reconfiguration clear, and wiping the verdict here left the hub
  /// reading "Not asked yet" on both panels after every reconfiguration [MEASURED].
  mutating func clear() {
    runningNonAnswer = nil
    consecutiveNonAnswers = 0
  }
}
