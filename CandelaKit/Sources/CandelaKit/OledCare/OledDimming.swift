import Foundation

public enum OledDimState: Equatable, Sendable {
  case active, idleDim, blackout, lockDim, unfocusedDim, suspended
}

/// A validated snapshot of one display's dimming settings.
///
/// Every stored property is `private(set)`: the two sanitizations below (level
/// range, blackout ordering) are invariants of the type, not of the caller, and
/// a settable property would make them advisory. Task 7 rebuilds the config
/// from prefs and hands the whole value to `updateConfig`, so nothing needs to
/// mutate a field in place.
public struct OledDimConfig: Equatable, Sendable {
  public private(set) var idleDimSeconds: Double
  public private(set) var idleDimLevel: Double
  public private(set) var lockDim: Bool
  public private(set) var blackoutEnabled: Bool
  public private(set) var blackoutSeconds: Double
  public private(set) var unfocusedDimEnabled: Bool
  public private(set) var unfocusedDimSeconds: Double
  public private(set) var unfocusedDimLevel: Double

  /// A dim of 0 does nothing and a dim of 1 is a silent blackout — one that
  /// would stay click-through, unlike the real thing (OC15). Neither is a
  /// setting anyone means, so both are config errors.
  ///
  /// Public so the pane's sliders offer exactly the range the config accepts;
  /// a control that can express a value this type will silently rewrite is a
  /// control that lies about what it did.
  public static let levelRange: ClosedRange<Double> = 0.1...0.9

  public init(idleDimSeconds: Double, idleDimLevel: Double, lockDim: Bool,
              blackoutEnabled: Bool, blackoutSeconds: Double,
              unfocusedDimEnabled: Bool, unfocusedDimSeconds: Double,
              unfocusedDimLevel: Double) {
    self.idleDimSeconds = idleDimSeconds
    self.idleDimLevel = Self.sanitizedLevel(idleDimLevel)
    self.lockDim = lockDim
    self.blackoutEnabled = blackoutEnabled
    // A blackout that fires at or below the idle threshold is a config error;
    // clamp rather than trust the pane (spec §3).
    self.blackoutSeconds = max(blackoutSeconds, idleDimSeconds + 60)
    self.unfocusedDimEnabled = unfocusedDimEnabled
    self.unfocusedDimSeconds = unfocusedDimSeconds
    self.unfocusedDimLevel = Self.sanitizedLevel(unfocusedDimLevel)
  }

  public init(prefs: DisplayPrefs) {
    self.init(idleDimSeconds: Double(prefs.oledIdleDimSeconds),
              idleDimLevel: prefs.oledIdleDimLevel,
              lockDim: prefs.oledLockDim,
              blackoutEnabled: prefs.oledBlackoutEnabled,
              blackoutSeconds: Double(prefs.oledBlackoutSeconds),
              unfocusedDimEnabled: prefs.oledUnfocusedDimEnabled,
              unfocusedDimSeconds: Double(prefs.oledUnfocusedDimSeconds),
              unfocusedDimLevel: prefs.oledUnfocusedDimLevel)
  }

  /// NaN survives `min(max(…))` untouched, and a NaN alpha is an undefined
  /// overlay rather than a visible error — so it lands mid-range instead.
  private static func sanitizedLevel(_ level: Double) -> Double {
    guard !level.isNaN else { return 0.5 }
    return min(max(level, levelRange.lowerBound), levelRange.upperBound)
  }
}

public struct OledDimSignals: Equatable, Sendable {
  public var idleSeconds: Double
  public var assertionHeld: Bool
  public var isLocked: Bool
  public var isMirrored: Bool
  public var isHDRSettling: Bool
  public var unfocusedSeconds: Double?

  public init(idleSeconds: Double, assertionHeld: Bool, isLocked: Bool,
              isMirrored: Bool, isHDRSettling: Bool, unfocusedSeconds: Double?) {
    self.idleSeconds = idleSeconds
    self.assertionHeld = assertionHeld
    self.isLocked = isLocked
    self.isMirrored = isMirrored
    self.isHDRSettling = isHDRSettling
    self.unfocusedSeconds = unfocusedSeconds
  }
}

/// Spec §3 precedence table. Pure: the coordinator gathers signals and renders
/// the returned state; this type never touches a window or a display.
public struct IdleDimmingEngine: Sendable {
  public private(set) var state: OledDimState = .active
  private var config: OledDimConfig
  private var lastIdleSeconds: Double = 0
  /// Lock dim is edge-armed by the lock notification, lifted by input, and
  /// re-armed by the idle threshold (spec §3 row 2).
  private var lockDimArmed = false

  public init(config: OledDimConfig) { self.config = config }

  public mutating func updateConfig(_ config: OledDimConfig) { self.config = config }
  public mutating func noteLock() { lockDimArmed = true }
  public mutating func noteUnlock() { lockDimArmed = false }
  public mutating func noteWake() { lockDimArmed = false }  // wake beats lock

  public mutating func tick(_ signals: OledDimSignals) -> OledDimState {
    defer { lastIdleSeconds = signals.idleSeconds }
    let inputOccurred = signals.idleSeconds < lastIdleSeconds

    if signals.isMirrored { state = .suspended; return state }

    if signals.isLocked && config.lockDim {
      if inputOccurred { lockDimArmed = false }
      if signals.idleSeconds >= config.idleDimSeconds { lockDimArmed = true }
      state = lockDimArmed ? .lockDim : .active
      return state
    }
    lockDimArmed = false  // not locked (or lock dim off): the edge is stale

    let wasDimmed = state != .active && state != .suspended
    // HDR settle defers entry, never forces exit (spec §8).
    let canEnter = !signals.isHDRSettling || wasDimmed

    if config.blackoutEnabled, !signals.assertionHeld,
       signals.idleSeconds >= config.blackoutSeconds, canEnter {
      state = .blackout
    } else if !signals.assertionHeld,
              signals.idleSeconds >= config.idleDimSeconds, canEnter {
      state = .idleDim
    } else if config.unfocusedDimEnabled, !signals.assertionHeld,
              let unfocused = signals.unfocusedSeconds,
              unfocused >= config.unfocusedDimSeconds, canEnter {
      state = .unfocusedDim
    } else if state == .unfocusedDim, signals.unfocusedSeconds != nil {
      // Global input does not exit unfocused dim; only focus arrival does.
      state = .unfocusedDim
    } else {
      state = .active
    }
    return state
  }

  public func alpha(for state: OledDimState) -> Double? {
    switch state {
    case .idleDim, .lockDim: config.idleDimLevel
    case .blackout: 1.0
    case .unfocusedDim: config.unfocusedDimLevel
    case .active, .suspended: nil
    }
  }
}
