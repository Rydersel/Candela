import AppKit
import CandelaKit
import os

/// A burst of screen notifications shares one deadline and write allowance.
/// Only the final topology pass, or sleep, starts a new recovery window.
struct GammaRecoveryBudget {
  private var deadline: TimeInterval?
  private var writesRemaining = 8

  mutating func begin(at now: TimeInterval) -> Bool {
    if deadline == nil { deadline = now + 2 }
    return now < deadline! && writesRemaining > 0
  }

  mutating func recordWrite() { writesRemaining = max(0, writesRemaining - 1) }
  mutating func finish() { deadline = nil; writesRemaining = 8 }
}

/// WindowServer can reset gamma after the screen notification but before the
/// one-second topology debounce completes. Follow just that interval, restoring
/// only a cached baseline reset on the same directly drawn SDR display.
@MainActor
final class GammaReconfigurationRecovery {
  private struct HDRObservation: Sendable { let enabled: Bool? }
  private struct Replies: Sendable {
    var generation: UInt64 = 0
    var values: [CGDirectDisplayID: HDRObservation] = [:]
  }

  private let gamma: GammaController
  private let targets: @MainActor () -> [CGDirectDisplayID]
  private let readHDR: @Sendable (CGDirectDisplayID) async -> Bool?
  private let epoch: @Sendable () -> UInt64
  private let asleep: @Sendable () -> Bool
  private let now: @MainActor () -> TimeInterval
  private let interval: TimeInterval
  private let replies = OSAllocatedUnfairLock(initialState: Replies())
  private var hdrTask: Task<Void, Never>?
  private var timer: Timer?
  private var candidates: [CGDirectDisplayID: GammaController.RecoverySnapshot] = [:]
  private var generation: UInt64 = 0
  private var observedEpoch: UInt64 = 0
  private var budget = GammaRecoveryBudget()
  private var inFinalPass = false
  private var pendingNotification = false
  private var stopped = false
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  init(
    gamma: GammaController, targets: @escaping @MainActor () -> [CGDirectDisplayID],
    readHDR: @escaping @Sendable (CGDirectDisplayID) async -> Bool?,
    epoch: @escaping @Sendable () -> UInt64, asleep: @escaping @Sendable () -> Bool,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    interval: TimeInterval = 1.0 / 120.0
  ) {
    self.gamma = gamma; self.targets = targets; self.readHDR = readHDR
    self.epoch = epoch; self.asleep = asleep; self.now = now; self.interval = interval
  }

  @discardableResult
  func begin() -> Task<Void, Never>? {
    guard !stopped else { return nil }
    guard !inFinalPass else { pendingNotification = true; return nil }
    cancelPending()
    guard !asleep() else { budget.finish(); return nil }
    guard budget.begin(at: now()) else { return nil }
    observedEpoch = epoch()
    for id in targets() {
      if let snapshot = gamma.recoverySnapshot(on: id) { candidates[id] = snapshot }
    }
    guard !candidates.isEmpty else { return nil }
    let ids = Array(candidates.keys)
    let generation = generation
    let replies = replies
    let readHDR = readHDR
    // No return hop to the main actor: it may be inside menu tracking. A
    // common-mode timer consumes this mailbox even while the menu is open.
    hdrTask = Task.detached {
      for id in ids {
        guard !Task.isCancelled else { return }
        let enabled = await readHDR(id)
        replies.withLock { state in
          guard state.generation == generation else { return }
          state.values[id] = HDRObservation(enabled: enabled)
        }
      }
    }
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    return hdrTask
  }

  func tick() {
    guard !stopped, !inFinalPass else { return }
    guard !asleep() else { cancelPending(); budget.finish(); return }
    guard budget.begin(at: now()) else { cancelPending(); return }
    guard epoch() == observedEpoch else { begin(); return }
    let observations = replies.withLock { $0.values }
    for (id, snapshot) in Array(candidates) {
      guard let observation = observations[id] else { continue }
      // The raw CG callback bumps this synchronously, including on HDR changes.
      guard epoch() == observedEpoch else { begin(); return }
      guard !asleep(), budget.begin(at: now()) else {
        cancelPending(); return
      }
      switch gamma.recoverBaselineIfReset(snapshot, hdrEnabled: observation.enabled) {
      case .unchanged: break
      case .written:
        budget.recordWrite()
        Self.log.info("Reconfiguration gamma table reasserted for display \(id, privacy: .public)")
      case .stopped:
        gamma.cancelRecovery(snapshot)
        candidates.removeValue(forKey: id)
      }
    }
    if candidates.isEmpty { cancelPending() }
  }

  func beginFinalPass() {
    inFinalPass = true
    pendingNotification = false
    cancelPending()
    budget.finish()
  }

  func endFinalPass() {
    inFinalPass = false
    if pendingNotification { pendingNotification = false; begin() }
  }

  func stop() {
    stopped = true
    cancelPending()
    budget.finish()
  }

  private func cancelPending() {
    generation &+= 1
    let generation = generation
    replies.withLock { $0 = Replies(generation: generation) }
    hdrTask?.cancel(); hdrTask = nil
    timer?.invalidate(); timer = nil
    candidates.removeAll()
  }
}
