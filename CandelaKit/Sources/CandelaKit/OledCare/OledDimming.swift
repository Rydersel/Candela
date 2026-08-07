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
///
/// Both `…DimLevel`s are the black overlay's OPACITY — higher is darker, and
/// blackout is the same scale at 1.0. They are not a fraction of the user's
/// brightness, and nothing here writes the display's brightness.
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

  /// Floor for every idle-driven threshold. Below this a "timeout" is
  /// indistinguishable from "always on", and the blackout row derives its own
  /// threshold from the idle one — so an unfloored idle threshold is how a
  /// display ends up blacked out at zero idle with no input to recover it.
  public static let minimumThresholdSeconds: Double = 30

  /// How far above the idle threshold the blackout threshold is forced to sit.
  /// Public for the same reason as the two constants above: the pane's blackout
  /// control derives its own lower bound from this, so it cannot offer a value
  /// this type would silently rewrite.
  public static let blackoutGapSeconds: Double = 60

  public init(idleDimSeconds: Double, idleDimLevel: Double, lockDim: Bool,
              blackoutEnabled: Bool, blackoutSeconds: Double,
              unfocusedDimEnabled: Bool, unfocusedDimSeconds: Double,
              unfocusedDimLevel: Double) {
    // Floored FIRST, so the blackout clamp below compounds off a sane idle
    // threshold: a zero or negative threshold means "dimmed always", and a
    // negative blackout derived from it would black the display out at zero
    // idle — unrecoverable from inside the app.
    self.idleDimSeconds = Self.sanitizedSeconds(idleDimSeconds,
                                                floor: Self.minimumThresholdSeconds)
    self.idleDimLevel = Self.sanitizedLevel(idleDimLevel)
    self.lockDim = lockDim
    self.blackoutEnabled = blackoutEnabled
    // A blackout that fires at or below the idle threshold is a config error;
    // clamp rather than trust the pane (spec §3).
    self.blackoutSeconds = Self.sanitizedSeconds(
      blackoutSeconds, floor: self.idleDimSeconds + Self.blackoutGapSeconds
    )
    self.unfocusedDimEnabled = unfocusedDimEnabled
    self.unfocusedDimSeconds = Self.sanitizedSeconds(unfocusedDimSeconds,
                                                     floor: Self.minimumThresholdSeconds)
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

  /// `max(NaN, floor)` returns NaN — every comparison against it is false, so a
  /// NaN threshold silently disables its row while the field still reads as
  /// floored. The floor is a promise; this is what keeps it.
  private static func sanitizedSeconds(_ seconds: Double, floor: Double) -> Double {
    guard !seconds.isNaN else { return floor }
    return max(seconds, floor)
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
  /// `secondsSinceLastEventType` counts through system sleep, so the first tick
  /// after a wake reports idle time the user never spent awake. Every
  /// idle-driven row measures from this floor instead; input clears it.
  private var idleFloor: Double = 0
  private var idleFloorPending = false

  public init(config: OledDimConfig) { self.config = config }

  public mutating func updateConfig(_ config: OledDimConfig) { self.config = config }

  /// `idleSeconds` is the idle reading AT the lock, and it is required for a
  /// reason: locking is itself input (a shortcut, a menu item, a hot corner),
  /// so the idle counter falls at the lock edge. The lift below reads a falling
  /// counter as "input while locked", and without this baseline the very input
  /// that locked the screen disarmed the dim on the same tick that armed it,
  /// leaving a full-bright lock screen until the idle threshold re-elapsed.
  /// Seeding the baseline keeps the lift honest: only a reading BELOW the one
  /// taken at the lock is input that happened after it.
  public mutating func noteLock(idleSeconds: Double) {
    lockDimArmed = true
    lastIdleSeconds = idleSeconds
  }

  public mutating func noteUnlock() { lockDimArmed = false }

  /// Wake beats lock: the user woke the machine to use it. Disarming alone is
  /// not enough — the stale idle counter would re-arm on the very next tick, so
  /// the floor is what actually makes wake land and STAY `.active`.
  public mutating func noteWake() {
    lockDimArmed = false
    idleFloorPending = true
  }

  public mutating func tick(_ signals: OledDimSignals) -> OledDimState {
    defer { lastIdleSeconds = signals.idleSeconds }
    let inputOccurred = signals.idleSeconds < lastIdleSeconds
    let current = state

    if idleFloorPending {
      idleFloor = signals.idleSeconds
      idleFloorPending = false
    }
    if inputOccurred { idleFloor = 0 }  // a real event: the counter is honest again
    let idleSinceWake = max(0, signals.idleSeconds - idleFloor)

    if signals.isMirrored { state = .suspended; return state }

    if signals.isLocked && config.lockDim {
      if inputOccurred { lockDimArmed = false }
      if idleSinceWake >= config.idleDimSeconds { lockDimArmed = true }
      // Locking never brightens: a display already blacked out stays black
      // rather than rising to lock dim's lighter alpha. The hold re-checks the
      // condition it holds FOR, so it cannot outlive it — an unconditional hold
      // swallows both the wake floor (wake must always land `.active`) and a
      // blackout switched off while the screen is locked.
      if current == .blackout, !inputOccurred, config.blackoutEnabled,
         idleSinceWake >= config.blackoutSeconds {
        state = .blackout
        return state
      }
      state = lockDimArmed ? .lockDim : .active
      return state
    }
    lockDimArmed = false  // not locked (or lock dim off): the edge is stale

    // The assertion and the HDR settle window gate ENTRY only — a dim already
    // up holds through both, and neither forces an exit (spec §3, §8). Lock dim
    // is deliberately outside this gate: it returns above, because a full-bright
    // lock screen during an HDR settle is worse than the settle it defers to,
    // and locking is an explicit user action rather than an inferred idle.
    func mayShow(_ target: OledDimState) -> Bool {
      current == target || (!signals.isHDRSettling && !signals.assertionHeld)
    }

    if config.blackoutEnabled, idleSinceWake >= config.blackoutSeconds, mayShow(.blackout) {
      state = .blackout
    } else if idleSinceWake >= config.idleDimSeconds, mayShow(.idleDim) {
      state = .idleDim
    } else if config.unfocusedDimEnabled,
              let unfocused = signals.unfocusedSeconds,
              unfocused >= config.unfocusedDimSeconds, mayShow(.unfocusedDim) {
      state = .unfocusedDim
    } else {
      state = .active
    }
    return state
  }

  /// The overlay opacity a state calls for, or nil when the state wants no
  /// overlay.
  ///
  /// **`.lockDim` answers nil, and that is the delivery ruling, not an
  /// omission.** A `CGShieldingWindowLevel()` overlay does not render above the
  /// macOS lock screen: MEASURED 2026-08-07, with `loginwindow`'s shield taking
  /// the front of the window list over a window two billion levels above it and
  /// a capture showing the lock screen at full brightness while the overlay
  /// still reported itself on screen. Lock dim is delivered on the wire instead
  /// (`LockDimPolicy` and `BrightnessController.beginTemporaryDim`), so the
  /// overlay layer is structurally unable to produce a lock dim that nobody
  /// could see.
  public func alpha(for state: OledDimState) -> Double? {
    switch state {
    case .idleDim: config.idleDimLevel
    case .blackout: 1.0
    case .unfocusedDim: config.unfocusedDimLevel
    case .lockDim, .active, .suspended: nil
    }
  }

  /// How far down the wire-level lock dim takes this display's brightness,
  /// derived from the same level the idle dim uses.
  public var lockDimFactor: Double {
    LockDimPolicy.factor(forLevel: config.idleDimLevel)
  }
}
