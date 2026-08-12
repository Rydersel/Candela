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
  /// Monotonic count of submits made by anyone OTHER than the drain's own
  /// retries. Two equal marks across an interval mean nothing new was queued
  /// during it; counting the retries would mean a round that retried could
  /// never report a quiet wire, which is the opposite of what it proves.
  func submissionMark() -> UInt64
  /// Forgets what this controller believes is already on the panel.
  ///
  /// Every queue here skips a write whose value the memo says is already in the
  /// register, and that memo is built from writes the panel ACKNOWLEDGED. Under
  /// HDR the I2C write is acknowledged and swallowed, so a memo built through an
  /// HDR window records values that never landed, and the skip then certifies
  /// them. Anything that knows the panel's state may have moved out from under
  /// the memo has to say so here.
  func resetWriteMemo()
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
  /// formality: a caller that was going to make the wire unusable must not do so
  /// on false.
  ///
  /// `isWireOpen` removes a timing bet where the caller has one to offer. What
  /// skips writes is the reconfiguration gate, and that gate is readable, so a
  /// round that failed can wait for it to open instead of sleeping a length of
  /// time chosen to be longer than a window nobody measured. Without it the
  /// pause is a plain sleep, which is why the default is sized to outlast the
  /// gate's own quiet window rather than to be quick.
  @MainActor
  public static func settle(
    _ controllers: [any PendingWireDraining],
    rounds: Int = 5,
    betweenRounds: Duration = .milliseconds(400),
    isWireOpen: (@MainActor () -> Bool)? = nil
  ) async -> Bool {
    guard !controllers.isEmpty else { return true }
    for round in 0 ..< rounds {
      let before = controllers.map { $0.submissionMark() }
      var allApplied = true
      for controller in controllers where await controller.drainPendingWrites() == false {
        allApplied = false
      }
      // Read AFTER the drains, so a retry the drain itself issued is not
      // mistaken for someone else queueing work (`submissionMark` excludes
      // those, and this is the other half of the same accounting).
      let after = controllers.map { $0.submissionMark() }
      if allApplied, before == after { return true }
      if round + 1 < rounds { await pause(betweenRounds, isWireOpen: isWireOpen) }
    }
    return false
  }

  /// Waits for the gate rather than for the clock when a gate is available:
  /// polls in short slices and returns the moment the wire is open, capped by
  /// the same budget the blind sleep would have spent.
  @MainActor
  private static func pause(_ budget: Duration, isWireOpen: (@MainActor () -> Bool)?) async {
    guard let isWireOpen else {
      try? await Task.sleep(for: budget)
      return
    }
    let slice = Duration.milliseconds(25)
    var spent = Duration.zero
    while spent < budget {
      if isWireOpen() { return }
      try? await Task.sleep(for: slice)
      spent += slice
    }
  }
}
