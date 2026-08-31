import CoreGraphics
import Foundation
import os

/// Topology intake diagnostics: one line per raw CG reconfiguration event, plus
/// sleep/wake intake and quiet-window fires. The unplug/replug hardware check
/// reads this category, because Kit tests drive `_simulateReconfigureEvent` and
/// cannot prove real CG delivery.
let topologyLog = Logger(subsystem: "com.rydersel.Candela", category: "topology")

/// Epoch authority for display reconfiguration and sleep/wake: one monotonic
/// epoch plus a suspension gate.
///
/// Two decoupled outputs, on purpose:
/// - The epoch bump and write suspension happen SYNCHRONOUSLY inside the raw
///   event intake (the C callback body, `noteSleep`), so writes submitted during
///   a reconfigure storm fail `isEpochCurrent` from the very first event.
///   "Writes stop now" is real, not debounce-deferred.
/// - The debounce governs only the downstream `topologyChanges` signal: one
///   element per quiet window, restarting on every new event, which is when the
///   suspension clears and the app re-discovers displays.
public actor DisplayManager {
  /// The single epoch store: everything lives behind one nonisolated lock, with
  /// no duplicate actor-side property, so the coalescer drain and submit paths
  /// read it synchronously with no actor hop.
  struct EpochState: Sendable {
    /// Monotonic write-validity generation. Bumped inside the C callback for
    /// every raw CG event, by `noteSleep`, and by the wake quiet-window fire.
    /// Never reset: a captured epoch can only go stale, never current again.
    var epoch: UInt64 = 0
    /// Set by the first raw event of a reconfigure burst; cleared at quiet.
    var reconfigureSuspended = false
    /// Set by `noteSleep`; cleared only by a wake-completed quiet window. Kept
    /// separate from `reconfigureSuspended` so a reconfigure burst going quiet
    /// mid-sleep cannot reopen the write gate.
    var asleep = false
    /// `noteWake` was seen: the next quiet-window fire clears both
    /// suspensions, bumps the epoch, and emits the topology element.
    var wakePending = false
    /// Debounce arm token. Every intake mutation bumps it, and a quiet-window
    /// fire acts only if its token is still current, so restart-on-new-event is
    /// race-free under the same lock as the state it mutates. Cancellation alone
    /// leaves a window where a fire racing a fresh event clears a suspension
    /// that event just set.
    var armToken: UInt64 = 0

    var suspended: Bool { reconfigureSuspended || asleep }
  }

  /// Shared with the `@convention(c)` reconfiguration callback through the
  /// `userInfo` pointer. Sendable: it holds only the state lock and the raw
  /// intake continuation (both Sendable), and its one method is synchronous.
  final class IntakeBox: Sendable {
    let state: OSAllocatedUnfairLock<EpochState>
    let rawEvents: AsyncStream<Void>.Continuation

    init(state: OSAllocatedUnfairLock<EpochState>, rawEvents: AsyncStream<Void>.Continuation) {
      self.state = state
      self.rawEvents = rawEvents
    }

    /// The entire intake for one raw CG event, run synchronously in the
    /// callback: bump the epoch, raise the suspension, signal the debouncer.
    /// Nothing is filtered, so even the begin-configuration phase counts.
    func reconfigureEvent(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
      let epoch = state.withLock { state -> UInt64 in
        state.epoch += 1
        state.reconfigureSuspended = true
        state.armToken += 1
        return state.epoch
      }
      topologyLog.log("reconfigure intake: display=\(displayID) flags=0x\(String(flags.rawValue, radix: 16), privacy: .public) epoch=\(epoch)")
      rawEvents.yield(())
    }
  }

  private nonisolated let state: OSAllocatedUnfairLock<EpochState>
  private nonisolated let intake: IntakeBox
  private nonisolated let intakeTask: Task<Void, Never>

  /// Debounced downstream signal: one element per quiet window after a
  /// reconfigure burst or a wake. Single consumer, because AsyncStream supports
  /// only one iterator, so nothing else may `for await` this.
  public nonisolated let topologyChanges: AsyncStream<Void>

  public init(debounce: Duration = .seconds(1)) {
    let (rawEvents, rawContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let (topology, topologyContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let state = OSAllocatedUnfairLock(initialState: EpochState())
    self.state = state
    self.intake = IntakeBox(state: state, rawEvents: rawContinuation)
    self.topologyChanges = topology
    // Detached and self-free: the intake loop captures only Sendable locals,
    // so it neither inherits an isolation it must hop through nor keeps the
    // actor alive (test instances can deinit).
    self.intakeTask = Task.detached {
      await Self.runIntake(rawEvents: rawEvents, state: state, topology: topologyContinuation, debounce: debounce)
    }
  }

  deinit {
    // App-lifetime in production, never torn down; test instances end the
    // intake machinery here.
    intake.rawEvents.finish()
    intakeTask.cancel()
  }

  /// Sync and lock-backed, so the coalescer drain needs no actor hop. FALSE for
  /// any epoch while suspended (asleep, or mid-reconfigure burst): the
  /// submit-time epoch stamp plus this gate is what keeps a pre-reconfiguration
  /// write off rebuilt hardware.
  public nonisolated func isEpochCurrent(_ epoch: UInt64) -> Bool {
    state.withLock { !$0.suspended && $0.epoch == epoch }
  }

  /// Sync, lock-backed. Read at submit time to stamp `PendingWrite.epoch`.
  public nonisolated func currentEpoch() -> UInt64 {
    state.withLock { $0.epoch }
  }

  /// Sleep intake (NSWorkspace notifications stay app-side and forward here):
  /// synchronous bump and suspend, NO topology element, because sleep is a write
  /// gate rather than a topology change. The arm-token bump invalidates any
  /// in-flight quiet-window fire, so a pre-sleep burst going quiet mid-sleep
  /// cannot emit.
  public nonisolated func noteSleep() {
    let epoch = state.withLock { state -> UInt64 in
      state.epoch += 1
      state.asleep = true
      state.wakePending = false
      state.armToken += 1
      return state.epoch
    }
    topologyLog.log("sleep intake: epoch=\(epoch)")
  }

  /// Wake intake, routed through the debounced path: the suspension clears,
  /// with one epoch bump and one topology element, only after the post-wake
  /// quiet window. The bump at fire keeps epochs captured while suspended
  /// permanently stale.
  public nonisolated func noteWake() {
    state.withLock { state in
      state.wakePending = true
      state.armToken += 1
    }
    topologyLog.log("wake intake")
    intake.rawEvents.yield(())
  }

  /// Registers the CG reconfiguration callback. Nonisolated and synchronous on
  /// purpose: CG delivers callbacks on the run loop of the thread that
  /// registered them, and an actor-executor thread has none, so call this from
  /// the main thread in `applicationDidFinishLaunching`. Call once: the
  /// registration lives for the process, so the box handed to CG is
  /// intentionally immortal (`passRetained`, never balanced).
  public nonisolated func activate() {
    let userInfo = Unmanaged.passRetained(intake).toOpaque()
    let result = CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
      guard let userInfo else { return }
      Unmanaged<DisplayManager.IntakeBox>.fromOpaque(userInfo).takeUnretainedValue()
        .reconfigureEvent(displayID: displayID, flags: flags)
    }, userInfo)
    if result != .success {
      topologyLog.error("CGDisplayRegisterReconfigurationCallback failed: \(result.rawValue); topology intake is dead")
    }
  }

  /// Test seam: drives exactly the C callback's code path. Kit tests cannot
  /// produce real CG events; proof of real delivery is the unplug/replug
  /// intake-log check.
  nonisolated func _simulateReconfigureEvent() {
    intake.reconfigureEvent(displayID: 0, flags: [])
  }

  /// Consumes raw intake events and debounces ONLY the downstream signal: each
  /// raw event re-arms a quiet-window timer stamped with the arm token current
  /// at that moment, and a timer expiring with its token still current performs
  /// the quiet transition. Static so it cannot capture the actor.
  private static func runIntake(
    rawEvents: AsyncStream<Void>,
    state: OSAllocatedUnfairLock<EpochState>,
    topology: AsyncStream<Void>.Continuation,
    debounce: Duration
  ) async {
    var pendingFire: Task<Void, Never>?
    for await _ in rawEvents {
      pendingFire?.cancel() // best-effort; the arm token is the correctness gate
      let token = state.withLock { $0.armToken }
      pendingFire = Task.detached {
        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else { return }
        let emit = state.withLock { state -> Bool in
          guard state.armToken == token else { return false } // superseded by newer intake
          if state.wakePending {
            state.wakePending = false
            state.asleep = false
            state.reconfigureSuspended = false
            state.epoch += 1 // epochs captured while suspended stay stale
            return true
          }
          state.reconfigureSuspended = false
          // Quiet mid-sleep: keep the gate shut and defer the element to the
          // wake fire.
          return !state.asleep
        }
        if emit {
          topologyLog.log("topology quiet window elapsed, signaling refresh")
          topology.yield(())
        }
      }
    }
    pendingFire?.cancel()
    topology.finish()
  }
}
