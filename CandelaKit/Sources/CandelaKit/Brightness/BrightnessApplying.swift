import CoreGraphics
import os

/// Wiring-bug diagnostics for the appliers: a mismatched target kind means
/// path selection handed a target to the wrong applier.
let applierLog = Logger(subsystem: "com.rydersel.Candela", category: "applier")

/// One hardware brightness endpoint's target value. `Equatable` so the
/// coalescer's duplicate-skip compares what actually hits hardware,
/// independent of which applier carries the write.
public enum HardwareTarget: Sendable, Equatable {
  /// Raw DDC value (0...maxDDCValue) for the applier's command — brightness
  /// VCP 0x10 by default, but a remapped or non-brightness command's raw
  /// rides the same case; the code lives with the writer, not here.
  case ddc(raw: UInt16)
  /// Native Apple-display brightness in 0...1 (DisplayServices).
  case native(Float)
}

/// Applies one hardware brightness target. Implementations serialize their
/// own I/O.
public protocol BrightnessApplying: Sendable {
  func apply(_ target: HardwareTarget) async -> Bool
}

/// Native-brightness applier over an injected apply closure — the app injects
/// `DisplayServices.setBrightness`; injection keeps this type (and CandelaKit
/// tests) independent of the private-framework shim. A `.ddc` target is a
/// path-selection wiring bug: rejected (`false`), logged once per instance.
public struct NativeBrightnessApplier: BrightnessApplying {
  /// Per-instance, not static (review M2): with multiple displays a static
  /// flag would let the first display's wiring bug suppress the log for all
  /// others. Copies share the lock's heap storage, so copies of one instance
  /// still log once; the per-submit-constructed applier logs once per
  /// affected write — acceptable, since a live wiring bug is a must-fix.
  private let mismatchLogged = OSAllocatedUnfairLock(initialState: false)
  private let displayID: CGDirectDisplayID
  private let applyNative: @Sendable (Float, CGDirectDisplayID) -> Bool

  public init(displayID: CGDirectDisplayID, apply: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool) {
    self.displayID = displayID
    self.applyNative = apply
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .native(value) = target else {
      logMismatchOnce(mismatchLogged, "NativeBrightnessApplier received a .ddc target")
      return false
    }
    return applyNative(value, displayID)
  }
}

/// Logs `message` only the first time its (per-instance) flag is seen unset:
/// repeated mismatches on the same applier instance produce one line.
func logMismatchOnce(_ flag: OSAllocatedUnfairLock<Bool>, _ message: String) {
  let firstTime = flag.withLock { logged -> Bool in
    if logged { return false }
    logged = true
    return true
  }
  if firstTime {
    applierLog.error("\(message, privacy: .public) (path-selection wiring bug)")
  }
}
