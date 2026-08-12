/// Hardware boundary for DDC/CI. Implementations serialize their own I/O.
public protocol DDCWriting: Sendable {
  func write(command: UInt8, value: UInt16) async -> Bool
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)?
  /// The display's MCCS capability string (VCP 0xF3), reassembled from its
  /// fragments. `nil` means the TRANSACTION failed — never read that as "this
  /// display has no capabilities" (D24: unknown resolves to enabled).
  func readCapabilityString() async -> String?
}

public extension DDCWriting {
  /// Writers with no capabilities path — the built-in's `NoopDDCWriter`, test
  /// fakes — inherit the honest answer: we do not know.
  func readCapabilityString() async -> String? { nil }
}

/// A controller holding hardware writes that have been SUBMITTED and may not
/// have reached the wire.
///
/// Every value controller here submits onto a coalescer that drains on its own
/// task, so a submit call returning says nothing about the register. Anything
/// that is about to make the wire unusable (HDR locks DDC on the display) has
/// to wait the queue out first, and this is what it waits on.
///
/// Waiting is not enough on its own, which is why this is two methods and not
/// one. The queue completes a generation whether the target reached hardware or
/// was SKIPPED (stamped before a display reconfiguration, or the apply failed),
/// so a plain wait can return instantly having put nothing on the panel. And a
/// queue that is empty now can be refilled a moment later by a poller or a
/// dimming tick, so emptiness has to be re-checked against a submission counter
/// rather than believed once.
@MainActor
public protocol PendingWireDraining {
  /// Monotonic count of submits. Two equal marks across an interval mean
  /// nothing new was queued during it.
  func submissionMark() -> UInt64
  /// Waits the queue out and reports whether everything submitted has reached
  /// hardware. A target the queue completed WITHOUT applying is submitted again
  /// (with a fresh epoch stamp) and waited on once more, so a single closed
  /// reconfiguration window is recovered rather than reported.
  ///
  /// What "reached hardware" can mean here is bounded by the panel: the applier
  /// ran and reported success. On a write-only display that is the end of the
  /// evidence, and it is still categorically better than the counter, which
  /// cannot tell a write from a skip.
  func drainPendingWrites() async -> Bool
}

/// Drives a set of write queues to a state where nothing is owed to the panel.
public enum WireQuiescence {
  /// Drains every controller repeatedly until one full pass ends with every
  /// queue applied AND nobody having submitted anything new during the pass.
  ///
  /// The re-check is the load-bearing half. Draining controllers one at a time
  /// only proves the LAST one is empty: a poller tick or a dimming ramp landing
  /// while a later controller is still being waited on refills an earlier queue,
  /// and a caller that took the first pass as proof would then lock the register
  /// over a write nobody can see fail. A pass with no advance anywhere is what
  /// rules that out.
  ///
  /// Returns false when it cannot get there, which is a real outcome and not a
  /// formality: the reconfiguration window that skips writes lasts about a
  /// second, so the rounds and the pause between them are sized to outlast one.
  /// A caller that was going to make the wire unusable must not do so on false.
  @MainActor
  public static func settle(
    _ controllers: [any PendingWireDraining],
    rounds: Int = 5,
    betweenRounds: Duration = .milliseconds(400)
  ) async -> Bool {
    guard !controllers.isEmpty else { return true }
    for round in 0 ..< rounds {
      let before = controllers.map { $0.submissionMark() }
      var allApplied = true
      for controller in controllers where await controller.drainPendingWrites() == false {
        allApplied = false
      }
      let after = controllers.map { $0.submissionMark() }
      if allApplied, before == after { return true }
      if round + 1 < rounds { try? await Task.sleep(for: betweenRounds) }
    }
    return false
  }
}
