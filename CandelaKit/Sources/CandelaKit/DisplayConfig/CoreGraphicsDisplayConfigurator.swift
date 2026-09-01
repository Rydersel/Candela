import CoreGraphics
import Foundation
import os

/// The real `DisplayConfiguring`. Thin on purpose.
public struct CoreGraphicsDisplayConfigurator: DisplayConfiguring {
  public init() {}

  /// ONLINE, not ACTIVE, and the difference is not academic: a display asleep
  /// on the idle timer is still online but is NOT active.
  ///
  /// `DisplayModeCoordinator` samples this list to decide whether a display has
  /// DEPARTED, and a departure is what makes the next appearance an arrival that
  /// reapply acts on (DM7). Under the active-only list every idle display sleep
  /// read as an unplug and every wake as a replug, so with "Remember this
  /// resolution" on, a resolution the user changed in System Settings mid-session
  /// was silently undone the next time their screen slept. Every other
  /// enumeration in this codebase uses the online list too (`DisplayDiscovery`,
  /// `BuiltInDisplay`, `KeyActionExecutor`), so do not "correct" this back.
  ///
  /// The price of "online" is that it includes MIRROR SLAVES, which no active
  /// list would show. Each entry therefore carries `mirrorsDisplay`, read here
  /// rather than by the caller: the mirror state has to describe the same instant
  /// as the list.
  public func displays() -> [ConfiguredDisplay] {
    // 32 to match `DisplayDiscovery`: virtual displays fill this buffer before
    // anything filters them out.
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
      // `!= 0` is safe HERE only because `id` came out of the line above.
      // `CGDisplayIsBuiltin` returns **-1**, not 0, for an ID it does not know
      // (measured on the mirroring hardware pass §4.2), so this test calls any
      // unknown ID "the built-in": it once refused a probe because it believed
      // display 99999 was the laptop panel. Every `CGDisplayIsBuiltin` call in
      // this package reads an ID it just got from `CGGetOnlineDisplayList`; keep
      // it that way rather than hardening the test.
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
        // Same loop iteration as the list: the mirror state has to describe the
        // same instant, and a caller asking later asks about a topology that may
        // have moved on.
        isInMirrorSet: CGDisplayIsInHWMirrorSet(id) != 0 || CGDisplayIsInMirrorSet(id) != 0,
        isAlwaysInMirrorSet: CGDisplayIsAlwaysInMirrorSet(id) != 0
      )
    }
  }

  /// ONE enumeration, always with `kCGDisplayShowDuplicateLowResolutionModes`.
  ///
  /// Do not add a second, plain call back. Despite its name, the option is what
  /// makes HiDPI modes appear at all: measured on three panels, plain gave
  /// 60/155/66 modes with ZERO HiDPI and was a strict subset of the revealed
  /// 132/332/120, the difference being exactly the HiDPI entries. Diffing the
  /// two computed nothing but `!isHiDPI`, which `DisplayMode` already derives.
  /// Neither list corresponds to what Displays settings shows.
  public func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
    let (published, revealed) = enumerate(displayID)
    // Collapse AFTER the merge, not inside `copyModes`. Revelation dedupes
    // against the published IDs, so a twin removed before it ran would free its
    // ID and come back wearing the revealed badge. Its own gates would reject it
    // today, but that is a fact about this hardware, not about the ordering.
    return DisplayModeList.deduplicated(published + (revealed?.modes ?? []))
  }

  public func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int {
    enumerate(displayID).revealed?.dropped.noNativeParentTiming ?? 0
  }

  /// The CoreGraphics list, and the revelation pass over it when one ran.
  ///
  /// Split out from `modes(for:)` so the drop counts survive the call: they are
  /// the only account of what the wire-timing guard withheld (CR11).
  // Internal rather than private because `PlatformConformance` needs the
  // published list and the revelation result SEPARATELY. The subset cross-check
  // is only meaningful against modes CoreGraphics computed on its own; a
  // revealed mode agreeing with the CGS entry it was built from proves nothing.
  func enumerate(
    _ displayID: CGDirectDisplayID
  ) -> (published: [DisplayMode], revealed: CGSModeRevelation.RevelationResult?) {
    let published = copyModes(displayID).map { ioID, mode in
      Self.displayMode(ioModeID: ioID, mode: mode)
    }
    guard revealsHiddenModes else { return (published, nil) }

    // The native mode MUST be found in the CoreGraphics list alone.
    //
    // `nativePixels(for:)` is a lookup into `modes(for:)`, so deriving the aspect
    // reference from the MERGED list would call back here and recurse without
    // bound. CoreGraphics always publishes the panel's own timing (the mode
    // carrying kDisplayModeNativeFlag), so `published` is correct, terminating,
    // and what makes the wire-timing guard's evidence non-empty.
    guard let native = published.first(where: \.isNative) else { return (published, nil) }

    let revealed = CGSModeRevelation.reveal(
      cgs: Self.cgsDescriptors(for: displayID),
      existing: published,
      nativePixelWidth: native.pixelWidth,
      nativePixelHeight: native.pixelHeight,
      guardsWireTiming: guardsWireTiming
    )
    return (published, revealed)
  }

  /// Read live rather than captured at construction, so the documented
  /// `defaults write` takes effect on the next enumeration instead of needing a
  /// relaunch, which is also what makes it testable by hand on hardware.
  public var guardsWireTiming: Bool {
    DisplayPrefs(persistenceKey: "app").wireTimingGuard
  }

  /// Resolved by LOOKUP into `modes(for:)` rather than constructed fresh from
  /// `CGDisplayCopyDisplayMode`, so the value is an element of the list: `==` to
  /// its own entry, and findable by `apply`. A separately-constructed value would
  /// merely happen to match, and a picker marking the current row by comparison
  /// would break on any field the two paths ever disagreed about.
  ///
  /// Sound because `IODisplayModeID` stays unique even under
  /// `kCGDisplayShowDuplicateLowResolutionModes`, measured on hardware at
  /// 132/132, 332/332 and 120/120 across three panels.
  public func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    // Resolved rather than looked up: the display can be running a duplicate the
    // enumeration collapsed, and this call answers with the live id either way.
    // See `DisplayModeList.resolve`.
    return DisplayModeList.resolve(
      Self.displayMode(ioModeID: mode.ioDisplayModeID, mode: mode),
      in: modes(for: displayID))
  }

  public func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    guard let native = modes(for: displayID).first(where: \.isNative) else { return nil }
    return (native.pixelWidth, native.pixelHeight)
  }

  public func apply(
    _ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope
  ) throws {
    switch mode.provenance {
    case .coreGraphics:
      try applyPublishedMode(mode, to: displayID, scope: scope)
    case .coreGraphicsServices:
      try applyRevealedMode(mode, to: displayID, scope: scope)
    case .synthesized:
      // Refused, not routed. A synthesized size is engaged by
      // `ModeSynthesisEngine` (a virtual display plus a mirror) and its sentinel
      // `ioModeID` denotes nothing in either mode-ID space, so there is no
      // transaction to stage. Reaching here means a caller bypassed the engine.
      //
      // `invalidOperation` rather than the `illegalArgument` the published path
      // throws for an unresolvable ID: sharing that code would make "you
      // bypassed the engine" indistinguishable from "that mode is not on this
      // display".
      throw DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue)
    }
  }

  /// The revealed path.
  ///
  /// No `CGDisplayMode` object exists to cross-check before staging, so the
  /// pre-commit descriptor guard `applyPublishedMode` uses has no analogue here.
  /// The post-commit readback below is this path's guard instead: a deliberate
  /// asymmetry, not an omission (CR9). Sound because CoreGraphics and CGS share
  /// one mode-ID space (S6 §4).
  private func applyRevealedMode(
    _ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope
  ) throws {
    guard let configureMode = SkyLight.configureDisplayMode else {
      throw DisplayConfigError(cgErrorCode: CGError.cannotComplete.rawValue)
    }

    let config = try beginDisplayConfiguration()
    let staged = configureMode(
      unsafeBitCast(config, to: UnsafeMutableRawPointer.self), displayID, mode.ioModeID)
    guard staged == CGError.success.rawValue else {
      CGCancelDisplayConfiguration(config)
      throw DisplayConfigError(cgErrorCode: staged)
    }
    let result = CGCompleteDisplayConfiguration(config, scope.configureOption)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }

    // THE RETURN CODE IS NOT THE EVIDENCE — the achieved mode is.
    let achieved = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID
    guard achieved == mode.ioModeID else {
      Logger(subsystem: "com.rydersel.Candela", category: "topology").error(
        """
        CoreGraphics reported success for a revealed mode it did not apply: \
        display \(displayID, privacy: .public) asked for mode \
        \(mode.ioModeID, privacy: .public), reports \(achieved ?? -1, privacy: .public)
        """
      )
      // Deliberately not a platform error code: the platform did not report
      // one, which is the entire point of this check.
      throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    }
  }

  /// The public path: resolve the `CGDisplayMode`, cross-check the geometry it
  /// actually denotes, then stage and commit.
  private func applyPublishedMode(
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
    // different mode, which the lookup above would find, apply, and return
    // normally. The caller would be told its mode was applied while the display
    // sits at some other resolution, the one failure neither `ModePreviewSession`
    // nor the reapply path can detect afterwards.
    //
    // The comparison rule (tolerant refresh, no `isNative`, never `ioModeID`) is
    // `matchesGeometry`, which states why. The CHECK stays here: this is the only
    // place that can catch a reassigned ID before the caller is told its mode was
    // applied.
    let resolved = Self.displayMode(ioModeID: mode.ioModeID, mode: cgMode)
    guard resolved.matchesGeometry(of: mode) else {
      throw DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
    }

    let config = try beginDisplayConfiguration()
    // Staging is checked, not discarded: if this fails,
    // `CGCompleteDisplayConfiguration` commits the empty configuration and
    // returns `.success`, so `apply` would return normally having changed
    // nothing. The caller reverts on a throw and has no other way to learn the
    // mode did not take.
    let staged = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
    guard staged == .success else {
      CGCancelDisplayConfiguration(config)
      throw DisplayConfigError(cgErrorCode: staged.rawValue)
    }
    let result = CGCompleteDisplayConfiguration(config, scope.configureOption)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }
  }

  /// The same transaction discipline as `apply`, with the mirror call
  /// substituted for the mode call. Every invariant below exists because an
  /// earlier implementation violated it: it staged its changes, discarded all
  /// four return values, and returned `true` regardless.
  public func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    // An empty transaction commits `.success` having changed nothing, which is
    // indistinguishable from having worked. Open nothing.
    guard !changes.isEmpty else { return }

    let config = try beginDisplayConfiguration()
    for change in changes {
      // Staging is CHECKED, not discarded. If it fails,
      // `CGCompleteDisplayConfiguration` commits the empty configuration and
      // returns `.success`, so this function would return normally having
      // changed nothing, and the caller's only other way to learn is the user
      // telling them. Every early exit cancels, so the config ref never leaks.
      let staged = CGConfigureDisplayMirrorOfDisplay(config, change.display, change.master)
      guard staged == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayConfigError(cgErrorCode: staged.rawValue)
      }
    }
    // The header notes a complete can fail for reasons that have nothing to do
    // with mirroring — an unsupported mode, or another app running full-screen.
    let result = CGCompleteDisplayConfiguration(config, scope.configureOption)
    guard result == .success else {
      throw DisplayConfigError(cgErrorCode: result.rawValue)
    }
    // THE RETURN CODE IS NOT THE EVIDENCE, the achieved topology is. Measured:
    // a cyclic list and a list naming one display twice both had every stage AND
    // the complete return `.success`, and CoreGraphics did something else
    // (`MirrorVerification`).
    //
    // Read immediately with no settle loop, and that is measured rather than
    // assumed: the rig re-read `CGDisplayMirrorsDisplay` directly after the
    // complete in every run, the honoured ones and both divergences, and got the
    // truth each time. `applyRotation` needs its bounded wait because
    // `SLSSetDisplayRotation`'s readback was seen trailing its own return; a
    // mirror commit was not.
    if let unhonoured = MirrorVerification.unhonoured(
      in: changes, achievedParent: CGDisplayMirrorsDisplay
    ) {
      // The thrown code below is generic, so without this line a real occurrence
      // is a bare "CoreGraphics error 1000" in the UI, naming no change.
      Logger(subsystem: "com.rydersel.Candela", category: "topology").error(
        """
        CoreGraphics reported success for a mirror change it did not make: \
        display \(unhonoured.display, privacy: .public) should mirror \
        \(unhonoured.master, privacy: .public) but mirrors \
        \(CGDisplayMirrorsDisplay(unhonoured.display), privacy: .public)
        """
      )
      // Deliberately not a platform error code: the platform did not report
      // one, which is the entire point of this check.
      throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    }
  }

  // MARK: - Private

  /// The option is not optional in practice: without it CoreGraphics returns
  /// only 1x modes, so every HiDPI mode is missing from the list entirely,
  /// including the one most displays are currently running.
  private func copyModes(_ displayID: CGDirectDisplayID) -> [(Int32, CGDisplayMode)] {
    let options = [
      kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue as Any,
    ] as CFDictionary
    guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
      return []
    }
    // macOS itself says these cannot drive the desktop GUI, and this list only
    // ever offers a person something to switch to. Measured 2026-08-17: 95 such
    // modes on the Dell, 47 on the MAG, 0 on the built-in, and they were the
    // WHOLE of the MAG's duplicate rows, each an unusable twin of a usable one.
    //
    // Safe ahead of the native lookup below, which would strand the revelation
    // pass if this removed the panel's own timing: no mode carrying
    // `kDisplayModeNativeFlag` is unusable on any of the three panels, and the
    // CGS side rejects the same modes independently (its gate 2 reads the
    // descriptor's own unusable flag).
    return raw.filter { $0.isUsableForDesktopGUI() }.map { ($0.ioDisplayModeID, $0) }
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
      // Quantized at the boundary: see DisplayMode.quantizedRefresh.
      refreshHz: DisplayMode.quantizedRefresh(mode.refreshRate),
      isNative: (mode.ioFlags & nativeFlag) != 0
    )
  }

  // MARK: - Hidden-mode revelation

  public var revealsHiddenModes: Bool {
    SkyLight.getDisplayModeCount != nil
      && SkyLight.getDisplayModeDescription != nil
      && SkyLight.configureDisplayMode != nil
  }

  /// Reads the raw CGS list. Makes NO decisions — every gate lives in
  /// `CGSModeRevelation`, which is Foundation-only and fixture-tested (CR8).
  static func cgsDescriptors(for displayID: CGDirectDisplayID) -> [CGSModeDescriptor] {
    guard let getCount = SkyLight.getDisplayModeCount,
      let getDescription = SkyLight.getDisplayModeDescription
    else { return [] }

    var count: Int32 = 0
    guard getCount(displayID, &count) == 0, count > 0 else { return [] }

    // Over-allocated on purpose: the DECLARED length is what bounds the write
    // (verified — the callee touches nothing past 212 on any panel tested), and
    // a larger buffer means a future layout growth corrupts nothing of ours.
    let byteCount = 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
    defer { buffer.deallocate() }

    var descriptors: [CGSModeDescriptor] = []
    descriptors.reserveCapacity(Int(count))
    for index in 0 ..< Int(count) {
      memset(buffer, 0, byteCount)
      guard getDescription(displayID, Int32(index), buffer, SkyLight.descriptorLength) == 0
      else { continue }
      descriptors.append(
        CGSModeDescriptor(
          modeNumber: Int32(bitPattern: buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
          flags: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
          logicalWidth: Int(buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
          logicalHeight: Int(buffer.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
          pixelWidth: Int(buffer.loadUnaligned(fromByteOffset: 200, as: UInt32.self)),
          pixelHeight: Int(buffer.loadUnaligned(fromByteOffset: 204, as: UInt32.self)),
          refreshHz: Int(buffer.loadUnaligned(fromByteOffset: 190, as: UInt16.self)),
          density: Double(buffer.loadUnaligned(fromByteOffset: 208, as: Float.self))
        ))
    }
    return descriptors
  }

  // MARK: - Rotation

  public var canRotate: Bool { SkyLight.setDisplayRotation != nil }

  public func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? {
    DisplayRotation(degrees: CGDisplayRotation(displayID))
  }

  public func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {
    guard let setRotation = SkyLight.setDisplayRotation else {
      throw DisplayConfigError(cgErrorCode: CGError.cannotComplete.rawValue)
    }
    let error = setRotation(displayID, rotation.degrees)
    guard error == CGError.success.rawValue else {
      throw DisplayConfigError(cgErrorCode: error)
    }
    // RT8. The call already blocks until the rotation has taken effect (RS10:
    // 0.4 to 1.1s), but the readback was measured still trailing its return by
    // ~26ms, so a single immediate check reports a false failure on the slow
    // path. Bounded, not unbounded: if it has not landed half a second after a
    // call that already waited a second, it is not landing.
    let deadline = Date().addingTimeInterval(0.5)
    while self.rotation(of: displayID) != rotation, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard self.rotation(of: displayID) == rotation else {
      // Deliberately not the platform's error code: the platform did not report
      // one. That is the entire point of this check.
      throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    }
  }
}

/// The one private-API seam this feature has.
///
/// **RT4: there is no fallback and none should be written.** The Intel-era
/// `IOServiceRequestProbe` + `kIOFBSetTransform` route has **zero**
/// `IOFramebuffer` services to attach to on Apple Silicon (RS2).
// Internal rather than private because `PlatformConformance` reads the resolved
// symbols individually, so a post-macOS-update run can name WHICH one went
// missing where `revealsHiddenModes` can only say that one did.
enum SkyLight {
  /// Two arguments, the second a 32-bit integer of degrees. Read out of the
  /// shipping binary's prologue rather than guessed (RS1): it saves `x0` and
  /// `x1`, never touches `x2`, and stores argument 1 through `stp w22, w20`. A
  /// guessed `float` signature would have passed the angle in `s0`.
  typealias SetDisplayRotation = @convention(c) (CGDirectDisplayID, Int32) -> Int32

  static let setDisplayRotation: SetDisplayRotation? = {
    guard let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    ), let symbol = dlsym(handle, "SLSSetDisplayRotation") else { return nil }
    return unsafeBitCast(symbol, to: SetDisplayRotation.self)
  }()

  // MARK: - CGS mode list
  //
  // Enumeration and application of the modes CoreGraphics computes but never
  // publishes. Layout and behaviour verified byte-for-byte on macOS 26.6.1
  // (25G76) across three panels, 2026-08-06.
  //
  // RE-VERIFY THAT LAYOUT AFTER EVERY MACOS MINOR RELEASE. The 212-byte
  // descriptor is the fragile part; `CGSModeRevelation.isPlausible` turns a
  // shifted layout into "nothing revealed" rather than garbage modes.

  typealias GetDisplayModeCount =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
  typealias GetDisplayModeDescription =
    @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
  /// Argument 1 is the `CGDisplayConfigRef` from `CGBeginDisplayConfiguration`,
  /// **not** a connection id: the call must sit inside a real transaction.
  typealias ConfigureDisplayMode =
    @convention(c) (UnsafeMutableRawPointer?, CGDirectDisplayID, Int32) -> Int32

  /// The declared descriptor length. Verified: the callee writes nothing past
  /// this on any panel tested.
  static let descriptorLength: Int32 = 212

  static let getDisplayModeCount: GetDisplayModeCount? =
    symbol("CGSGetNumberOfDisplayModes").map {
      unsafeBitCast($0, to: GetDisplayModeCount.self)
    }
  static let getDisplayModeDescription: GetDisplayModeDescription? =
    symbol("CGSGetDisplayModeDescriptionOfLength").map {
      unsafeBitCast($0, to: GetDisplayModeDescription.self)
    }
  static let configureDisplayMode: ConfigureDisplayMode? =
    symbol("CGSConfigureDisplayMode").map {
      unsafeBitCast($0, to: ConfigureDisplayMode.self)
    }

  private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
    guard let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
    ) else { return nil }
    guard let symbol = dlsym(handle, name) else {
      Logger(subsystem: "com.rydersel.Candela", category: "topology").error(
        """
        SkyLight symbol \(name, privacy: .public) missing; hidden-mode \
        revelation disabled, mode list degrades to CoreGraphics only
        """
      )
      return nil
    }
    return symbol
  }
}
