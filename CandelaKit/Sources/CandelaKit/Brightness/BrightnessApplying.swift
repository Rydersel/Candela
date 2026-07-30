import CoreGraphics
import os

/// Wiring-bug diagnostics for the appliers: a mismatched target kind means
/// path selection handed a target to the wrong applier.
private let applierLog = Logger(subsystem: "com.rydersel.Candela", category: "applier")

/// One hardware brightness endpoint's target value. `Equatable` so the
/// coalescer's duplicate-skip compares what actually hits hardware,
/// independent of which applier carries the write.
public enum HardwareTarget: Sendable, Equatable {
  /// Raw DDC brightness value (0...maxDDCValue), written to VCP 0x10.
  case ddc(raw: UInt16)
  /// Native Apple-display brightness in 0...1 (DisplayServices).
  case native(Float)
}

/// Applies one hardware brightness target. Implementations serialize their
/// own I/O.
public protocol BrightnessApplying: Sendable {
  func apply(_ target: HardwareTarget) async -> Bool
}

/// Wraps the existing per-display DDC actor. A `.native` target is a
/// path-selection wiring bug: rejected (`false`), logged once.
public struct DDCBrightnessApplier: BrightnessApplying {
  private static let mismatchLogged = OSAllocatedUnfairLock(initialState: false)
  private let writer: any DDCWriting

  public init(writer: any DDCWriting) {
    self.writer = writer
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .ddc(raw) = target else {
      logMismatchOnce(Self.mismatchLogged, "DDCBrightnessApplier received a .native target")
      return false
    }
    return await writer.write(command: VCP.brightness, value: raw)
  }
}

/// Native-brightness applier over an injected apply closure — the app injects
/// `DisplayServices.setBrightness`; injection keeps this type (and CandelaKit
/// tests) independent of the private-framework shim. A `.ddc` target is a
/// path-selection wiring bug: rejected (`false`), logged once.
public struct NativeBrightnessApplier: BrightnessApplying {
  private static let mismatchLogged = OSAllocatedUnfairLock(initialState: false)
  private let displayID: CGDirectDisplayID
  private let applyNative: @Sendable (Float, CGDirectDisplayID) -> Bool

  public init(displayID: CGDirectDisplayID, apply: @escaping @Sendable (Float, CGDirectDisplayID) -> Bool) {
    self.displayID = displayID
    self.applyNative = apply
  }

  public func apply(_ target: HardwareTarget) async -> Bool {
    guard case let .native(value) = target else {
      logMismatchOnce(Self.mismatchLogged, "NativeBrightnessApplier received a .ddc target")
      return false
    }
    return applyNative(value, displayID)
  }
}

/// Logs `message` only the first time its flag is seen unset: a wiring bug is
/// worth exactly one log line, not one per coalesced write (which arrive at
/// ~30 Hz during a drag).
private func logMismatchOnce(_ flag: OSAllocatedUnfairLock<Bool>, _ message: String) {
  let firstTime = flag.withLock { logged -> Bool in
    if logged { return false }
    logged = true
    return true
  }
  if firstTime {
    applierLog.error("\(message, privacy: .public) — path-selection wiring bug")
  }
}
