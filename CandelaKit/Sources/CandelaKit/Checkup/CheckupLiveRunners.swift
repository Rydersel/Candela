import CoreGraphics
import Foundation

/// CK11. For each control the capabilities string advertises: read, write the
/// same value back, read again, and quote the whole round trip.
///
/// The write's return value is deliberately discarded. A DDC ACK is evidence of
/// nothing, so the only thing that can grade this check is the second READ.
public struct CheckupLiveCapabilitiesRunner: CheckupCapabilitiesRunning {
  let writer: any DDCWriting
  let capabilities: String

  public init(writer: any DDCWriting, capabilities: String) {
    self.writer = writer
    self.capabilities = capabilities
  }

  static let controls: [(id: String, name: String, code: UInt8)] = [
    (CheckupCheckID.capabilityBrightness, "brightness", VCP.brightness),
    (CheckupCheckID.capabilityContrast, "contrast", VCP.contrast),
    (CheckupCheckID.capabilityVolume, "volume", VCP.audioSpeakerVolume),
  ]

  static func hex(_ code: UInt8) -> String {
    "0x" + String(format: "%02X", code)
  }

  public func run() async -> [CheckupClaim] {
    var claims: [CheckupClaim] = []
    for control in Self.controls {
      let label = "\(control.name) (VCP \(Self.hex(control.code)))"
      // Support comes from the string alone; an unadvertised code is never
      // read, because a read that answers establishes nothing.
      switch CapabilityString.support(forVCP: control.code, in: capabilities) {
      case .supported:
        break
      case .unsupported:
        claims.append(
          CheckupClaim(
            family: .capabilities, id: control.id,
            verdict: .notObserved("\(label) is not advertised by this panel")))
        continue
      case .unknown:
        // Distinct from unsupported on purpose (D24): a string we could not
        // parse is not a display that denied the code, and saying so would put
        // a denial the panel never made into a report a person keeps.
        claims.append(
          CheckupClaim(
            family: .capabilities, id: control.id,
            verdict: .notObserved(
              "\(label): this panel's capabilities string could not be parsed, so whether it advertises this control is unknown"
            )))
        continue
      }
      guard let first = await writer.read(command: control.code) else {
        claims.append(
          CheckupClaim(
            family: .capabilities, id: control.id,
            verdict: .refused("\(control.name): no reply to the read")))
        continue
      }
      _ = await writer.write(command: control.code, value: first.current)
      guard let second = await writer.read(command: control.code) else {
        claims.append(
          CheckupClaim(
            family: .capabilities, id: control.id,
            verdict: .refused(
              "\(control.name): read \(first.current), wrote \(first.current), no reply to the second read"
            )))
        continue
      }
      let text =
        "\(control.name): read \(first.current), wrote \(first.current), read \(second.current) of \(second.max)"
      claims.append(
        CheckupClaim(
          family: .capabilities, id: control.id,
          verdict: second.current == first.current
            ? .observed(text) : .refused(text + "; the value did not hold")))
    }
    return claims
  }
}

/// CK12 and CK13. Stages the native mode, then every rate advertised at the
/// native size, and grades each one on what `currentMode` reports afterwards.
///
/// An actor rather than a class with an unchecked promise: it holds the one
/// piece of mutable state in these runners (the mode to put back), and the
/// isolation the compiler checks is worth more here than a comment claiming the
/// flow calls it in sequence.
public actor CheckupLiveModeRunner: CheckupModeRunning {
  let configurator: any DisplayConfiguring
  let displayID: CGDirectDisplayID
  private var before: DisplayMode?

  /// Every apply here is `.preview` (`kCGConfigureForAppOnly`), which macOS
  /// reverts when this process exits, crash included. A checkup walks a display
  /// through modes it was never asked to keep, so a run that dies mid-sweep
  /// must not leave someone's panel parked on the last rate it tried.
  /// `restore()` still puts the mode back explicitly rather than relying on
  /// this: the app is expected to keep running.
  static let scope: DisplayConfigScope = .preview

  public init(configurator: any DisplayConfiguring, displayID: CGDirectDisplayID) {
    self.configurator = configurator
    self.displayID = displayID
  }

  static func describe(_ m: DisplayMode) -> String {
    "\(m.pixelWidth) by \(m.pixelHeight) at \(hz(m.refreshHz)) Hz"
  }

  /// One quantization boundary for the whole app: rates that differ only by
  /// CoreGraphics float noise print the same, and NTSC's 59.9 stays its own
  /// number.
  static func hz(_ v: Double) -> String {
    String(format: "%g", DisplayMode.quantizedRefresh(v))
  }

  static func reason(_ error: any Error) -> String {
    if let configError = error as? DisplayConfigError {
      return "CGError \(configError.cgErrorCode)"
    }
    return String(describing: error)
  }

  /// Geometry and a quantized rate, never `ioModeID`.
  ///
  /// `ioModeID` is positional rather than identity: after a reconfiguration the
  /// same number can resolve to a different mode while the apply still reports
  /// success. The sweep reconfigures this display once per rate, so the id the
  /// pre-run mode was captured under is exactly the kind that can have moved
  /// underneath us. Geometry plus rate is what the persisted descriptor already
  /// uses to re-find a mode across reassignment, so it is what this compares.
  static func sameMode(_ a: DisplayMode, _ b: DisplayMode) -> Bool {
    a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
      && a.logicalWidth == b.logicalWidth && a.logicalHeight == b.logicalHeight
      && DisplayMode.quantizedRefresh(a.refreshHz) == DisplayMode.quantizedRefresh(b.refreshHz)
  }

  private func rememberCurrentMode() {
    if before == nil { before = configurator.currentMode(for: displayID) }
  }

  public func runNativeMode() -> [CheckupClaim] {
    rememberCurrentMode()
    let modes = configurator.modes(for: displayID)
    guard let native = modes.first(where: \.isNative) else {
      return [
        CheckupClaim(
          family: .nativeMode, id: CheckupCheckID.nativeMode,
          verdict: .refused("no native mode in the catalog for this display"))
      ]
    }
    do {
      try configurator.apply(native, to: displayID, scope: Self.scope)
    } catch {
      return [
        CheckupClaim(
          family: .nativeMode, id: CheckupCheckID.nativeMode,
          verdict: .refused("apply refused: \(Self.reason(error))"))
      ]
    }
    guard let achieved = configurator.currentMode(for: displayID) else {
      return [
        CheckupClaim(
          family: .nativeMode, id: CheckupCheckID.nativeMode,
          verdict: .refused(
            "applied \(Self.describe(native)); macOS reports no current mode"))
      ]
    }
    let matches = achieved.pixelWidth == native.pixelWidth
      && achieved.pixelHeight == native.pixelHeight
    let text = "achieved \(Self.describe(achieved)); macOS reports"
    return [
      CheckupClaim(
        family: .nativeMode, id: CheckupCheckID.nativeMode,
        verdict: matches
          ? .observed(text) : .refused("requested \(Self.describe(native)), " + text))
    ]
  }

  public func runRefreshSweep() -> [CheckupClaim] {
    rememberCurrentMode()
    let modes = configurator.modes(for: displayID)
    guard let native = modes.first(where: \.isNative) else { return [] }
    // CoreGraphics modes only. A synthesized size is one Candela renders rather
    // than one the panel offers, and a REVEALED mode can be bound to an
    // unrelated wire timing and scan out cropped while every readback we have
    // reports clean, so neither can support a claim about what this cable
    // carries.
    let atNative = modes.filter {
      $0.pixelWidth == native.pixelWidth && $0.pixelHeight == native.pixelHeight
        && $0.provenance == .coreGraphics
    }
    var claims: [CheckupClaim] = []
    for rate in DisplayModeCatalog.distinctRates(atNative).sorted() {
      guard
        let mode = atNative.first(where: { DisplayMode.quantizedRefresh($0.refreshHz) == rate })
      else { continue }
      let id = CheckupCheckID.refresh(hz: rate)
      do {
        try configurator.apply(mode, to: displayID, scope: Self.scope)
      } catch {
        claims.append(
          CheckupClaim(
            family: .refresh, id: id,
            verdict: .refused("\(Self.hz(rate)) Hz: apply refused: \(Self.reason(error))")))
        continue
      }
      guard let achieved = configurator.currentMode(for: displayID)?.refreshHz else {
        claims.append(
          CheckupClaim(
            family: .refresh, id: id,
            verdict: .refused(
              "requested \(Self.hz(rate)) Hz; macOS reports no current mode")))
        continue
      }
      if DisplayMode.quantizedRefresh(achieved) == rate {
        claims.append(
          CheckupClaim(
            family: .refresh, id: id,
            verdict: .observed("\(Self.hz(rate)) Hz achieved; macOS reports")))
      } else {
        claims.append(
          CheckupClaim(
            family: .refresh, id: id,
            verdict: .refused(
              "requested \(Self.hz(rate)) Hz, achieved \(Self.hz(achieved)) Hz; macOS reports")))
      }
    }
    return claims
  }

  public func restore() -> Bool {
    // Nothing ran, so nothing moved the display and it is already where it was.
    // Reporting a failed restore here would make a checkup that never touched
    // the mode tell someone their display was left somewhere else.
    guard let before else { return true }
    try? configurator.apply(before, to: displayID, scope: Self.scope)
    guard let achieved = configurator.currentMode(for: displayID) else { return false }
    return Self.sameMode(achieved, before)
  }
}

/// CK14. Two instruments that owe DDC nothing: the EDID EOTF flags, and whether
/// `preferHDRModes` settles after a toggle.
///
/// `setHDR` reports only that the write was issued, so the settle read is the
/// only thing that grades this. The prior state is restored on every exit path
/// and re-read afterwards, because a restore that reports success is not a
/// restore that happened.
public struct CheckupLiveHDRRunner: CheckupHDRRunning {
  let hdr: any HDRToggling
  let displayID: CGDirectDisplayID
  let identity: CheckupDisplayIdentity
  /// Injected so the fake-driven tests do not spend seconds sleeping.
  let settleDelay: Duration
  let restoreDelay: Duration

  public init(
    hdr: any HDRToggling, displayID: CGDirectDisplayID, identity: CheckupDisplayIdentity,
    settleDelay: Duration = .seconds(2), restoreDelay: Duration = .seconds(1)
  ) {
    self.hdr = hdr
    self.displayID = displayID
    self.identity = identity
    self.settleDelay = settleDelay
    self.restoreDelay = restoreDelay
  }

  public func run() async -> [CheckupClaim] {
    let flags = identity.supportsPQEOTF || identity.supportsHDRGammaEOTF
    var claims: [CheckupClaim] = []
    guard flags else {
      claims.append(
        CheckupClaim(
          family: .hdr, id: CheckupCheckID.hdrFlags,
          verdict: .observed("panel does not advertise HDR (no EOTF flags)")))
      claims.append(
        CheckupClaim(
          family: .hdr, id: CheckupCheckID.hdrSettle,
          verdict: .notObserved("not attempted: the panel advertises no HDR")))
      return claims
    }
    let macOSSays = await hdr.supportsHDR(displayID: displayID)
    claims.append(
      CheckupClaim(
        family: .hdr, id: CheckupCheckID.hdrFlags,
        verdict: .observed(
          "EOTF flags: PQ \(yesNo(identity.supportsPQEOTF)), HDR gamma \(yesNo(identity.supportsHDRGammaEOTF)); macOS hasHDRModes \(macOSSays ? "true" : "false")"
        )))
    claims.append(await settleClaim())
    return claims
  }

  /// Toggles the state AWAY from where it started and back, so the check has a
  /// transition to observe either way round.
  ///
  /// A panel already in HDR is the case this shape exists for: setting HDR on
  /// when it is already on writes nothing, settles instantly and reads back
  /// exactly the state that was there before the runner touched it, which is a
  /// check whose failure mode is silence. Starting from `on` therefore measures
  /// off-then-on and requires BOTH transitions.
  private func settleClaim() async -> CheckupClaim {
    let prior = await hdr.measuredHDREnabled(displayID: displayID)
    var transitions: [(target: Bool, settled: Bool)] = []
    for target in prior ? [false, true] : [true] {
      await hdr.setHDR(displayID: displayID, enabled: target)
      try? await Task.sleep(for: settleDelay)
      transitions.append((target, await hdr.measuredHDREnabled(displayID: displayID) == target))
    }
    await hdr.setHDR(displayID: displayID, enabled: prior)
    try? await Task.sleep(for: restoreDelay)
    let restored = await hdr.measuredHDREnabled(displayID: displayID) == prior
    let suffix = restored ? "" : "; restore to the prior state did not settle"
    let text =
      transitions.map { Self.transitionText(target: $0.target, settled: $0.settled) }
      .joined(separator: "; ") + suffix
    let allSettled = transitions.allSatisfy(\.settled)
    return CheckupClaim(
      family: .hdr, id: CheckupCheckID.hdrSettle,
      verdict: allSettled ? .observed(text) : .refused(text))
  }

  static func transitionText(target: Bool, settled: Bool) -> String {
    let verb = target ? "on" : "off"
    let stayed = target ? "off" : "on"
    return settled
      ? "toggled \(verb), preferHDRModes settled \(verb)"
      : "toggled \(verb), preferHDRModes stayed \(stayed)"
  }

  private func yesNo(_ v: Bool) -> String { v ? "yes" : "no" }
}
