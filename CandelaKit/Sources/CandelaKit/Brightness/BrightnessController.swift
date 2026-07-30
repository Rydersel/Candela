import Observation
import os

/// Drag-perf diagnostics: one log line per post-coalescing pipeline stage
/// (target adoption, DDC write start/end). Cheap (~30 Hz during a drag) and
/// the fastest way to localize a "slider moves but hardware doesn't" report:
/// `log show --predicate 'subsystem == "com.rydersel.Candela"'`.
let dragPerfLog = Logger(subsystem: "com.rydersel.Candela", category: "dragperf")

/// Single source of truth for one display's brightness (spec §5: every input
/// funnels through here; every surface renders from `brightness`).
@MainActor @Observable
public final class BrightnessController {
  public private(set) var brightness: Double = 0.5
  public private(set) var maxDDCValue: UInt16 = 100

  private let writer: any DDCWriting
  private let coalescer: BrightnessWriteCoalescer
  @ObservationIgnored private var issuedGeneration: UInt64 = 0

  public init(writer: any DDCWriting, minimumWriteInterval: Duration = .milliseconds(15)) {
    self.writer = writer
    self.coalescer = BrightnessWriteCoalescer(writer: writer, minimumWriteInterval: minimumWriteInterval)
  }

  deinit {
    // Ends the coalescer's drain loop (after any in-progress ramp lands) so
    // the coalescer and its task don't outlive the controller.
    coalescer.finishSubmissions()
  }

  public func refreshFromHardware() async {
    guard let result = await writer.read(command: VCP.brightness), result.max > 0 else {
      return
    }
    maxDDCValue = result.max
    brightness = Double(min(result.current, result.max)) / Double(result.max)
  }

  /// Synchronous by design: state updates immediately, hardware writes ease
  /// toward the latest target — a 60 Hz slider drag must never queue stale
  /// DDC writes (each write holds the DDC actor for ~20 ms, more on retries).
  ///
  /// The hardware write must not require the main actor for any step after
  /// this call returns: during a slider drag the main run loop sits in
  /// event-tracking mode, which starves main-actor task execution until
  /// mouseup — a drain loop started here with `Task {}` (which inherits
  /// MainActor isolation) would never run mid-drag, and even
  /// `Task { await coalescer.submit(...) }` needs a main-actor turn just to
  /// start its body. So the handoff is a synchronous, nonisolated store into
  /// a lock-protected slot; the coalescer drains on the global executor.
  public func setBrightness(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    brightness = clamped
    issuedGeneration += 1
    coalescer.submit(
      .init(value: UInt16((clamped * Double(maxDDCValue)).rounded()), generation: issuedGeneration)
    )
  }

  public func waitForPendingWrites() async {
    await coalescer.waitUntilCompleted(through: issuedGeneration)
  }
}

/// Drains brightness writes to hardware off the main actor with eased
/// stepping: instead of jumping to the newest target (which the MAG341C
/// renders as visible chunks — hardware-verified via `candela-probe ramp`,
/// task-7 round 4: 1-unit-step ramps at ~15-25 ms cadence are user-rated
/// smooth, coarse jumps are not), the drain writes a monotonic sequence of
/// intermediate values from the last value sent toward the CURRENT newest
/// target — the same play-through-intermediates approach as the MonitorControl
/// fork's smooth-brightness mode and BetterDisplay.
///
/// Submission is a synchronous, nonisolated store into an
/// `OSAllocatedUnfairLock`-protected slot (newest-wins, the slot *is* the
/// pending-target buffer) — storing never requires an executor hop, so a
/// @MainActor caller can submit while the run loop is stuck in event-tracking
/// mode (the round-1 defect). The single drain loop re-reads that slot before
/// every step, so a mid-ramp submission redirects the ramp instead of queuing
/// behind it. Each submitted target carries a monotonic generation;
/// `waitUntilCompleted(through:)` suspends until the ramp has REACHED a target
/// with at least that generation (a newer target superseding an older one
/// completes the older generation too — latest-wins).
actor BrightnessWriteCoalescer {
  struct PendingWrite: Sendable {
    let value: UInt16
    let generation: UInt64
  }

  private struct SubmissionState {
    var pending: PendingWrite?
    var finished = false
    var parkedDrain: CheckedContinuation<Void, Never>?
  }

  private enum NextAction {
    case target(PendingWrite)
    case finish
    case park
  }

  private let writer: any DDCWriting
  /// Newest-wins handoff slot shared with (nonisolated, synchronous) `submit`.
  private nonisolated let submissionLock = OSAllocatedUnfairLock(initialState: SubmissionState())

  /// Last raw value actually written to hardware — the ramp origin. `nil`
  /// until the first write: the MAG341C is a write-only DDC panel (every read
  /// returns zeros), so the panel's actual brightness is unknowable at init
  /// and there is no truthful ramp origin. The first target is therefore
  /// written directly (one jump); easing applies from there on.
  private var lastSentRaw: UInt16?
  private var completedGeneration: UInt64 = 0
  private var waiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

  /// Minimum spacing between write STARTS. The DDC transaction itself takes
  /// ~20-30 ms (internal usleep per write cycle), so with the 15 ms default
  /// the effective cadence is ~25-35 ms/step — the cadence the user rated
  /// smooth on the MAG341C ramp test. Injectable (use `.zero`) so logic tests
  /// stay wall-clock-free.
  private let minimumWriteInterval: Duration
  private var lastWriteStart: ContinuousClock.Instant?

  init(writer: any DDCWriting, minimumWriteInterval: Duration = .milliseconds(15)) {
    self.writer = writer
    self.minimumWriteInterval = minimumWriteInterval
    // Detached so the drain loop starts on the global executor regardless of
    // where the controller was created; a plain `Task {}` here could inherit
    // isolation from the initializing context.
    Task.detached { await self.drain() }
  }

  /// Synchronous and nonisolated on purpose — see the type comment.
  /// Generations must be issued monotonically by the (single) submitter.
  nonisolated func submit(_ write: PendingWrite) {
    let parked = submissionLock.withLock { state -> CheckedContinuation<Void, Never>? in
      guard !state.finished else { return nil }
      state.pending = write
      let parked = state.parkedDrain
      state.parkedDrain = nil
      return parked
    }
    parked?.resume()
  }

  /// Ends the drain loop once every already-submitted target has been reached.
  nonisolated func finishSubmissions() {
    let parked = submissionLock.withLock { state -> CheckedContinuation<Void, Never>? in
      state.finished = true
      let parked = state.parkedDrain
      state.parkedDrain = nil
      return parked
    }
    parked?.resume()
  }

  /// Suspends until the ramp has reached a target with generation >=
  /// `generation` (or a superseding one). Returns immediately for generation 0
  /// (nothing was ever submitted).
  func waitUntilCompleted(through generation: UInt64) async {
    guard generation > completedGeneration else { return }
    await withCheckedContinuation { waiters.append((generation, $0)) }
  }

  private func drain() async {
    while var target = await nextTarget() {
      dragPerfLog.log("coalescer.target raw=\(target.value) gen=\(target.generation)")
      ramp: while true {
        // Re-read the newest submission before every step so a mid-ramp
        // target change redirects the ramp instead of queuing behind it.
        if let newer = takePendingTarget() {
          target = newer
          dragPerfLog.log("coalescer.target raw=\(target.value) gen=\(target.generation)")
        }
        guard let origin = lastSentRaw else {
          // First-ever write: jump directly (no truthful ramp origin on a
          // write-only panel — see `lastSentRaw`).
          await pacedWrite(target.value)
          lastSentRaw = target.value
          complete(target.generation)
          break ramp
        }
        if target.value == origin {
          // Duplicate-skip (kept from round 2): the value is already on the
          // wire — no bus traffic, but the generation completes because the
          // ramp has trivially reached it.
          complete(target.generation)
          break ramp
        }
        // Adaptive easing: an eighth of the remaining distance per write
        // (recomputed each step, so big jumps start coarse and refine as
        // they approach), floored at 1 so small deltas play through every
        // intermediate value, capped at the remainder to land exactly.
        let remaining = Int(target.value) - Int(origin)
        let magnitude = abs(remaining)
        let step = min(max(1, magnitude / 8), magnitude)
        let next = UInt16(Int(origin) + (remaining > 0 ? step : -step))
        await pacedWrite(next)
        lastSentRaw = next
        if next == target.value {
          // Reached the target: complete its generation. Waiters on
          // superseded generations resolve here too (this generation is,
          // by monotonicity, at least theirs).
          complete(target.generation)
          break ramp
        }
      }
    }
    // Drain exits only after `finishSubmissions` with the slot empty, and
    // every dequeued target completed its generation above — no waiter can
    // be left suspended.
  }

  /// Dequeues the newest target, parking (suspended, no polling) while the
  /// slot is empty. Returns nil once finished and empty.
  private func nextTarget() async -> PendingWrite? {
    while true {
      let action = submissionLock.withLock { state -> NextAction in
        if let pending = state.pending {
          state.pending = nil
          return .target(pending)
        }
        return state.finished ? .finish : .park
      }
      switch action {
      case let .target(pending):
        return pending
      case .finish:
        return nil
      case .park:
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          // Re-check under the lock before parking: a submit may have landed
          // between the dequeue attempt above and here.
          let resumeImmediately = submissionLock.withLock { state -> Bool in
            if state.pending != nil || state.finished {
              return true
            }
            state.parkedDrain = continuation
            return false
          }
          if resumeImmediately {
            continuation.resume()
          }
        }
      }
    }
  }

  /// Non-blocking dequeue for mid-ramp redirect checks.
  private func takePendingTarget() -> PendingWrite? {
    submissionLock.withLock { state -> PendingWrite? in
      let pending = state.pending
      state.pending = nil
      return pending
    }
  }

  /// Writes one value, enforcing `minimumWriteInterval` between write starts.
  private func pacedWrite(_ value: UInt16) async {
    if let lastStart = lastWriteStart {
      // Spacing write STARTS (not end-to-start) means the ~20-30 ms
      // transaction usually absorbs the whole interval — this only adds
      // delay when a transaction returns unusually fast.
      try? await Task.sleep(until: lastStart + minimumWriteInterval, clock: .continuous)
    }
    lastWriteStart = ContinuousClock.now
    _ = await writer.write(command: VCP.brightness, value: value)
  }

  private func complete(_ generation: UInt64) {
    completedGeneration = max(completedGeneration, generation)
    resumeSatisfiedWaiters()
  }

  private func resumeSatisfiedWaiters() {
    let satisfied = waiters.filter { $0.generation <= completedGeneration }
    guard !satisfied.isEmpty else { return }
    waiters.removeAll { $0.generation <= completedGeneration }
    for waiter in satisfied {
      waiter.continuation.resume()
    }
  }
}
