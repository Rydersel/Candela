import CandelaKit
import CoreGraphics
import os

/// The engine, wrapped so every SUCCESSFUL engage ends with the display back on
/// its own timing: a re-time of the mirror slave, and one HDR round trip as the
/// fallback when the re-time could not run.
///
/// The mirror's SDR link negotiation lands marginal on some establishments:
/// visible flashing that tracks content updates, while topology, modes, gamma
/// and the log all read identical to a clean engage, so software can neither
/// detect nor prevent it. An HDR round trip renegotiates the link and the
/// mirror survives it; both observed occurrences cleared on the spot [MEASURED
/// 2026-08-18, eyes]. A display with no HDR modes skips the bounce: there is
/// nothing to renegotiate through.
///
/// Best-effort by design: a failed bounce never fails the engage. The one hard
/// rule is the OFF leg. HDR left standing kills DDC to the display, so the off
/// write is issued, settled and CHECKED, three times, before giving up loudly
/// and reporting it where a person can read it (the same shape as the
/// mute-strand rule: never leave the disabling state standing on a best-effort
/// path).
///
/// **Both legs go through the display's own brightness controller**
/// (`SynthesisHDRBounce`). Driving HDR past it opens a DDC-hostile window the
/// brightness stack cannot see, and the swallowed writes it then certifies as
/// landed are undetectable on a write-only display.
struct BouncingSynthesisDriver: SynthesisDriving {
  /// How long each wait in the tail is. Injected so a test can drive the whole
  /// sequence without paying about seventeen seconds of real wall clock per
  /// failure case; production takes the defaults and nothing else may.
  struct Durations: Sendable {
    /// The engage's own reconfigure has to settle before another one begins.
    var beforeRetime: Duration
    /// The same settle for the bounce, plus the non-blocking MonitorPanel
    /// access lock: the first write straight after an engage was measured
    /// refused.
    var beforeBounce: Duration
    /// The controller's HDR settle window, named HERE rather than left to
    /// `BrightnessController.settleDelay`, because this is the object that has
    /// to state the worst case: every leg pays it, and there can be six.
    var hdrSettle: Duration
    /// Between one HDR leg that did not take and the next.
    var betweenAttempts: Duration
    /// How long HDR stands before the off leg goes out, ON TOP of the settle
    /// the on leg already waited. Zero, and that is deliberate: routing through
    /// the controller moved a full settle inside the on leg, so a non-zero hold
    /// here would keep the display in HDR for twice as long as the sequence the
    /// eyes verification actually watched.
    var hdrHeld: Duration

    /// Worst case, and it is worth being able to read off the page because the
    /// whole of it is spent holding the `.displayModes` claim, the preview
    /// queue slot and a raised work depth, with no revert countdown armed yet:
    ///
    ///   retime 2 + bounce settle 3
    ///   + on leg (3 x settle 2, with 2 waits of 2 between) = 10
    ///   + hold 0
    ///   + off leg, same shape = 10
    ///   = about 25 seconds.
    ///
    /// The waits are BETWEEN attempts rather than after each one, which is
    /// where four seconds of the earlier arithmetic went.
    static let production = Durations(
      beforeRetime: .seconds(2), beforeBounce: .seconds(3), hdrSettle: .seconds(2),
      betweenAttempts: .seconds(2), hdrHeld: .zero
    )
  }

  let engine: ModeSynthesisEngine
  let hdr: SynthesisHDRBounce
  let configurator: any DisplayConfiguring
  var durations: Durations = .production

  private static let log = Logger(
    subsystem: "com.rydersel.Candela", category: "synthesis"
  )

  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    // Captured BEFORE the engage: once the mirror stands the display's
    // descriptor answers for the master until the re-time below puts it back.
    //
    // Switching from one stop to another re-enters here while the PREVIOUS set
    // is still standing (the engine tears it down as its own first step), so
    // what this reads then is the previous engage's re-time still holding. A
    // previous re-time that returned false leaves this capturing the old
    // master's geometry instead, which the apply's own descriptor cross-check
    // rejects: the tail falls to the bounce rather than putting a wrong mode on
    // the glass.
    let ownMode = configurator.currentMode(for: displayID)
    let result = await engine.engage(size, onPhysical: displayID, identityKey: identityKey)
    if case .success = result {
      if await retime(displayID, to: ownMode) == false { await bounce(displayID) }
    }
    return result
  }

  /// Re-applies the display's own mode to the mirror SLAVE after the engage.
  ///
  /// The mirror leaves the slave on a timing of the OS's choosing: the wire was
  /// measured at 100 Hz from a 175 Hz start, and on some establishments the
  /// chosen timing is marginal (visible flashing, software-invisible). A mode
  /// apply on a mirrored slave lands on the glass while the mirror keeps
  /// scanning the master's picture [MEASURED 2026-08-18: OSD 175, picture
  /// intact, mirror standing], so this both preserves the display's refresh and
  /// renegotiates the link onto its own known-good timing. Returns false when
  /// it could not run OR could not be confirmed; the HDR bounce is the fallback
  /// renegotiator.
  private func retime(_ displayID: CGDirectDisplayID, to ownMode: DisplayMode?) async -> Bool {
    guard let ownMode else { return false }
    try? await Task.sleep(for: durations.beforeRetime)
    do {
      // Session scope, matching the engine's own applies.
      try configurator.apply(ownMode, to: displayID, scope: .session)
    } catch {
      Self.log.info("synthesis.retime could not run for display \(displayID): \(String(describing: error), privacy: .public)")
      return false
    }
    // THE RETURN CODE IS NOT THE EVIDENCE. The apply cross-checks the RESOLVED
    // descriptor before staging, which catches a reassigned mode id, and then
    // trusts `CGCompleteDisplayConfiguration` for the commit itself, which has
    // been measured returning success over a request it did not honour. A
    // re-time refused or coerced on a mirror slave is a case nothing has
    // evidence about, and reporting it as landed skips the bounce in exactly
    // the situation the bounce exists for.
    guard let achieved = configurator.currentMode(for: displayID),
          achieved.logicalWidth == ownMode.logicalWidth,
          achieved.logicalHeight == ownMode.logicalHeight,
          achieved.pixelWidth == ownMode.pixelWidth,
          achieved.pixelHeight == ownMode.pixelHeight,
          DisplayMode.quantizedRefresh(achieved.refreshHz)
          == DisplayMode.quantizedRefresh(ownMode.refreshHz)
    else {
      Self.log.info(
        "synthesis.retime did not take on display \(displayID): the apply reported success and the display did not follow it"
      )
      return false
    }
    Self.log.info("synthesis.retime display \(displayID) back to \(ownMode.logicalWidth)x\(ownMode.logicalHeight) @\(ownMode.refreshHz)Hz")
    return true
  }

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    await engine.disengage(fromPhysical: displayID)
  }

  func pairing(forPhysical displayID: CGDirectDisplayID) async -> SynthesisPairing? {
    await engine.pairing(forPhysical: displayID)
  }

  private func bounce(_ displayID: CGDirectDisplayID) async {
    guard await hdr.supportsHDR(displayID) else { return }
    // The engage's reconfigure is still settling when this runs, and the
    // MonitorPanel access lock is non-blocking: the first write straight after
    // the engage was measured refused. Settle FIRST, then read the guard.
    try? await Task.sleep(for: durations.beforeBounce)
    // The user's own HDR is never touched: the reapply policy refuses an engage
    // under HDR, so finding it on here means an outside actor moved it, and a
    // bounce would end their choice. Read AFTER the settle rather than before
    // it, because a guard sampled seconds earlier describes a display somebody
    // may have changed since. nil fails this guard too, which is the safe
    // direction: a state nobody will vouch for is not one to decide from.
    guard await hdr.measuredHDREnabled(displayID) == false else {
      Self.log.info(
        "synthesis.bounce skipped on display \(displayID): HDR is live, or its state is nobody's to vouch for"
      )
      return
    }
    var wentOn = false
    for attempt in 1...3 {
      // ACHIEVED, not issued: the seam answers with the controller's own
      // measured read after its settle window. A write that was accepted while
      // the display did not switch leaves nothing to renegotiate.
      if await hdr.setHDR(displayID, true, durations.hdrSettle) { wentOn = true; break }
      if attempt < 3 { try? await Task.sleep(for: durations.betweenAttempts) }
    }
    if !wentOn {
      // **The off leg runs anyway**, and this is the one place it would be easy
      // to skip it. The seam's false is TWO facts: the display measured out of
      // HDR, or a newer transition superseded the call, which established
      // nothing and left the register assumed locked. This code cannot tell
      // them apart, and the second one means HDR may well be standing right
      // now, with the entry writes this loop just issued behind it. Walking
      // away on a maybe is the mute-strand shape exactly: a best-effort path
      // leaving the disabling state standing, on a display where the only
      // symptom is brightness and volume quietly not working.
      Self.log.info(
        "synthesis.bounce did not get display \(displayID) into HDR; standing the off leg down anyway, because a refused leg is not evidence the display is out"
      )
    } else {
      try? await Task.sleep(for: durations.hdrHeld)
    }
    if await standDownHDR(displayID) {
      // The seam answers with a measured read, so this line says only what was
      // established. Whether the round trip cleared the flashing is an eyes
      // question with no instrument behind it, and nothing here may claim it.
      Self.log.info(
        "synthesis.bounce finished on display \(displayID): HDR is measured off (round trip \(wentOn, privacy: .public))"
      )
    }
  }

  /// The OFF discipline, and the one hard rule in this file: HDR left standing
  /// kills DDC to the display, so the write is issued, settled and CHECKED,
  /// three times, before giving up loudly and reporting it somewhere a person
  /// can read. Returns whether the display is MEASURED out of HDR.
  private func standDownHDR(_ displayID: CGDirectDisplayID) async -> Bool {
    // Fresh, and it is the last chance NOT to write. `false` is a measured
    // answer with no transition racing it: the display is out of HDR, there is
    // nothing to stand down, and an off write would be this feature reaching
    // into a state it did not create. nil is "nobody vouches", which takes the
    // discipline below, because making sure is the safe direction.
    //
    // What this CANNOT do, stated rather than implied: once HDR is on, the
    // bounce cannot tell its own from HDR a person switched on during the hold.
    // Both read identically at every layer, so the off leg ends either. The
    // window is a few seconds and the alternative is leaving DDC dead.
    if await hdr.measuredHDREnabled(displayID) == false { return true }
    for attempt in 1...3 {
      if await hdr.setHDR(displayID, false, durations.hdrSettle) { return true }
      if attempt < 3 { try? await Task.sleep(for: durations.betweenAttempts) }
    }
    Self.log.error(
      "synthesis.bounce left HDR standing on display \(displayID): DDC to the display is dead until it is turned off"
    )
    await hdr.reportHDRLeftStanding(displayID)
    return false
  }
}
