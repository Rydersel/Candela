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

  private static let log = Logger(
    subsystem: "com.rydersel.Candela", category: "synthesis"
  )

  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    let result = await engine.engage(size, onPhysical: displayID, identityKey: identityKey)
    if case .success = result { await bounce(displayID) }
    return result
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
