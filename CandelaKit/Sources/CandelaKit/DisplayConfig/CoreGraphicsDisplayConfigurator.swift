import CoreGraphics
import Foundation

/// The real `DisplayConfiguring`. Thin on purpose.
public struct CoreGraphicsDisplayConfigurator: DisplayConfiguring {
  public init() {}

  /// ONLINE, not ACTIVE, and the difference is not academic: a display that has
  /// gone to sleep on the idle timer is still online but is NOT active.
  ///
  /// This list is what `DisplayModeCoordinator` samples to decide whether a
  /// display has DEPARTED, and a departure is what makes the next appearance an
  /// arrival that reapply acts on (DM7). Under the active-only list, every idle
  /// display sleep read as an unplug and every wake as a replug — so with
  /// "Remember this resolution" on, a resolution the user changed in System
  /// Settings mid-session was silently undone the next time their screen slept.
  /// DM7 exists to forbid exactly that.
  ///
  /// It is also what every other enumeration in this codebase uses
  /// (`DisplayDiscovery`, `BuiltInDisplay`, `Mirroring`, `KeyActionExecutor`),
  /// so please do not "correct" this back.
  ///
  /// The price of "online" is that it also includes MIRROR SLAVES, which no
  /// active list would show. Each entry therefore carries `mirrorsDisplay`,
  /// read here rather than by the caller: the mirror state has to describe the
  /// same instant as the list, and a caller asking `CGDisplayMirrorsDisplay`
  /// later is asking about a topology that may already have changed.
  public func displays() -> [ConfiguredDisplay] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
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
        isBuiltIn: isBuiltIn,
        mirrorsDisplay: CGDisplayMirrorsDisplay(id),
        // Both mirror-set calls, in the same loop iteration as everything else:
        // the mirror state has to describe the same instant as the list, and a
        // caller asking later is asking about a topology that may have moved on.
        isInMirrorSet: CGDisplayIsInHWMirrorSet(id) != 0 || CGDisplayIsInMirrorSet(id) != 0,
        isAlwaysInMirrorSet: CGDisplayIsAlwaysInMirrorSet(id) != 0
      )
    }
  }

  /// ONE enumeration, always with `kCGDisplayShowDuplicateLowResolutionModes`.
  ///
  /// Do not add a second, plain call back: it adds no coverage. Despite its
  /// name, the option is what makes HiDPI modes appear at all — the plain call
  /// returns none of them. Measured on three panels: plain gave 60/155/66 modes
  /// with ZERO HiDPI in each, and was a strict subset of the revealed 132/332/120,
  /// the difference being exactly the 72/177/54 HiDPI entries. Diffing the two
  /// therefore computed nothing but `!isHiDPI`, which `DisplayMode` already
  /// derives. Neither list corresponds to what Displays settings shows.
  public func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
    copyModes(displayID).map { ioID, mode in
      Self.displayMode(ioModeID: ioID, mode: mode)
    }
  }

  /// Resolved by LOOKUP into `modes(for:)` rather than constructed fresh from
  /// `CGDisplayCopyDisplayMode`, so the value returned here is guaranteed to be
  /// an element of the list — `==` to its own entry, and findable by `apply`.
  /// A separately-constructed value would merely happen to match, and a picker
  /// that marks the current row by comparing against the list would break on any
  /// field the two paths ever disagreed about.
  ///
  /// The lookup is sound because `IODisplayModeID` stays unique even under
  /// `kCGDisplayShowDuplicateLowResolutionModes` — measured on hardware,
  /// 132/132, 332/332 and 120/120 unique across three panels.
  public func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let ioModeID = mode.ioDisplayModeID
    return modes(for: displayID).first { $0.ioModeID == ioModeID }
  }

  public func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    guard let native = modes(for: displayID).first(where: \.isNative) else { return nil }
    return (native.pixelWidth, native.pixelHeight)
  }

  public func apply(
    _ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope
  ) throws {
    guard let cgMode = copyModes(displayID)
      .first(where: { $0.0 == mode.ioModeID })?.1
    else {
      throw DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
    }
    // `ioModeID` is a POSITIONAL handle, not a stable identity: it is reassigned
    // whenever the display is reconfigured. Between the caller enumerating modes
    // and this call, a replug or a sleep/wake can leave the same ID denoting a
    // different mode — and the lookup above would find it, apply it, and return
    // normally. The caller would then be told its mode was applied while the
    // display sits at some other resolution entirely, which is the one failure
    // neither `ModePreviewSession` nor the reapply path can detect afterwards.
    //
    // The geometry is re-derived from the CGDisplayMode we actually resolved and
    // checked against what was asked for. `refreshHz` is compared with a
    // tolerance for the usual reason (59.997 vs 60); `isNative` is deliberately
    // not compared, since it is not part of the mode's identity.
    let resolved = Self.displayMode(ioModeID: mode.ioModeID, mode: cgMode)
    guard resolved.logicalWidth == mode.logicalWidth,
          resolved.logicalHeight == mode.logicalHeight,
          resolved.pixelWidth == mode.pixelWidth,
          resolved.pixelHeight == mode.pixelHeight,
          ModePersistence.refreshMatches(resolved.refreshHz, mode.refreshHz)
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

  /// The same transaction discipline as `apply`, with the mirror call
  /// substituted for the mode call. Every invariant below exists because the
  /// transplanted `Mirroring.swift` violated it — that file stages its changes,
  /// discards all four return values, and returns `true` regardless.
  public func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    // An empty transaction commits `.success` having changed nothing, which is
    // indistinguishable from having worked. Open nothing.
    guard !changes.isEmpty else { return }

    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let config else {
      // A nil token after a `.success` begin would otherwise be reported as
      // error code 0 — an error that reads as "no error".
      throw DisplayConfigError(
        cgErrorCode: begin == .success ? CGError.failure.rawValue : begin.rawValue
      )
    }
    for change in changes {
      // Staging is CHECKED, not discarded. If it fails,
      // CGCompleteDisplayConfiguration happily commits the (empty)
      // configuration and returns `.success`, so this function would return
      // normally having changed nothing — and the caller's only other way to
      // learn that is the user telling them. Every early exit cancels, so the
      // config ref is never leaked (`Mirroring.swift:16,25` returns without
      // cancelling).
      let staged = CGConfigureDisplayMirrorOfDisplay(config, change.display, change.master)
      guard staged == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: staged.rawValue)
      }
    }
    let option: CGConfigureOption = scope == .preview ? .forAppOnly : .forSession
    // The header notes a complete can fail for reasons that have nothing to do
    // with mirroring — an unsupported mode, or another app running full-screen.
    let result = CGCompleteDisplayConfiguration(config, option)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }
  }

  // MARK: - Private

  /// The option is not optional in practice: without it CoreGraphics returns
  /// only 1x modes, so every HiDPI mode — including the one most displays are
  /// currently running — would be missing from the list entirely.
  private func copyModes(_ displayID: CGDirectDisplayID) -> [(Int32, CGDisplayMode)] {
    let options = [
      kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue as Any,
    ] as CFDictionary
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      return []
    }
    return raw.map { ($0.ioDisplayModeID, $0) }
  }

  private static func displayMode(ioModeID: Int32, mode: CGDisplayMode) -> DisplayMode {
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
      isNative: (mode.ioFlags & nativeFlag) != 0
    )
  }
}
