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
/// detect nor prevent it. An HDR round trip renegotiates the link and both
/// observed occurrences cleared on the spot [MEASURED 2026-08-18, eyes]. A
/// display with no HDR modes skips the bounce.
///
/// Best-effort by design: a failed bounce never fails the engage. The one hard
/// rule is the OFF leg. HDR left standing kills DDC to the display, so the off
/// write is issued, settled and CHECKED, three times, before giving up loudly
/// and reporting it where a person can read it (the mute-strand shape: never
/// leave the disabling state standing on a best-effort path).
///
/// **Both legs go through the display's own brightness controller**
/// (`SynthesisHDRBounce`). Driving HDR past it opens a DDC-hostile window the
/// brightness stack cannot see, and the swallowed writes it then certifies as
/// landed are undetectable on a write-only display.
struct BouncingSynthesisDriver: SynthesisDriving {
  /// How long each wait in the tail is. Injected so a test can drive the whole
  /// sequence without paying the real wall clock; production takes the defaults
  /// and nothing else may.
  struct Durations: Sendable {
    /// The engage's own reconfigure has to settle before another one begins.
    var beforeRetime: Duration
    /// The same settle for the bounce, plus the non-blocking MonitorPanel
    /// access lock: the first write straight after an engage was measured
    /// refused.
    var beforeBounce: Duration
    /// The controller's HDR settle window, named HERE rather than left to
    /// `BrightnessController.settleDelay`: every leg pays it, and there can be
    /// six.
    var hdrSettle: Duration
    /// Between one HDR leg that did not take and the next.
    var betweenAttempts: Duration
    /// How long HDR stands before the off leg goes out, ON TOP of the settle
    /// the on leg already waited. Zero on purpose: the on leg already pays a
    /// full settle inside the controller, so a non-zero hold would keep the
    /// display in HDR for twice as long as the sequence the eyes verification
    /// watched.
    var hdrHeld: Duration

    /// Worst case is about 25 seconds: the re-time, the bounce settle, then
    /// three settled attempts per HDR leg with a wait BETWEEN attempts rather
    /// than after each. All of it is spent holding the `.displayModes` claim,
    /// the preview queue slot and a raised work depth, with no revert countdown
    /// armed yet.
    static let production = Durations(
      beforeRetime: .seconds(2), beforeBounce: .seconds(3), hdrSettle: .seconds(2),
      betweenAttempts: .seconds(2), hdrHeld: .zero
    )
  }

  let engine: ModeSynthesisEngine
  let hdr: SynthesisHDRBounce
  let configurator: any DisplayConfiguring
  var durations: Durations = .production
  /// Shared by every copy of this struct: see `SynthesisOwnModeLedger`.
  let ownModes = SynthesisOwnModeLedger()

  private static let log = Logger(
    subsystem: "com.rydersel.Candela", category: "synthesis"
  )

  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    // Captured BEFORE the engage: once the mirror stands the display's
    // descriptor answers for the master until the re-time below puts it back.
    //
    // First write wins. Switching from one stop to another re-enters here while
    // the PREVIOUS set is still standing, so what this reads then is the
    // previous engage's re-time; overwriting would make the disengage restore
    // put the twin back rather than the mode the user chose. A stale capture is
    // rejected by the apply's own descriptor cross-check, so the tail falls to
    // the bounce rather than putting a wrong mode on the glass.
    let ownMode = ownModes.remember(configurator.currentMode(for: displayID), for: displayID)
    let result = await engine.engage(size, onPhysical: displayID, identityKey: identityKey)
    switch result {
    case let .success(pairing):
      let target = retimeTarget(
        for: displayID, ownMode: ownMode, master: pairing.virtualDisplayID)
      if await retime(displayID, to: target) == false { await bounce(displayID) }
    case .failure:
      // Nothing of ours stands, so nothing is owed a restore. A left record
      // would have a later disengage reassert a mode the user has since
      // changed.
      ownModes.forget(displayID)
    }
    return result
  }

  /// **The re-time lands on the HiDPI TWIN of the display's own mode, not on the
  /// mode itself.**
  ///
  /// The hardware cursor is sized by the SLAVE's mode scale while the content
  /// comes from the 2x master, so a panel re-timed onto its 1x native mode draws
  /// a tiny cursor over an enlarged UI [MEASURED 2026-08-18, eyes]. The twin has
  /// the SAME framebuffer pixels and refresh, so only the cursor scale follows.
  ///
  /// Matched on the panel's own published list by framebuffer and quantized
  /// refresh, with the scale read from the master rather than assumed. Ties go
  /// to a native-flagged candidate, then the lowest mode id, so a panel
  /// publishing duplicate twins re-times onto the same one every session.
  ///
  /// **The twin can never look like the size being rendered**, which is what
  /// keeps the teardown's panel-restore check able to fail: a 2x twin's logical
  /// size is exactly half the panel's and the ladder's lowest rung is 65 percent
  /// of it. A ladder that ever reached 50 percent would put the re-time target
  /// on top of a stop and make every teardown report an incomplete unwind.
  ///
  /// **The fallback is the display's own mode**, with a log line: the cursor
  /// mismatch comes back and nothing else changes, so it is a degradation rather
  /// than a failure and must not stop the re-time from running.
  private func retimeTarget(
    for displayID: CGDirectDisplayID, ownMode: DisplayMode?, master: CGDirectDisplayID
  ) -> DisplayMode? {
    guard let ownMode else { return nil }
    let wantsHiDPI = configurator.currentMode(for: master)?.isHiDPI ?? true
    let twins = configurator.modes(for: displayID).filter {
      $0.pixelWidth == ownMode.pixelWidth && $0.pixelHeight == ownMode.pixelHeight
        && DisplayMode.quantizedRefresh($0.refreshHz)
        == DisplayMode.quantizedRefresh(ownMode.refreshHz)
        && $0.isHiDPI == wantsHiDPI
    }
    guard let twin = twins.min(by: { left, right in
      left.isNative == right.isNative
        ? left.ioModeID < right.ioModeID : left.isNative
    }) else {
      Self.log.info("""
      synthesis.retime display \(displayID) publishes no \
      \(wantsHiDPI ? "HiDPI" : "1x", privacy: .public) twin of \
      \(ownMode.pixelWidth, privacy: .public)x\(ownMode.pixelHeight, privacy: .public) \
      @\(ownMode.refreshHz, privacy: .public)Hz; re-timing onto its own mode, which leaves \
      the pointer sized for that mode rather than for the size on screen
      """)
      return ownMode
    }
    return twin
  }

  /// Re-applies the display's own timing to the mirror SLAVE after the engage,
  /// as the HiDPI twin `retimeTarget` chose.
  ///
  /// The mirror leaves the slave on a timing of the OS's choosing (measured at
  /// 100 Hz from a 175 Hz start), and on some establishments that timing is
  /// marginal: visible flashing, software-invisible. A mode apply on a mirrored
  /// slave lands on the glass while the mirror keeps scanning the master's
  /// picture [MEASURED 2026-08-18: OSD 175, picture intact, mirror standing].
  /// Returns false when it could not run OR could not be confirmed; the HDR
  /// bounce is the fallback renegotiator.
  private func retime(_ displayID: CGDirectDisplayID, to target: DisplayMode?) async -> Bool {
    guard let target else { return false }
    try? await Task.sleep(for: durations.beforeRetime)
    do {
      // Session scope, matching the engine's own applies.
      try configurator.apply(target, to: displayID, scope: .session)
    } catch {
      Self.log.info("synthesis.retime could not run for display \(displayID): \(String(describing: error), privacy: .public)")
      return false
    }
    // THE RETURN CODE IS NOT THE EVIDENCE. The apply cross-checks the RESOLVED
    // descriptor before staging, then trusts `CGCompleteDisplayConfiguration`
    // for the commit, which has been measured returning success over a request
    // it did not honour. Reporting a coerced re-time as landed skips the bounce
    // in exactly the situation the bounce exists for.
    guard let achieved = configurator.currentMode(for: displayID),
          achieved.logicalWidth == target.logicalWidth,
          achieved.logicalHeight == target.logicalHeight,
          achieved.pixelWidth == target.pixelWidth,
          achieved.pixelHeight == target.pixelHeight,
          DisplayMode.quantizedRefresh(achieved.refreshHz)
          == DisplayMode.quantizedRefresh(target.refreshHz)
    else {
      Self.log.info(
        "synthesis.retime did not take on display \(displayID): the apply reported success and the display did not follow it"
      )
      return false
    }
    Self.log.info("synthesis.retime display \(displayID) onto \(target.logicalWidth)x\(target.logicalHeight) (framebuffer \(target.pixelWidth)x\(target.pixelHeight)) @\(target.refreshHz)Hz")
    return true
  }

  /// Takes the set down, then puts the panel back on the mode the user chose.
  ///
  /// The restore is the other half of the twin re-time. The panel spent the
  /// engagement on a 2x mode this feature applied, and breaking a mirror can
  /// leave a slave on whichever mode it last held, so without this a user who
  /// turns a synthesized size off can be left looking at half the desktop they
  /// asked for.
  ///
  /// Only the preview session's stand-down comes through here. The engine's own
  /// teardowns do not need it: a switch between stops re-engages and re-times
  /// immediately, and an unwind after a failed engage ends with nothing of this
  /// feature's standing. `SynthesisCoordinator`'s direct calls each end
  /// somewhere the restore would be undone or pointless, except the opt-out,
  /// where routing through here is its decision rather than this file's.
  ///
  /// The net for every bypass is the remembered-mode reapply, a preference
  /// rather than a guarantee, so this path does not lean on it.
  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure> {
    // Read, not taken: a disengage that fails leaves the set standing, and the
    // panel still owes the restore.
    let ownMode = ownModes.mode(for: displayID)
    let result = await engine.disengage(fromPhysical: displayID)
    if case .success = result {
      ownModes.forget(displayID)
      await restoreOwnMode(displayID, to: ownMode)
    }
    return result
  }

  /// Puts `ownMode` back when the panel came out of the mirror on a different
  /// SCALE, which is the shape the twin re-time can leave behind.
  ///
  /// Scale rather than any difference: the test buys silence in the ordinary
  /// case, where the mirror break already restored the mode and an apply would
  /// be a reconfiguration for nothing.
  ///
  /// An unreadable achieved mode reapplies rather than standing down, the
  /// opposite of the HDR legs' rule in this file: their write can leave DDC
  /// dead, while the only thing this can put on the glass is the mode the user
  /// picked.
  private func restoreOwnMode(_ displayID: CGDirectDisplayID, to ownMode: DisplayMode?) async {
    guard let ownMode else { return }
    // The mirror break is a reconfiguration and the window server lags it, so a
    // mode read taken inline would describe the world before it.
    try? await Task.sleep(for: durations.beforeRetime)
    let achieved = configurator.currentMode(for: displayID)
    if let achieved, achieved.isHiDPI == ownMode.isHiDPI { return }
    do {
      try configurator.apply(ownMode, to: displayID, scope: .session)
    } catch {
      Self.log.error("""
      synthesis.restore could not put display \(displayID, privacy: .public) back on \
      \(ownMode.logicalWidth, privacy: .public)x\(ownMode.logicalHeight, privacy: .public): \
      \(String(describing: error), privacy: .public)
      """)
      return
    }
    // The apply's return code is not the evidence, for `retime`'s reason.
    guard let landed = configurator.currentMode(for: displayID),
          landed.isHiDPI == ownMode.isHiDPI
    else {
      Self.log.error("""
      synthesis.restore display \(displayID, privacy: .public) did not follow the mode it \
      was put back on; it is left at the scale the mirror break chose
      """)
      return
    }
    Self.log.info("""
    synthesis.restore display \(displayID, privacy: .public) back on \
    \(ownMode.logicalWidth, privacy: .public)x\(ownMode.logicalHeight, privacy: .public) \
    @\(ownMode.refreshHz, privacy: .public)Hz
    """)
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
    // under HDR, so finding it on here means an outside actor moved it. Read
    // AFTER the settle, because a guard sampled seconds earlier describes a
    // display somebody may have changed since. nil fails this guard too: a
    // state nobody will vouch for is not one to decide from.
    guard await hdr.measuredHDREnabled(displayID) == false else {
      Self.log.info(
        "synthesis.bounce skipped on display \(displayID): HDR is live, or its state is nobody's to vouch for"
      )
      return
    }
    var wentOn = false
    for attempt in 1...3 {
      // ACHIEVED, not issued: the seam answers with the controller's measured
      // read. A write accepted while the display did not switch leaves nothing
      // to renegotiate.
      if await hdr.setHDR(displayID, true, durations.hdrSettle) { wentOn = true; break }
      if attempt < 3 { try? await Task.sleep(for: durations.betweenAttempts) }
    }
    if !wentOn {
      // **The off leg runs anyway**, and this is the one place it would be easy
      // to skip it. The seam's false is TWO facts: the display measured out of
      // HDR, or a newer transition superseded the call and established nothing.
      // This code cannot tell them apart, so HDR may well be standing right now.
      // Walking away on a maybe is the mute-strand shape exactly, on a display
      // where the only symptom is brightness and volume quietly not working.
      Self.log.info(
        "synthesis.bounce did not get display \(displayID) into HDR; standing the off leg down anyway, because a refused leg is not evidence the display is out"
      )
    } else {
      try? await Task.sleep(for: durations.hdrHeld)
    }
    if await standDownHDR(displayID) {
      // Only what was measured. Whether the round trip cleared the flashing is
      // an eyes question with no instrument behind it, and nothing here may
      // claim it.
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
    // Fresh, and the last chance NOT to write. `false` is a measured answer
    // with nothing racing it: there is nothing to stand down, and an off write
    // would reach into a state this feature did not create. nil is "nobody
    // vouches", which takes the discipline below.
    //
    // What this CANNOT do: once HDR is on, the bounce cannot tell its own from
    // HDR a person switched on during the hold. Both read identically at every
    // layer, so the off leg ends either. The window is a few seconds and the
    // alternative is leaving DDC dead.
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

/// The mode each panel was on when its synthesized size was engaged, so the
/// disengage can put it back.
///
/// A reference behind a value type: the driver is a struct and is copied (the
/// coordinator holds one, the preview session another), and both copies have to
/// see one record. One lock over one dictionary, synchronous readers.
///
/// **First write wins per display, until a disengage clears it.** Switching
/// stops re-enters the engage while the previous set still stands, and what the
/// panel reads as its current mode then is the previous engage's re-time: the
/// HiDPI twin, not the mode the user chose.
///
/// Keyed by runtime display ID, which is an address rather than an identity.
/// Safe here because an entry's whole life is one engage and the disengage that
/// follows it, and a record stranded by a replug is dropped by the engage that
/// claims the ID next.
final class SynthesisOwnModeLedger: Sendable {
  private let stored = OSAllocatedUnfairLock<[CGDirectDisplayID: DisplayMode]>(
    initialState: [:]
  )

  /// Records `mode` unless something is already on record for this display, and
  /// answers with whatever now stands.
  @discardableResult
  func remember(_ mode: DisplayMode?, for displayID: CGDirectDisplayID) -> DisplayMode? {
    stored.withLock { modes in
      if let existing = modes[displayID] { return existing }
      guard let mode else { return nil }
      modes[displayID] = mode
      return mode
    }
  }

  func mode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    stored.withLock { $0[displayID] }
  }

  func forget(_ displayID: CGDirectDisplayID) {
    stored.withLock { $0[displayID] = nil }
  }
}
