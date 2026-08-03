import CoreGraphics
import Foundation

/// The real `DisplayConfiguring`. Thin on purpose.
public struct CoreGraphicsDisplayConfigurator: DisplayConfiguring {
  public init() {}

  public func displays() -> [ConfiguredDisplay] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
      let isBuiltIn = CGDisplayIsBuiltin(id) != 0
      return ConfiguredDisplay(
        id: id,
        identity: DisplayConfigIdentity(
          vendor: CGDisplayVendorNumber(id),
          model: CGDisplayModelNumber(id),
          serial: CGDisplaySerialNumber(id),
          isBuiltIn: isBuiltIn
        ),
        name: isBuiltIn ? "Built-in Display" : "Display \(id)",
        isBuiltIn: isBuiltIn
      )
    }
  }

  /// Enumerates TWICE and diffs, so `surfacedByMacOS` is measured rather than
  /// assumed. The plain call is what Displays settings shows; the option call
  /// is everything macOS actually computed.
  public func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
    let revealed = copyModes(displayID, revealHidden: true)
    let surfacedIDs = Set(copyModes(displayID, revealHidden: false).map(\.0))
    return revealed.map { ioID, mode in
      Self.displayMode(ioModeID: ioID, mode: mode, surfaced: surfacedIDs.contains(ioID))
    }
  }

  public func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return Self.displayMode(
      ioModeID: mode.ioDisplayModeID, mode: mode,
      surfaced: true
    )
  }

  public func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    guard let native = modes(for: displayID).first(where: \.isNative) else { return nil }
    return (native.pixelWidth, native.pixelHeight)
  }

  public func apply(
    _ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope
  ) throws {
    guard let cgMode = copyModes(displayID, revealHidden: true)
      .first(where: { $0.0 == mode.ioModeID })?.1
    else {
      throw DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
    }

    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let config else {
      // A nil token after a `.success` begin would otherwise be reported as
      // error code 0 — an error that reads as "no error".
      throw DisplayConfigError(
        cgErrorCode: begin == .success ? CGError.failure.rawValue : begin.rawValue
      )
    }
    // Staging is checked, not discarded: if this fails, CGCompleteDisplayConfiguration
    // happily commits the (empty) configuration and returns .success, so `apply`
    // would return normally having changed nothing. Silent no-op is the worst
    // possible outcome for a mode switch — the caller reverts on a throw, and
    // has no other way to learn the mode did not take.
    let staged = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
    guard staged == .success else {
      CGCancelDisplayConfiguration(config)
      throw DisplayConfigError(cgErrorCode: staged.rawValue)
    }
    let option: CGConfigureOption = scope == .preview ? .forAppOnly : .forSession
    let result = CGCompleteDisplayConfiguration(config, option)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }
  }

  // MARK: - Private

  private func copyModes(
    _ displayID: CGDirectDisplayID, revealHidden: Bool
  ) -> [(Int32, CGDisplayMode)] {
    let options: CFDictionary? = revealHidden
      ? [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue as Any] as CFDictionary
      : nil
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      return []
    }
    return raw.map { ($0.ioDisplayModeID, $0) }
  }

  private static func displayMode(
    ioModeID: Int32, mode: CGDisplayMode, surfaced: Bool
  ) -> DisplayMode {
    // kDisplayModeNativeFlag is not exposed in the Swift overlay.
    let nativeFlag: UInt32 = 0x0200_0000
    return DisplayMode(
      ioModeID: ioModeID,
      logicalWidth: mode.width,
      logicalHeight: mode.height,
      pixelWidth: mode.pixelWidth,
      pixelHeight: mode.pixelHeight,
      // Quantized at the boundary — see DisplayMode.quantizedRefresh.
      refreshHz: DisplayMode.quantizedRefresh(mode.refreshRate),
      isNative: (mode.ioFlags & nativeFlag) != 0,
      surfacedByMacOS: surfaced
    )
  }
}
