// macOS's own ambient auto-brightness, the switch System Settings calls
// "Automatically adjust brightness", over the private DisplayServices C API.
//
// macOS is the store: every answer is read live and nothing is mirrored into a
// pref, the same one-source-of-truth shape login items get from SMAppService. A
// mirror would only be correct until System Settings moved the setting.

import CoreGraphics

/// The DisplayServices entry points this feature needs, as an injectable table.
/// A nil member models a symbol that failed to resolve, which is why this is a value
/// rather than three direct calls: a test has to be able to reach the degraded case,
/// not only a future macOS release that drops a symbol.
public struct AmbientLightSymbols: Sendable {
  /// Whether the display has ambient light compensation at all.
  public typealias SensorQuery = @Sendable (CGDirectDisplayID) -> Bool
  /// The live setting, or nil when macOS declines to answer.
  ///
  /// Nil is not "off". A failing read leaves its out-parameter untouched
  /// [MEASURED 2026-08-19: a sentinel byte survives the call on both externals], so
  /// a non-zero return carries no state and must never be folded into false.
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
  /// All three symbols are load-bearing: without the reader no achieved state can be
  /// published, without the writer the control cannot act, and without the sensor
  /// there is nothing to act on.
  ///
  /// Prefers `DisplayServicesHasAmbientLightCompensation`, which answers directly
  /// [MEASURED 2026-08-19: true on the built-in, false on both externals, and it
  /// leaves a passed buffer untouched]. Without that symbol the reader's own success
  /// stands in: the getter returns 0 on the built-in and kIOReturnError (-536870212)
  /// on a display with no sensor, so its success is the same signal one step
  /// removed.
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
  /// coerces or ignores the write reports the state it actually reached. Nil when
  /// macOS will not answer, which leaves the caller nothing true to show.
  @discardableResult
  public func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool? {
    guard supports(displayID), let write = symbols.write else { return isEnabled(displayID) }
    write(displayID, enabled)
    return isEnabled(displayID)
  }
}
