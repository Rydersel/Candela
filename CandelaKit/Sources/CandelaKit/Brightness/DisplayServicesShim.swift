// dlsym-loaded shims for the private DisplayServices.framework C API
// (spec §4: no linker flags against private frameworks, no unsafeFlags).

import CoreGraphics
import Darwin
import os

/// Namespace for the DisplayServices private C API. Every call is
/// optional-/Bool-returning; a missing framework or symbol degrades to
/// nil/false and logs once at resolve time (spec §6).
public enum DisplayServices {
  private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
  /// Whether the display has ambient light compensation at all. Takes the
  /// display alone: called with a spare second register argument it leaves the
  /// buffer behind it untouched [MEASURED 2026-08-19].
  private typealias HasAmbientFn = @convention(c) (CGDirectDisplayID) -> Bool
  private typealias GetAmbientFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<UInt8>) -> Int32
  private typealias SetAmbientFn = @convention(c) (CGDirectDisplayID, UInt8) -> Int32

  /// @convention(c) function types are Sendable, so this struct is Sendable
  /// and safe as a lazily-initialized global under strict concurrency.
  private struct Symbols: Sendable {
    let getBrightness: GetBrightnessFn?
    let setBrightness: SetBrightnessFn?
    let hasAmbient: HasAmbientFn?
    let getAmbient: GetAmbientFn?
    let setAmbient: SetAmbientFn?
  }

  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "DisplayServices")

  /// Resolved once, thread-safely (static-let semantics). The dlopen handle is
  /// deliberately not stored: we never dlclose a system framework, and a stored
  /// UnsafeMutableRawPointer global would trip Sendable checking.
  ///
  /// The binary is not on disk (dyld shared cache since Big Sur) — never gate
  /// on FileManager.fileExists, only on the dlopen result.
  private static let symbols: Symbols = {
    guard let handle = dlopen(
      "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    ) else {
      log.error("DisplayServices.framework failed to dlopen; native brightness disabled (degrading to DDC/software)")
      return Symbols(getBrightness: nil, setBrightness: nil,
                     hasAmbient: nil, getAmbient: nil, setAmbient: nil)
    }
    func resolve<T>(_ name: String, as _: T.Type) -> T? {
      guard let sym = dlsym(handle, name) else {
        log.error("DisplayServices symbol \(name, privacy: .public) missing; call sites will degrade")
        return nil
      }
      return unsafeBitCast(sym, to: T.self)
    }
    return Symbols(
      getBrightness: resolve("DisplayServicesGetBrightness", as: GetBrightnessFn.self),
      setBrightness: resolve("DisplayServicesSetBrightness", as: SetBrightnessFn.self),
      hasAmbient: resolve("DisplayServicesHasAmbientLightCompensation", as: HasAmbientFn.self),
      getAmbient: resolve("DisplayServicesAmbientLightCompensationEnabled", as: GetAmbientFn.self),
      setAmbient: resolve("DisplayServicesEnableAmbientLightCompensation", as: SetAmbientFn.self)
    )
  }()

  /// Whether DisplayServices.framework resolved at all on this machine (B6).
  ///
  /// The shim logs ONCE at resolve time if the framework or a symbol is
  /// missing and then degrades silently to nil/false forever — correct
  /// behaviour, and completely invisible: "native brightness cannot work on
  /// this machine at all" is a fact the process learns on first use and, until
  /// now, could not state. Two lines make it sayable, which is the project's
  /// private-API rule (spec §6) made VISIBLE rather than merely obeyed.
  ///
  /// Keyed on `setBrightness` rather than on both symbols because setting is
  /// what the native path requires: a machine that resolves the setter but not
  /// the getter can still drive brightness, and reporting that as unavailable
  /// would be a second untruth in the other direction.
  ///
  /// Reading this forces the lazy resolve — i.e. one `dlopen` of a system
  /// framework, on whatever thread asks first, thereafter cached by static-let
  /// semantics. No new calls into the private API itself.
  public static var isAvailable: Bool { symbols.setBrightness != nil }

  /// Conformance-only granularity: `isAvailable` is deliberately keyed on the
  /// setter alone, so a getter that vanished in a macOS update would hide
  /// behind it. `PlatformConformance` reads both.
  static var resolvedGetter: Bool { symbols.getBrightness != nil }
  static var resolvedSetter: Bool { symbols.setBrightness != nil }

  /// nil when the symbol is unavailable, the call fails, or the value is
  /// out of range (fork convention: success == (ret == 0 && value >= 0),
  /// OtherDisplay.swift:330).
  public static func getBrightness(for displayID: CGDirectDisplayID) -> Float? {
    guard let fn = symbols.getBrightness else { return nil }
    var value: Float = -1
    guard fn(displayID, &value) == 0, value >= 0 else { return nil }
    return value
  }

  /// false when the symbol is unavailable or the call fails. Callers must
  /// treat false as "degrade to DDC/software", never crash (spec §6).
  ///
  /// Serialization is the caller's job: the fork serialized SetBrightness on a
  /// per-display queue (AppleDisplay.swift:27); in Candela set calls route
  /// through the per-display write path, and this shim stays a stateless
  /// function table.
  @discardableResult
  public static func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
    guard let fn = symbols.setBrightness else { return false }
    return fn(displayID, min(max(value, 0), 1)) == 0
  }

  /// The ambient-compensation symbols, wrapped for `AmbientLightCompensation`.
  ///
  /// The wrapping is where the C conventions stop: a missing symbol becomes a
  /// nil member rather than a call that silently does nothing, a failing read
  /// becomes nil rather than a zero byte the call never wrote, and the
  /// setter's return code is dropped at the boundary so no caller can mistake
  /// it for the achieved state.
  static let ambientLightSymbols: AmbientLightSymbols = {
    var table = AmbientLightSymbols()
    if let hasAmbient = symbols.hasAmbient {
      let query: AmbientLightSymbols.SensorQuery = { displayID in hasAmbient(displayID) }
      table.hasSensor = query
    }
    if let getAmbient = symbols.getAmbient {
      let read: AmbientLightSymbols.Read = { displayID in
        var value: UInt8 = 0
        guard getAmbient(displayID, &value) == 0 else { return nil }
        return value != 0
      }
      table.read = read
    }
    if let setAmbient = symbols.setAmbient {
      let write: AmbientLightSymbols.Write = { displayID, enabled in
        _ = setAmbient(displayID, enabled ? 1 : 0)
      }
      table.write = write
    }
    return table
  }()
}
