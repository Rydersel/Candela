// macOS's own ambient auto-brightness, the switch System Settings calls
// "Automatically adjust brightness", over the private DisplayServices C API.
//
// macOS is the store. Candela persists nothing here and mirrors nothing into a
// pref: every answer is read live, the same one-source-of-truth shape login
// items get from SMAppService. A mirror would only be correct until something
// outside the app moved the setting, and System Settings moves it constantly.

import CoreGraphics

/// The DisplayServices entry points this feature needs, as an injectable
/// table.
///
/// A nil member models a symbol that failed to resolve. That is the whole
/// reason this is a value rather than three direct calls: the degraded case
/// has to be reachable from a test, not only from a future macOS release that
/// drops one of the symbols.
public struct AmbientLightSymbols: Sendable {
  /// Whether the display has ambient light compensation at all.
  public typealias SensorQuery = @Sendable (CGDirectDisplayID) -> Bool
  /// The live setting, or nil when macOS declines to answer.
  ///
  /// Nil is not "off". A failing read leaves its out-parameter untouched
  /// [MEASURED 2026-08-19: a sentinel byte survives the call on both
  /// externals], so a non-zero return carries no state at all and must never
  /// be folded into false.
  public typealias Read = @Sendable (CGDirectDisplayID) -> Bool?
  /// Requests a new setting. The return value is deliberately dropped: an ACK
  /// is evidence of nothing, so callers re-read for the achieved state.
  public typealias Write = @Sendable (CGDirectDisplayID, Bool) -> Void

  public var hasSensor: SensorQuery?
  public var read: Read?
  public var write: Write?

  public init(hasSensor: SensorQuery? = nil, read: Read? = nil, write: Write? = nil) {
    self.hasSensor = hasSensor
    self.read = read
    self.write = write
  }

  /// Every symbol missing: the shape of a macOS release that dropped them, and
  /// of a machine where the framework itself fails to open.
  public static let none = AmbientLightSymbols()
}

/// Reads and writes macOS's ambient auto-brightness for one display at a time.
public struct AmbientLightCompensation: Sendable {
  private let symbols: AmbientLightSymbols

  public init(symbols: AmbientLightSymbols) {
    self.symbols = symbols
  }

  /// The real DisplayServices symbols.
  public static let live = AmbientLightCompensation(symbols: DisplayServices.ambientLightSymbols)

  /// Whether to offer the control for this display at all.
  ///
  /// Three conditions, all load-bearing. Without the reader no achieved state
  /// can ever be published, so the switch could only ever show what was asked
  /// for. Without the writer the control cannot do the one thing it exists
  /// for. And without the sensor there is nothing for it to act on.
  ///
  /// The sensor question prefers `DisplayServicesHasAmbientLightCompensation`,
  /// which answers it directly [MEASURED 2026-08-19: true on the built-in,
  /// false on both externals, and it leaves a passed buffer untouched, so it
  /// takes the display alone]. When that symbol is absent the reader's own
  /// success stands in: the getter returns 0 on the built-in and
  /// kIOReturnError (-536870212) on a display with no sensor, so its success
  /// is the same signal one step removed. That fallback is what a competitor
  /// ships as its only check; having both means losing either symbol costs a
  /// degraded answer rather than the feature.
  public func supports(_ displayID: CGDirectDisplayID) -> Bool {
    guard let read = symbols.read, symbols.write != nil else { return false }
    if let hasSensor = symbols.hasSensor { return hasSensor(displayID) }
    return read(displayID) != nil
  }

  /// What macOS reports for this display, or nil when it will not say.
  public func isEnabled(_ displayID: CGDirectDisplayID) -> Bool? {
    symbols.read?(displayID)
  }

  /// Requests `enabled`, then reports what macOS says afterwards.
  ///
  /// The returned value is measured, never the requested one: a display that
  /// coerces or ignores the write reports the state it actually reached, and
  /// the caller publishes that. Returns nil when macOS will not answer, which
  /// leaves the caller with nothing true to show.
  @discardableResult
  public func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool? {
    guard supports(displayID), let write = symbols.write else { return isEnabled(displayID) }
    write(displayID, enabled)
    return isEnabled(displayID)
  }
}
