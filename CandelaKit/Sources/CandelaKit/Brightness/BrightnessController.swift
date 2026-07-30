import Observation
import os

/// Drag-perf diagnostics: one log line per post-coalescing pipeline stage
/// (coalescer receipt, DDC write start/end). Cheap (~30 Hz during a drag) and
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

  public init(writer: any DDCWriting) {
    self.writer = writer
    self.coalescer = BrightnessWriteCoalescer(writer: writer)
  }

  deinit {
    // Ends the coalescer's drain loop (after any buffered write lands) so the
    // coalescer and its task don't outlive the controller.
    coalescer.finishSubmissions()
  }

  public func refreshFromHardware() async {
    guard let result = await writer.read(command: VCP.brightness), result.max > 0 else {
      return
    }
    maxDDCValue = result.max
    brightness = Double(min(result.current, result.max)) / Double(result.max)
  }

  /// Synchronous by design: state updates immediately, hardware writes coalesce
  /// latest-wins — a 60 Hz slider drag must never queue stale DDC writes (each
  /// write holds the DDC actor for ~20 ms, more on retries).
  ///
  /// The hardware write must not require the main actor for any step after
  /// this call returns: during a slider drag the main run loop sits in
  /// event-tracking mode, which starves main-actor task execution until
  /// mouseup — a drain loop started here with `Task {}` (which inherits
  /// MainActor isolation) would never run mid-drag, and even
  /// `Task { await coalescer.submit(...) }` needs a main-actor turn just to
  /// start its body. So the handoff is a synchronous, nonisolated
  /// `AsyncStream` yield; the coalescer drains on the global executor.
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

/// Drains brightness writes to hardware off the main actor, coalescing
/// latest-wins: at most one DDC write in flight, intermediate values dropped,
/// the final value always lands.
///
/// Submission is a synchronous `AsyncStream.Continuation.yield` into a
/// `.bufferingNewest(1)` stream — the buffer *is* the pending-write slot, and
/// yielding never requires an executor hop, so a @MainActor caller can submit
/// while the run loop is stuck in event-tracking mode. The single consumer
/// loop provides "at most one write in flight"; each submitted value carries a
/// monotonic generation so `waitUntilCompleted(through:)` can block until a
/// write at least that new has landed (a newer write superseding an older,
/// dropped value completes the older generation too — latest-wins).
actor BrightnessWriteCoalescer {
  struct PendingWrite: Sendable {
    let value: UInt16
    let generation: UInt64
  }

  private let writer: any DDCWriting
  private nonisolated let continuation: AsyncStream<PendingWrite>.Continuation
  private var lastWrittenValue: UInt16?
  private var completedGeneration: UInt64 = 0
  private var waiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

  init(writer: any DDCWriting) {
    self.writer = writer
    let (stream, continuation) = AsyncStream.makeStream(
      of: PendingWrite.self, bufferingPolicy: .bufferingNewest(1)
    )
    self.continuation = continuation
    // Detached so the drain loop starts on the global executor regardless of
    // where the controller was created; a plain `Task {}` here could inherit
    // isolation from the initializing context.
    Task.detached { await self.drain(stream) }
  }

  /// Synchronous and nonisolated on purpose — see the type comment.
  /// Generations must be issued monotonically by the (single) submitter.
  nonisolated func submit(_ write: PendingWrite) {
    continuation.yield(write)
  }

  /// Ends the drain loop once every already-submitted write has landed.
  nonisolated func finishSubmissions() {
    continuation.finish()
  }

  /// Suspends until a write with generation >= `generation` has completed.
  /// Returns immediately for generation 0 (nothing was ever submitted).
  func waitUntilCompleted(through generation: UInt64) async {
    guard generation > completedGeneration else { return }
    await withCheckedContinuation { waiters.append((generation, $0)) }
  }

  private func drain(_ stream: AsyncStream<PendingWrite>) async {
    for await write in stream {
      dragPerfLog.log("coalescer.receive raw=\(write.value) gen=\(write.generation)")
      // Never rewrite the value already on the wire (mirrors the MonitorControl
      // fork's `writeDDCLastSavedValue` guard). Measured on hardware (MAG341C,
      // task-7 fix round 2): a drag produces gesture ticks faster than the
      // ~30 ms DDC transaction, so without this guard the drain re-sends the
      // same raw value back-to-back, saturating the I2C bus for the whole
      // drag — and the monitor defers *applying* VCP brightness until the bus
      // quiets, i.e. nothing visibly changes until mouseup even though every
      // write returns success. Skipping duplicates restores idle gaps whenever
      // the value holds still — the traffic shape the fork produces and the
      // monitor demonstrably tracks live.
      if write.value != lastWrittenValue {
        _ = await writer.write(command: VCP.brightness, value: write.value)
        lastWrittenValue = write.value
      }
      completedGeneration = max(completedGeneration, write.generation)
      resumeSatisfiedWaiters()
    }
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
