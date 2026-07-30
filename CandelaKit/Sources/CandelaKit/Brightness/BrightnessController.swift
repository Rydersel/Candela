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
  /// Last-written brightness is the only truth on write-only DDC panels, so it
  /// is persisted here and restored at init — without it the panel opens at
  /// the 0.5 default on every launch.
  private let store: (any BrightnessStoring)?
  private let storageKey: String?

  public init(writer: any DDCWriting, store: (any BrightnessStoring)? = nil, storageKey: String? = nil) {
    self.writer = writer
    self.store = store
    self.storageKey = storageKey
    self.coalescer = BrightnessWriteCoalescer(writer: writer)
    if let store, let storageKey, let saved = store.savedBrightness(for: storageKey) {
      brightness = min(max(saved, 0), 1)
    }
  }

  deinit {
    // Ends the coalescer's drain loop (after any pending write lands) so the
    // coalescer and its task don't outlive the controller.
    coalescer.finishSubmissions()
  }

  public func refreshFromHardware() async {
    guard let result = await writer.read(command: VCP.brightness), result.max > 0 else {
      return
    }
    maxDDCValue = result.max
    brightness = Double(min(result.current, result.max)) / Double(result.max)
    // A readable panel's hardware value is truth, so the store must adopt it
    // too — otherwise the saved number goes stale and the next launch restores
    // an outdated brightness.
    if let store, let storageKey {
      store.saveBrightness(brightness, for: storageKey)
    }
  }

  /// Synchronous by design: state updates immediately, hardware writes
  /// coalesce latest-wins — a 60 Hz slider drag must never queue stale DDC
  /// writes (each write holds the DDC actor for ~20 ms, more on retries).
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
    if let store, let storageKey {
      store.saveBrightness(clamped, for: storageKey)
    }
  }

  /// One OSD-chiclet step (fork: `Display.calcNewBrightness`): 16 chiclets,
  /// quarter-chiclet bias, ceil-snap so off-boundary values snap in the
  /// direction of travel. `isFine` steps a quarter chiclet (Opt+Shift).
  @discardableResult
  public func step(isUp: Bool, isFine: Bool) -> Double {
    var stepSize: Double = (isUp ? 1 : -1) / 16.0
    let delta = stepSize / 4
    if isFine {
      stepSize = delta
    }
    let value = min(max(0, (((brightness + delta) / stepSize).rounded(.up)) * stepSize), 1)
    setBrightness(value)
    return value
  }

  public func waitForPendingWrites() async {
    await coalescer.waitUntilCompleted(through: issuedGeneration)
  }
}

/// Drains brightness writes to hardware off the main actor, coalescing
/// latest-wins: every write jumps straight to the newest target, as fast as
/// the DDC transaction allows (its internal per-cycle sleeps are the only
/// pacing). Deliberate product decision (task-7 round 6): eased intermediate
/// stepping made drags "feel slower" on the MAG341C — the panel's DDC
/// apply-path is the bottleneck, and the real smoothness fix is M3 software
/// dimming, not write-shaping.
///
/// Submission is a synchronous, nonisolated store into an
/// `OSAllocatedUnfairLock`-protected slot (newest-wins, the slot *is* the
/// pending-target buffer) — storing never requires an executor hop, so a
/// @MainActor caller can submit while the run loop is stuck in event-tracking
/// mode (the round-1 defect). The single drain loop dequeues the newest
/// target, so intermediates that arrive while a write is in flight are
/// dropped and the final value always lands. Each submitted target carries a
/// monotonic generation; `waitUntilCompleted(through:)` suspends until a
/// target with at least that generation has been written or skipped (a newer
/// target superseding an older, dropped one completes the older generation
/// too — latest-wins).
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

  /// Last raw value actually written to hardware, for the duplicate-skip
  /// (round 2): re-sending the value already on the wire saturates the
  /// DDC/I2C bus for nothing. `nil` until the first write.
  private var lastSentRaw: UInt16?
  private var completedGeneration: UInt64 = 0
  private var waiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

  init(writer: any DDCWriting) {
    self.writer = writer
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

  /// Ends the drain loop once every already-submitted target has landed.
  nonisolated func finishSubmissions() {
    let parked = submissionLock.withLock { state -> CheckedContinuation<Void, Never>? in
      state.finished = true
      let parked = state.parkedDrain
      state.parkedDrain = nil
      return parked
    }
    parked?.resume()
  }

  /// Suspends until a target with generation >= `generation` has been written
  /// (or skipped as a duplicate, or superseded). Returns immediately for
  /// generation 0 (nothing was ever submitted).
  func waitUntilCompleted(through generation: UInt64) async {
    guard generation > completedGeneration else { return }
    await withCheckedContinuation { waiters.append((generation, $0)) }
  }

  private func drain() async {
    while let target = await nextTarget() {
      dragPerfLog.log("coalescer.target raw=\(target.value) gen=\(target.generation)")
      // Duplicate-skip (round 2): never rewrite the value already on the
      // wire — duplicate re-sends saturate the bus for nothing. The
      // generation still completes.
      if target.value != lastSentRaw {
        // Only a *successful* write means the value is on the wire. Advancing
        // `lastSentRaw` after a failed write would make the next identical
        // target look like a duplicate and get skipped, leaving brightness
        // stuck at the old level until the user moved to a different value.
        if await writer.write(command: VCP.brightness, value: target.value) {
          lastSentRaw = target.value
        }
      }
      complete(target.generation)
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
