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
      // Support comes from the string alone; an unadvertised code is never
      // read, because a read that answers establishes nothing.
      guard CapabilityString.support(forVCP: control.code, in: capabilities) == .supported else {
        claims.append(
          CheckupClaim(
            family: .capabilities, id: control.id,
            verdict: .notObserved(
              "\(control.name) (VCP \(Self.hex(control.code))) is not advertised by this panel")))
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
      try configurator.apply(native, to: displayID, scope: .session)
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
    // Synthesized sizes are rendered by us rather than offered by the panel, so
    // they say nothing about what the wire carries.
    let atNative = modes.filter {
      $0.pixelWidth == native.pixelWidth && $0.pixelHeight == native.pixelHeight
        && $0.provenance != .synthesized
    }
    var claims: [CheckupClaim] = []
    for rate in DisplayModeCatalog.distinctRates(atNative).sorted() {
      guard
        let mode = atNative.first(where: { DisplayMode.quantizedRefresh($0.refreshHz) == rate })
      else { continue }
      let id = CheckupCheckID.refresh(hz: rate)
      do {
        try configurator.apply(mode, to: displayID, scope: .session)
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

  public func restore() {
    guard let before else { return }
    try? configurator.apply(before, to: displayID, scope: .session)
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
  /// Injected so the fake-driven tests do not spend three seconds sleeping.
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
    let prior = await hdr.measuredHDREnabled(displayID: displayID)
    await hdr.setHDR(displayID: displayID, enabled: true)
    try? await Task.sleep(for: settleDelay)
    let settled = await hdr.measuredHDREnabled(displayID: displayID)
    await hdr.setHDR(displayID: displayID, enabled: prior)
    try? await Task.sleep(for: restoreDelay)
    let restored = await hdr.measuredHDREnabled(displayID: displayID) == prior
    let suffix = restored ? "" : "; restore to the prior state did not settle"
    claims.append(
      CheckupClaim(
        family: .hdr, id: CheckupCheckID.hdrSettle,
        verdict: settled
          ? .observed("toggled on, preferHDRModes settled on" + suffix)
          : .refused("toggled on, preferHDRModes stayed off" + suffix)))
    return claims
  }

  private func yesNo(_ v: Bool) -> String { v ? "yes" : "no" }
}
