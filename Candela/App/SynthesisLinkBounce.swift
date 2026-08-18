import CandelaKit
import CoreGraphics
import os

/// The engine, wrapped so every SUCCESSFUL engage ends with one HDR round
/// trip on the physical panel.
///
/// The mirror's SDR link negotiation lands marginal on some establishments:
/// visible flashing that tracks content updates, while topology, modes,
/// gamma and the log all read identical to a clean engage, so software can
/// neither detect nor prevent it. An HDR round trip renegotiates the link
/// and the mirror survives it; both observed occurrences cleared on the
/// spot [MEASURED 2026-08-18, eyes]. A panel with no HDR modes skips the
/// bounce: there is nothing to renegotiate through.
///
/// Best-effort by design: a failed bounce never fails the engage. The one
/// hard rule is the OFF leg. HDR left standing kills DDC to the panel, so
/// the off write is issued, settled and CHECKED, three times before giving
/// up loudly (the same shape as the mute-strand rule: never leave the
/// disabling state standing on a best-effort path).
struct BouncingSynthesisDriver: SynthesisDriving {
  let engine: ModeSynthesisEngine
  let hdr: any HDRToggling
  let configurator: any DisplayConfiguring

  private static let log = Logger(
    subsystem: "com.rydersel.Candela", category: "synthesis"
  )

  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    // Captured BEFORE the engage: once the mirror stands the display's
    // descriptor answers for the master, and the mode the panel was running
    // is not recoverable from anywhere.
    let ownMode = configurator.currentMode(for: displayID)
    let result = await engine.engage(size, onPhysical: displayID, identityKey: identityKey)
    if case .success = result {
      if await retime(displayID, to: ownMode) == false { await bounce(displayID) }
    }
    return result
  }

  /// Re-applies the panel's own mode to the mirror SLAVE after the engage.
  ///
  /// The mirror leaves the slave on a timing of the OS's choosing: the wire
  /// was measured at 100 Hz from a 175 Hz start, and on some establishments
  /// the chosen timing is marginal (visible flashing, software-invisible). A
  /// mode apply on a mirrored slave lands on the glass while the mirror keeps
  /// scanning the master's picture [MEASURED 2026-08-18: OSD 175, picture
  /// intact, mirror standing], so this both preserves the panel's refresh and
  /// renegotiates the link to the panel's own known-good timing. Returns
  /// false when it could not run; the HDR bounce is the fallback
  /// renegotiator.
  private func retime(_ displayID: CGDirectDisplayID, to ownMode: DisplayMode?) async -> Bool {
    guard let ownMode else { return false }
    // The engage's reconfigure needs to settle before another one begins.
    try? await Task.sleep(for: .seconds(2))
    do {
      // Session scope, matching the engine's own applies. The apply
      // cross-checks the resolved descriptor and throws on a reassigned
      // ioModeID, so a stale capture surfaces here rather than as a wrong
      // mode on the glass.
      try configurator.apply(ownMode, to: displayID, scope: .session)
      Self.log.info("synthesis.retime display \(displayID) back to \(ownMode.logicalWidth)x\(ownMode.logicalHeight) @\(ownMode.refreshHz)Hz")
      return true
    } catch {
      Self.log.info("synthesis.retime could not run for display \(displayID): \(String(describing: error), privacy: .public)")
      return false
    }
  }

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    await engine.disengage(fromPhysical: displayID)
  }

  func pairing(forPhysical displayID: CGDirectDisplayID) async -> SynthesisPairing? {
    await engine.pairing(forPhysical: displayID)
  }

  private func bounce(_ displayID: CGDirectDisplayID) async {
    guard await hdr.supportsHDR(displayID: displayID) else { return }
    // The user's own HDR is never touched: the reapply policy refuses an
    // engage under HDR, so reaching here with it on means an outside actor
    // moved it mid-engage, and a bounce would end their choice.
    guard await hdr.measuredHDREnabled(displayID: displayID) == false else { return }
    // The engage's reconfigure is still settling when this runs, and the
    // MonitorPanel access lock is non-blocking: the first write straight
    // after the engage was measured refused. Settle first, then retry the
    // on leg with the same patience the off leg gets.
    try? await Task.sleep(for: .seconds(3))
    var wentOn = false
    for _ in 1...3 {
      if await hdr.setHDR(displayID: displayID, enabled: true) { wentOn = true; break }
      try? await Task.sleep(for: .seconds(2))
    }
    guard wentOn else {
      Self.log.info("synthesis.bounce skipped: the on write was refused for display \(displayID)")
      return
    }
    try? await Task.sleep(for: .seconds(2))
    for _ in 1...3 {
      _ = await hdr.setHDR(displayID: displayID, enabled: false)
      try? await Task.sleep(for: .seconds(2))
      if await hdr.measuredHDREnabled(displayID: displayID) == false {
        Self.log.info("synthesis.bounce completed for display \(displayID)")
        return
      }
    }
    Self.log.error(
      "synthesis.bounce left HDR standing on display \(displayID): DDC to the panel is dead until it is turned off"
    )
  }
}
