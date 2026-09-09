import CoreGraphics
import Foundation
import os

let pollLog = Logger(subsystem: "com.rydersel.Candela", category: "poll")

/// Polls native brightness for displays whose controller is HDR-native,
/// discards echoes of our own writes, and reports real external deltas to the
/// controller. Ported from the MonitorControl fork's `refreshBrightness` poll
/// job, the behavior oracle for the echo discard and for the moving/idle pair at
/// the top of the cadence.
///
/// It never smooths, never writes hardware and never decides staleness:
/// `BrightnessController.adoptExternal` owns the easing and the generation
/// discard.
///
/// Unlike the fork, the idle cadence is not one interval: `BrightnessPollCadence`
/// lengthens it when nothing consumes the value. The task itself never stops.
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
    /// Only externals vote on the cadence; see `BrightnessPollCadence.choose`.
    public let isExternal: Bool

    public init(
      displayID: CGDirectDisplayID,
      expected: @escaping @Sendable () -> (value: Double?, generation: UInt64),
      isNativeActive: @escaping @Sendable () -> Bool,
      adopt: @escaping @Sendable (Double, UInt64) -> Void,
      isConverging: @escaping @Sendable () -> Bool,
      isExternal: Bool
    ) {
      self.displayID = displayID
      self.expected = expected
      self.isNativeActive = isNativeActive
      self.adopt = adopt
      self.isConverging = isConverging
      self.isExternal = isExternal
    }
  }

  private let targets: [Target]
  private let read: @Sendable (CGDirectDisplayID) -> Double?
  private let isEpochCurrent: @Sendable () -> Bool
  private let isSyncEnabled: @Sendable () -> Bool
  private let isSurfaceVisible: @Sendable () -> Bool
  private let isOnBattery: @Sendable () -> Bool
  private let fastInterval: Duration
  private let idleInterval: Duration
  private let slowIdleInterval: Duration
  private let batteryIdleInterval: Duration
  private let tolerance: Double
  /// Last cadence reported to the log, so a steady state costs no lines.
  private var lastLoggedCadence: BrightnessPollCadence?

  /// Control Center's slider quantization plus the float round-trip through
  /// DisplayServices; larger swallows real external moves. Public so the pre-step
  /// freshness read shares it.
  public static let defaultTolerance = 0.008

  /// `tolerance` is per instance so a test can widen or narrow it. The consumer
  /// signals are read LIVE on every tick, like the native gate, so a surface
  /// opening or a pref write never needs the job rebuilt.
  public init(
    targets: [Target],
    read: @escaping @Sendable (CGDirectDisplayID) -> Double?,
    isEpochCurrent: @escaping @Sendable () -> Bool,
    isSyncEnabled: @escaping @Sendable () -> Bool,
    isSurfaceVisible: @escaping @Sendable () -> Bool,
    isOnBattery: @escaping @Sendable () -> Bool = { PowerSource.isOnBattery() },
    fastInterval: Duration = .milliseconds(100),
    idleInterval: Duration = .seconds(1),
    slowIdleInterval: Duration = .seconds(10),
    batteryIdleInterval: Duration = .seconds(30),
    tolerance: Double = BrightnessPoller.defaultTolerance
  ) {
    self.targets = targets
    self.read = read
    self.isEpochCurrent = isEpochCurrent
    self.isSyncEnabled = isSyncEnabled
    self.isSurfaceVisible = isSurfaceVisible
    self.isOnBattery = isOnBattery
    self.fastInterval = fastInterval
    self.idleInterval = idleInterval
    self.slowIdleInterval = slowIdleInterval
    self.batteryIdleInterval = batteryIdleInterval
    self.tolerance = tolerance
  }

  /// Returns on cancellation.
  public func run() async {
    while !Task.isCancelled {
      let delay = pollOnce()
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
    }
  }

  /// Performs one poll and returns the delay before the next one.
  func pollOnce() -> Duration {
    let moving = tick()
    let cadence = BrightnessPollCadence.choose(
      isMoving: moving,
      isSyncEnabled: isSyncEnabled(),
      isSurfaceVisible: isSurfaceVisible(),
      // A reconfiguration can skip the read without removing its consumers.
      isExternalNativeActive: externalNativeActive(),
      isOnBattery: isOnBattery()
    )
    let delay = interval(for: cadence)
    log(cadence, sleeping: delay)
    return delay
  }

  /// The idle intervals are otherwise unobservable from outside the process.
  /// `.fast` is not logged: it flips on every adopted value during a drag.
  private func log(_ cadence: BrightnessPollCadence, sleeping: Duration) {
    guard cadence != .fast, cadence != lastLoggedCadence else { return }
    lastLoggedCadence = cadence
    let ms = sleeping.components.seconds * 1000
      + sleeping.components.attoseconds / 1_000_000_000_000_000
    pollLog.info(
      "native poll cadence \(cadence.name, privacy: .public) interval=\(ms, privacy: .public)ms"
    )
  }

  private func externalNativeActive() -> Bool {
    targets.contains { $0.isExternal && $0.isNativeActive() }
  }

  private func interval(for cadence: BrightnessPollCadence) -> Duration {
    switch cadence {
    case .fast: fastInterval
    case .idle: idleInterval
    case .slowIdle: slowIdleInterval
    case .batterySlowIdle: batteryIdleInterval
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
