import Foundation

public enum OledDimState: Equatable, Sendable {
  case active, idleDim, blackout, lockDim, unfocusedDim, suspended
}

/// A validated snapshot of one display's dimming settings.
///
/// Every stored property is `private(set)`: the sanitizations below (level
/// range, blackout ordering) are invariants of the type, not of the caller, and
/// a settable property would make them advisory. Callers rebuild the whole value
/// and hand it to `updateConfig`.
///
/// Both `…DimBrightness` values are HOW BRIGHT the display is left while dimmed:
/// 0.1 is darkest, 0.9 barely dimmed. The overlay's opacity is their complement
/// (`alpha(for:)`), and blackout is opacity 1.0. The overlay path never writes
/// the display's own brightness; the lock dim, which does, uses this number as
/// the fraction of the user's brightness to keep.
public struct OledDimConfig: Equatable, Sendable {
  public private(set) var idleDimSeconds: Double
  public private(set) var idleDimBrightness: Double
  public private(set) var lockDim: Bool
  public private(set) var blackoutEnabled: Bool
  public private(set) var blackoutSeconds: Double
  public private(set) var unfocusedDimEnabled: Bool
  public private(set) var unfocusedDimSeconds: Double
  public private(set) var unfocusedDimBrightness: Double

  /// A brightness of 1 dims nothing and a brightness of 0 is a silent blackout,
  /// one that would stay click-through unlike the real thing (OC15). Both are
  /// config errors.
  ///
  /// Public so the pane's sliders offer exactly the range the config accepts: a
  /// control that can express a value this type rewrites is a control that lies
  /// about what it did.
  public static let brightnessRange: ClosedRange<Double> = 0.1...0.9

  /// Floor for every idle-driven threshold. Below this a "timeout" is
  /// indistinguishable from "always on", and the blackout row derives its own
  /// threshold from the idle one, so an unfloored idle threshold blacks a
  /// display out at zero idle with no input to recover it.
  public static let minimumThresholdSeconds: Double = 30

  /// How far above the idle threshold the blackout threshold is forced to sit.
  /// Public for the same reason as the two constants above: the pane's blackout
  /// control derives its own lower bound from it.
  public static let blackoutGapSeconds: Double = 60

  public init(idleDimSeconds: Double, idleDimBrightness: Double, lockDim: Bool,
              blackoutEnabled: Bool, blackoutSeconds: Double,
              unfocusedDimEnabled: Bool, unfocusedDimSeconds: Double,
              unfocusedDimBrightness: Double) {
    // Floored FIRST so the blackout clamp compounds off a sane idle threshold:
    // a zero or negative threshold means "dimmed always", and a negative
    // blackout derived from it blacks the display out at zero idle,
    // unrecoverable from inside the app.
    self.idleDimSeconds = Self.sanitizedSeconds(idleDimSeconds,
                                                floor: Self.minimumThresholdSeconds)
    self.idleDimBrightness = Self.sanitizedBrightness(idleDimBrightness)
    self.lockDim = lockDim
    self.blackoutEnabled = blackoutEnabled
    // A blackout at or below the idle threshold is a config error; clamp
    // rather than trust the pane.
    self.blackoutSeconds = Self.sanitizedSeconds(
      blackoutSeconds, floor: self.idleDimSeconds + Self.blackoutGapSeconds
    )
    self.unfocusedDimEnabled = unfocusedDimEnabled
    self.unfocusedDimSeconds = Self.sanitizedSeconds(unfocusedDimSeconds,
                                                     floor: Self.minimumThresholdSeconds)
    self.unfocusedDimBrightness = Self.sanitizedBrightness(unfocusedDimBrightness)
  }

  public init(prefs: DisplayPrefs) {
    self.init(idleDimSeconds: Double(prefs.oledIdleDimSeconds),
              idleDimBrightness: prefs.oledIdleDimBrightness,
              lockDim: prefs.oledLockDim,
              blackoutEnabled: prefs.oledBlackoutEnabled,
              blackoutSeconds: Double(prefs.oledBlackoutSeconds),
              unfocusedDimEnabled: prefs.oledUnfocusedDimEnabled,
              unfocusedDimSeconds: Double(prefs.oledUnfocusedDimSeconds),
              unfocusedDimBrightness: prefs.oledUnfocusedDimBrightness)
  }

  /// NaN survives `min(max(…))` untouched, and a NaN alpha is an undefined
  /// overlay rather than a visible error, so it lands mid-range instead.
  private static func sanitizedBrightness(_ brightness: Double) -> Double {
    guard !brightness.isNaN else { return 0.5 }
    return min(max(brightness, brightnessRange.lowerBound), brightnessRange.upperBound)
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
  /// A checkup field is on this panel. The field and every care overlay sit at
  /// the same `CGShieldingWindowLevel()`, so a dim that won the ordering would
  /// be graded as part of the panel.
  public var isCheckupFieldShowing: Bool

  public init(idleSeconds: Double, assertionHeld: Bool, isLocked: Bool,
              isMirrored: Bool, isHDRSettling: Bool, unfocusedSeconds: Double?,
              isCheckupFieldShowing: Bool = false) {
    self.idleSeconds = idleSeconds
    self.assertionHeld = assertionHeld
    self.isLocked = isLocked
    self.isMirrored = isMirrored
    self.isHDRSettling = isHDRSettling
    self.unfocusedSeconds = unfocusedSeconds
    self.isCheckupFieldShowing = isCheckupFieldShowing
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

  /// `idleSeconds` is the idle reading AT the lock, and it is required: locking
  /// is itself input (a shortcut, a menu item, a hot corner), so the idle
  /// counter falls at the lock edge. The lift below reads a falling counter as
  /// "input while locked", so without this baseline the very input that locked
  /// the screen disarms the dim on the tick that armed it. Only a reading BELOW
  /// the one taken at the lock is input that happened after it.
  public mutating func noteLock(idleSeconds: Double) {
    lockDimArmed = true
    lastIdleSeconds = idleSeconds
  }

  public mutating func noteUnlock() { lockDimArmed = false }

  /// Wake beats lock: the user woke the machine to use it. Disarming alone is
  /// not enough, since the stale idle counter would re-arm on the next tick, so
  /// the floor is what makes wake land and STAY `.active`.
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

    // Ahead of the lock branch on purpose: the lock dim goes on the WIRE, so a
    // field on a locked panel would be dimmed by a route no window ordering
    // could save.
    if signals.isMirrored || signals.isCheckupFieldShowing { state = .suspended; return state }

    if signals.isLocked && config.lockDim {
      if inputOccurred { lockDimArmed = false }
      if idleSinceWake >= config.idleDimSeconds { lockDimArmed = true }
      // A blacked-out display that gets locked drops to `.lockDim`, and that IS
      // ruling D (locking never brightens) rather than a violation of it.
      //
      // The hold this replaces (A-3) kept `.blackout` so the panel would not
      // rise to lock dim's lighter level. It could not: `.blackout` is delivered
      // ONLY by an overlay, and A-16 measured that no overlay of ours renders
      // above the lock screen, so the held blackout put the panel at the
      // FULL-BRIGHT lock screen. `.lockDim` goes on the wire, which the lock
      // screen cannot cover, so it is strictly darker.
      state = lockDimArmed ? .lockDim : .active
      return state
    }
    lockDimArmed = false  // not locked (or lock dim off): the edge is stale

    // The assertion and the HDR settle window gate ENTRY only: a dim already up
    // holds through both, and neither forces an exit. Lock dim is deliberately
    // outside this gate (it returns above), because a full-bright lock screen
    // during an HDR settle is worse than the settle it defers to.
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
  /// macOS lock screen [MEASURED 2026-08-07]: `loginwindow`'s shield took the
  /// front of the window list over a window two billion levels above it, and a
  /// capture showed the lock screen at full brightness while the overlay still
  /// reported itself on screen. Lock dim goes on the wire instead
  /// (`LockDimPolicy`, `BrightnessController.beginTemporaryDim`).
  public func alpha(for state: OledDimState) -> Double? {
    switch state {
    // The COMPLEMENT: the config carries how bright the display is left, the
    // overlay needs how much to cover it with.
    case .idleDim: 1 - config.idleDimBrightness
    case .blackout: 1.0
    case .unfocusedDim: 1 - config.unfocusedDimBrightness
    case .lockDim, .active, .suspended: nil
    }
  }

  /// How far down the wire-level lock dim takes this display's brightness,
  /// derived from the same level the idle dim uses.
  public var lockDimFactor: Double {
    LockDimPolicy.factor(forBrightness: config.idleDimBrightness)
  }
}
