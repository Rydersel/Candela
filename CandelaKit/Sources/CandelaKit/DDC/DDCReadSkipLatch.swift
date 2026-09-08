/// When a display's DDC reads stop being worth attempting.
///
/// A read pass on a silent panel walks the whole retry ladder with the wire
/// held, which is the menu-close stall a person feels, so a panel that says
/// nothing is asked once per plug rather than on every pass. What decides that
/// is TWO consecutive silent passes, not one: bus contention, the probe holding
/// the wire, another panel entering HDR and a wedged transaction all produce one
/// bad pass on a display that answers perfectly on the next, and latching on the
/// first would publish "does not answer reads" about the Dell for the rest of
/// the plug. The cost of the second pass is one more futile read pass per plug
/// on a genuinely write-only panel.
///
/// Counts PASSES, never attempts: a pass that retries internally is one
/// hearing, and the retries are the reliability mechanism rather than evidence
/// of their own.
///
/// Separate from `DDCReadEvidence`, which is what diagnostics reports. The
/// verdict is published from the first silent pass; only the asking waits for
/// the second.
struct DDCReadSkipLatch: Sendable, Equatable {
  static let latchAfter = 2

  private(set) var consecutiveSilentPasses = 0

  /// Whether the next pass should skip the wire entirely.
  var skipsRead: Bool { consecutiveSilentPasses >= Self.latchAfter }

  /// One pass's verdict. `notAttempted` is not a pass and leaves the count
  /// alone: a controller that returned before reaching the wire has learned
  /// nothing about the panel either way.
  mutating func record(_ evidence: DDCReadEvidence) {
    switch evidence {
    case .noReply, .allZeros:
      // Capped so a long-lived silent panel cannot count past the latch and
      // make the value itself unstable.
      consecutiveSilentPasses = min(consecutiveSilentPasses + 1, Self.latchAfter)
    case .answered:
      consecutiveSilentPasses = 0
    case .notAttempted:
      break
    }
  }

  /// Anything that may have changed the panel's mind: a wake, a
  /// reconfiguration, a rebind onto another panel, an HDR window closing.
  mutating func clear() { consecutiveSilentPasses = 0 }
}
