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
    // Switching from one stop to another re-enters here while the PREVIOUS set
    // is still standing (the engine tears it down as its own first step), so
    // what this reads then is the previous engage's re-time still holding. A
    // previous re-time that returned false leaves this capturing the old
    // master's geometry instead, which the apply's own descriptor cross-check
    // rejects: the tail falls to the bounce rather than putting a wrong mode on
    // the glass.
    //
    // Recorded rather than merely read, and first write wins: the re-enter case
    // above would otherwise overwrite the user's own mode with the previous
    // engage's re-time, and the disengage restore would then put the twin back
    // rather than the mode the user chose.
    let ownMode = ownModes.remember(configurator.currentMode(for: displayID), for: displayID)
    let result = await engine.engage(size, onPhysical: displayID, identityKey: identityKey)
    switch result {
    case let .success(pairing):
      let target = retimeTarget(
        for: displayID, ownMode: ownMode, master: pairing.virtualDisplayID)
      if await retime(displayID, to: target) == false { await bounce(displayID) }
    case .failure:
      // Nothing of ours stands, so nothing of ours is owed a restore. Leaving
      // the record would make a mode the user has since changed the thing a
      // later disengage reasserts.
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
  /// the SAME framebuffer pixels and the same refresh, so the wire timing is
  /// identical and the picture is unchanged; only the cursor scale follows.
  ///
  /// The twin is matched on the panel's own published list by framebuffer and
  /// quantized refresh, with the scale taken from the master rather than
  /// assumed. A synthesis master is always HiDPI, so this resolves to the 2x
  /// twin in every case the feature produces; reading it keeps the rule true
  /// rather than merely usually true, and an unreadable master falls back to
  /// HiDPI for the same reason.
  ///
  /// A native-flagged candidate wins, then the lowest mode id, so a panel
  /// publishing duplicate twins re-times onto the same one every session rather
  /// than onto whichever came back first.
  ///
  /// **The twin can never look like the size being rendered**, which is what
  /// keeps the teardown's panel-restore check able to fail. That check calls a
  /// panel wrong when its readback IS the rendered stop; a 2x twin's logical
  /// size is exactly half the panel's, and the ladder's lowest rung is 65
  /// percent of it, so the two cannot collide. A ladder that ever reached 50
  /// percent would put the re-time target on top of a stop and make every
  /// teardown report an incomplete unwind.
  ///
  /// **The fallback is the display's own mode**, with a log line: no twin
  /// published means the cursor mismatch comes back, and nothing else changes.
  /// That is the state this whole tail shipped in, so it is a degradation rather
  /// than a failure, and it must not stop the re-time from running.
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
  /// The mirror leaves the slave on a timing of the OS's choosing: the wire was
  /// measured at 100 Hz from a 175 Hz start, and on some establishments the
  /// chosen timing is marginal (visible flashing, software-invisible). A mode
  /// apply on a mirrored slave lands on the glass while the mirror keeps
  /// scanning the master's picture [MEASURED 2026-08-18: OSD 175, picture
  /// intact, mirror standing], so this both preserves the display's refresh and
  /// renegotiates the link onto its own known-good timing. Returns false when
  /// it could not run OR could not be confirmed; the HDR bounce is the fallback
  /// renegotiator.
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
    // descriptor before staging, which catches a reassigned mode id, and then
    // trusts `CGCompleteDisplayConfiguration` for the commit itself, which has
    // been measured returning success over a request it did not honour. A
    // re-time refused or coerced on a mirror slave is a case nothing has
    // evidence about, and reporting it as landed skips the bounce in exactly
    // the situation the bounce exists for.
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
  /// **Paths that bypass it, named rather than implied.** Only the preview
  /// session's stand-down comes through here. Process death takes the ledger
  /// with it. The engine's own teardowns do not come through here at all: the
  /// one at the top of a switch between stops, and the unwind after a failed
  /// engage. Neither needs this, because of what follows them: a switch
  /// re-engages and re-times immediately, and an unwind ends with nothing of
  /// this feature's standing.
  ///
  /// `SynthesisCoordinator` also calls the engine directly, and those four are
  /// worth reading one at a time. A departure teardown has no panel to put
  /// back. The whole-app reset is about to rebuild everything anyway. The
  /// ordinary-pick teardown is followed immediately by the mode the user
  /// picked, so a restore there would be a reconfiguration for a mode that is
  /// about to be replaced. The opt-out (and the per-display reset that shares
  /// its path) is the one where the panel stays attached and the user is
  /// looking at it, so it is the bypass that matters; routing it through here
  /// is a coordinator decision, not this file's.
  ///
  /// For every bypass the net is the remembered-mode reapply, which reasserts
  /// the user's stored mode on reconfiguration when it is enabled for that
  /// display. That net is a preference rather than a guarantee, which is why
  /// this path does not lean on it.
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
  /// Scale rather than any difference: a panel that came back on some unrelated
  /// mode is a state this feature did not create, and the user's own mode is
  /// still the right answer for it, so the same reapply covers both. What the
  /// scale test buys is silence in the ordinary case, where the mirror break
  /// already restored the mode and an apply would be a reconfiguration for
  /// nothing.
  ///
  /// An unreadable achieved mode reapplies rather than standing down, which is
  /// the opposite of the HDR legs' rule in this file and deliberate: the write
  /// they are careful about can leave DDC dead, while the only thing this can
  /// put on the glass is the mode the user picked.
  private func restoreOwnMode(_ displayID: CGDirectDisplayID, to ownMode: DisplayMode?) async {
    guard let ownMode else { return }
    // The mirror break is a reconfiguration and the window server lags it, so a
    // mode read taken inline would describe the world before it. Paid only on a
    // disengage of a set this driver engaged, because of the guard above.
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

/// The mode each panel was on when its synthesized size was engaged, so the
/// disengage can put it back.
///
/// A reference behind a value type, deliberately: the driver is a struct and is
/// copied (the coordinator holds one, the preview session another), and both
/// copies have to see one record. One lock over one dictionary, synchronous
/// readers, the same shape as `MirrorTopologyStore`.
///
/// **First write wins per display, until a disengage clears it.** Switching from
/// one stop to another re-enters the engage while the previous set still
/// stands, and what the panel reads as its current mode then is the previous
/// engage's re-time: the HiDPI twin, not the mode the user chose. Overwriting
/// would make the twin the thing a later disengage restores, which is the
/// defect the restore exists to prevent.
///
/// Keyed by runtime display ID, which is an address rather than an identity.
/// That is safe here because an entry's whole life is one engage and the
/// disengage that follows it, and every engage rewrites the entry for whatever
/// panel holds that ID now. A record stranded by a replug is dropped by the
/// engage that claims the ID next.
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
