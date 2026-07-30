//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Signatures transplanted from the MonitorControl project (MIT):
//  Support/Bridging-Header.h:16-17.
//
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

  /// @convention(c) function types are Sendable, so this struct is Sendable
  /// and safe as a lazily-initialized global under strict concurrency.
  private struct Symbols: Sendable {
    let getBrightness: GetBrightnessFn?
    let setBrightness: SetBrightnessFn?
  }

  private static let log = Logger(subsystem: "app.candela.CandelaKit", category: "DisplayServices")

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
      return Symbols(getBrightness: nil, setBrightness: nil)
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
      setBrightness: resolve("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    )
  }()

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
}
