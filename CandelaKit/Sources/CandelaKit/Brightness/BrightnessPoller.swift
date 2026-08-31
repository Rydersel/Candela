import CoreGraphics
import Foundation

/// Polls native brightness for displays whose controller is HDR-native,
/// discards echoes of our own writes, and reports real external deltas to the
/// controller (dossier §10, the fork's `refreshBrightness` poll job).
///
/// It never smooths, never writes hardware and never decides staleness:
/// `BrightnessController.adoptExternal` owns the easing and the generation
/// discard.
public actor BrightnessPoller {
  public struct Target: Sendable {
    public let displayID: CGDirectDisplayID
    /// Controller's lock-backed echo slot: the last locally-written native
    /// value and the generation to hand back to `adopt`.
    public let expected: @Sendable () -> (value: Double?, generation: UInt64)
    /// False while the display is mid-HDR-transition or off the native path,
    /// so the poller never reads a blanking or re-moding panel.
    public let isNativeActive: @Sendable () -> Bool
    /// Hops to the main actor inside. The generation was snapshotted before
    /// the read.
    public let adopt: @Sendable (Double, UInt64) -> Void
    /// True while an earlier adoption is still easing toward its target: the
    /// echo discard must be bypassed or the chase never terminates.
    public let isConverging: @Sendable () -> Bool

    public init(
      displayID: CGDirectDisplayID,
      expected: @escaping @Sendable () -> (value: Double?, generation: UInt64),
      isNativeActive: @escaping @Sendable () -> Bool,
      adopt: @escaping @Sendable (Double, UInt64) -> Void,
      isConverging: @escaping @Sendable () -> Bool
    ) {
      self.displayID = displayID
      self.expected = expected
      self.isNativeActive = isNativeActive
      self.adopt = adopt
      self.isConverging = isConverging
    }
  }

  private let targets: [Target]
  private let read: @Sendable (CGDirectDisplayID) -> Double?
  private let isEpochCurrent: @Sendable () -> Bool
  private let fastInterval: Duration
  private let idleInterval: Duration
  private let tolerance: Double

  /// `tolerance` covers Control Center's slider quantization plus the float
  /// round-trip through DisplayServices; larger swallows real external moves.
  public init(
    targets: [Target],
    read: @escaping @Sendable (CGDirectDisplayID) -> Double?,
    isEpochCurrent: @escaping @Sendable () -> Bool,
    fastInterval: Duration = .milliseconds(100),
    idleInterval: Duration = .seconds(1),
    tolerance: Double = 0.008
  ) {
    self.targets = targets
    self.read = read
    self.isEpochCurrent = isEpochCurrent
    self.fastInterval = fastInterval
    self.idleInterval = idleInterval
    self.tolerance = tolerance
  }

  /// Returns on cancellation.
  public func run() async {
    while !Task.isCancelled {
      let moving = tick()
      do {
        try await Task.sleep(for: moving ? fastInterval : idleInterval)
      } catch {
        return
      }
    }
  }

  /// Returns true when any target moved this tick (drives the fast cadence).
  private func tick() -> Bool {
    // Skipped wholesale mid-reconfigure or asleep: display state is being
    // rebuilt, so every read is suspect.
    guard isEpochCurrent() else { return false }
    var moved = false
    for target in targets {
      guard target.isNativeActive() else { continue }
      // Snapshotted BEFORE the read: a local write landing during the read
      // bumps the controller's generation, so the adoption we hand back is
      // discarded as stale rather than clobbering the fresh write.
      let slot = target.expected()
      guard let value = read(target.displayID) else { continue }
      if !target.isConverging(), let expected = slot.value,
         abs(value - expected) <= tolerance {
        continue // our own write echoing back
      }
      target.adopt(value, slot.generation)
      moved = true
    }
    return moved
  }
}
