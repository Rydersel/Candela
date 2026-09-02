import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of the mode-synthesis engine, its preview session, and the
/// two per-display prefs behind synthesized sizes.
///
/// `pairings` is a SNAPSHOT this object holds, never a question asked of the
/// engine. `ModeSynthesisEngine.engage` and `.disengage` are non-async actor
/// methods that block for the whole hardware sequence (about 24 seconds worst
/// case), so a UI path that asked the actor would stall for that window. This
/// object re-reads the table after each operation it performed; everything
/// else reads the snapshot.
///
/// The two key spaces are not interchangeable and mixing them fails silently:
/// prefs are keyed by `DisplayPrefs`' persistence key (the EDID UUID), the
/// engine's pairing by `DisplayConfigIdentity.key` (vendor-model-serial).
/// Every parameter here says which one it wants.
@MainActor @Observable
final class SynthesisCoordinator {
  /// Why a synthesis request produced nothing, and which display it was about.
  ///
  /// Its own type rather than a case on `DisplayModeCoordinator.StartFailure`:
  /// that type's diagnostic line renders "CoreGraphics error <n>", and no
  /// synthesis refusal has a CGError behind it.
  struct Refusal: Equatable {
    let displayID: CGDirectDisplayID
    let reason: Reason

    /// `SynthesisCopy` owns the wording; this is the distinction it renders.
    enum Reason: Equatable {
      /// The built-in panel is never a synthesis target in v1.
      case builtIn
      /// Engaging with HDR on risks the silent HDR drop measured on
      /// mode changes.
      case hdrEngaged
      /// The display is in a mirror set the USER built. Synthesis mirrors the
      /// panel onto a virtual display, which a panel already showing another
      /// display's framebuffer cannot do.
      case alreadyMirrored
      /// The display's opt-in is off, so there was nothing to engage.
      case notOffered
      /// The size asked for is no longer one the catalog offers for this panel.
      case sizeNoLongerOffered
      /// A synthesized size was taken down for an ordinary pick, the pick did
      /// not stand, and something else claimed the displays before it could be
      /// put back. Not a refusal: it explains a disappearance nobody asked for.
      case restoreSuperseded
      /// The post-engage link bounce turned HDR on to renegotiate the wire and
      /// could not turn it back off. The size is on the glass, but DDC stays
      /// dead until the person clears HDR themselves.
      case hdrLeftStanding
      /// A hardware sequence was already running. The one reason worth
      /// retrying, so both busy shapes the session can answer with land here:
      /// a caller that cannot tell "never" from "again in a moment" gets one
      /// of them wrong.
      case busy
      /// Another display-reconfiguring feature holds the gate.
      case blocked(by: ReconfigurationClaimant)
      /// The engine's sequence failed. Every case names the step it stopped at.
      case engine(SynthesisFailure)
    }
  }

  /// The engine's pairing table as of the last operation this object performed.
  /// Ordered `physicalDisplayID`-ascending, as the engine returns it.
  private(set) var pairings: [SynthesisPairing] = []

  /// The last refusal, or nil. One value rather than one per display: it is
  /// about the request just made, and the surfaces that render it check the
  /// display themselves.
  private(set) var refusal: Refusal?

  /// True while an engage or disengage this object started is still running.
  /// The teardown paths below refuse on it, so it has to stay true for the
  /// WHOLE of an operation and not merely for its innermost step.
  var isWorking: Bool { workDepth > 0 }

  /// A depth, not a flag: `performing` nests (an engage runs a departure sweep
  /// that performs disengages), and a bool would be cleared by the inner
  /// operation returning while the outer sequence is still running.
  ///
  /// Not `@ObservationIgnored`: `isWorking` is computed from it, so this is the
  /// property observation has to track.
  private var workDepth = 0

  /// The preview session, reached DIRECTLY by the countdown driver.
  ///
  /// `nonisolated` on purpose: `PreviewCountdownDriver` runs detached so a
  /// wedged main thread cannot stop an expiry, and routing a tick through this
  /// main-actor object would put the main thread back on the clock's path.
  @ObservationIgnored nonisolated let session: SynthesisPreviewSession

  @ObservationIgnored private let engine: ModeSynthesisEngine
  /// The engage funnel: the engine plus the post-engage link bounce.
  @ObservationIgnored private let driver: BouncingSynthesisDriver
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  /// Kept for one question this object answers for itself: which displays are
  /// attached right now. See `sweepDeparturesAfterEngage`.
  @ObservationIgnored private let configurator: any DisplayConfiguring
  /// Where the pairing enters the app's topology. Stamped on the store
  /// because its other writer samples CoreGraphics alone and cannot know what
  /// the app engaged.
  @ObservationIgnored private let topologyStore: MirrorTopologyStore

  /// The DisplayPrefs persistence key for a display, or nil when nothing knows
  /// it (a display discovery has not seen, which is every virtual display).
  @ObservationIgnored var persistenceKey: (CGDirectDisplayID) -> String? = { _ in nil }

  /// The HDR-engaged guard's input, live. Wired by `AppModel` to the display's controller, which
  /// is the achieved state rather than the stored intent.
  @ObservationIgnored var isHDREngaged: (CGDirectDisplayID) -> Bool = { _ in false }

  /// Called after either synthesis pref is written so the propagation
  /// seam hears about it whichever surface asked. The panel and the
  /// confirmation window have no `SettingsActions`.
  @ObservationIgnored var didWriteSynthesisPref: (PrefName, String) -> Void = { _, _ in }

  /// Re-enumerates one display's mode catalog.
  ///
  /// The opt-in decides which ROWS the size picker holds and the catalog
  /// is enumerated on demand, so without this the toggle changes nothing
  /// visible until the display id changes or a reconfiguration fires.
  @ObservationIgnored var didChangeOffer: (CGDirectDisplayID) -> Void = { _ in }

  /// Ends whatever preview any surface has outstanding and reports whether the
  /// machine came back. This object's standalone paths (the opt-out, the
  /// resets) reconfigure displays too, so they must not run over a preview
  /// whose fallback was captured before them.
  ///
  /// It enters `DisplayModeCoordinator`'s serial queue, so a caller from inside
  /// that queue would wait on the operation doing the waiting.
  @ObservationIgnored var endOutstandingPreview: () async -> Bool = { true }

  /// Gives the reconfiguration-gate claim back THROUGH the coordinator's funnel, which releases
  /// only when nothing is outstanding.
  ///
  /// Never `gate.release(.displayModes)` from here: synthesis shares
  /// `.displayModes` with the mode picker, so a select granted during the
  /// multi-second disengage below would lose its claim the moment this
  /// finished, leaving its preview unguarded for the rest of its countdown.
  @ObservationIgnored var releaseClaimIfIdle: () async -> Void = {}

  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "synthesis"
  )

  init(
    virtualDisplays: any VirtualDisplayAchievedModeReporting,
    configurator: any DisplayConfiguring,
    gate: DisplayReconfigurationGate,
    topologyStore: MirrorTopologyStore,
    hdr: SynthesisHDRBounce,
    bounceDurations: BouncingSynthesisDriver.Durations = .production
  ) {
    // The pairing enters the published topology HERE, before the mirror it
    // describes, and not at `refreshSnapshot` alone. The engage runs for
    // seconds with the mirror landing mid-sequence, and `MirrorTopologySampler`
    // writes the store un-debounced, so a stamp that waited would leave a
    // window where the store answers `isInMirrorSet` true and `isSynthesisSet`
    // false. OLED care's forget edge wipes static-region history irreversibly
    // on that one wrong answer.
    //
    // Over-stamping is harmless: a display nobody mirrors is in no set.
    // `refreshSnapshot` republishes the AUTHORITATIVE table after every engage
    // and is therefore the un-stamp for a failed one.
    //
    // Read-modify-write over two lock acquisitions, and safe: the only other
    // writer is `refreshSnapshot`, which asks the engine for its table and so
    // queues behind the very engage this fires inside.
    engine = ModeSynthesisEngine(
      virtualDisplays: virtualDisplays, configurator: configurator,
      willMirrorOntoVirtualDisplay: { [topologyStore] virtualDisplayID in
        topologyStore.noteSynthesisMasters(
          topologyStore.topology().synthesisMasters.union([virtualDisplayID])
        )
      }
    )
    // Both engage entry points route through the driver, so the link bounce
    // runs for a picked size and an unattended restore alike.
    let driver = BouncingSynthesisDriver(
      engine: engine, hdr: hdr, configurator: configurator, durations: bounceDurations
    )
    self.driver = driver
    session = SynthesisPreviewSession(driver: driver)
    self.gate = gate
    self.configurator = configurator
    self.topologyStore = topologyStore
  }

  // MARK: - Reading the snapshot

  /// The virtual displays a synthesized size is mirrored onto right now.
  var masterIDs: Set<CGDirectDisplayID> {
    Set(pairings.map(\.virtualDisplayID))
  }

  func pairing(forPhysical displayID: CGDirectDisplayID) -> SynthesisPairing? {
    pairings.first { $0.physicalDisplayID == displayID }
  }

  func isEngaged(displayID: CGDirectDisplayID) -> Bool {
    pairing(forPhysical: displayID) != nil
  }

  /// True while a "not engaged" answer about this display cannot be trusted:
  /// an operation is in flight (the snapshot is empty for its whole duration),
  /// or the display sits in a mirror set. A catalog refresh landing inside the
  /// engage window read as not-engaged while the OS list already carried the
  /// mirror-published twins, and the poisoned ladder then suppressed the
  /// engaged stop everywhere [MEASURED 2026-08-18].
  func baselineUnstable(displayID: CGDirectDisplayID) -> Bool {
    isWorking || !topologyStore.topology().setMembers(containing: displayID).isEmpty
  }

  func engagedSize(displayID: CGDirectDisplayID) -> SyntheticSize? {
    pairing(forPhysical: displayID)?.size
  }

  /// The engaged stop for a panel named by `DisplayConfigIdentity.key`, which
  /// is what survives the display IDs being reassigned across a replug.
  func engagedSize(identityKey: String) -> SyntheticSize? {
    pairings.first { $0.physicalIdentityKey == identityKey }?.size
  }

  /// How many of the two synthesis slots are unused, as the snapshot sees it.
  var freeSlots: Int {
    max(0, VirtualDisplayIdentity.synthesisSlotRange.count - pairings.count)
  }

  // MARK: - Prefs

  func offersSyntheticSizes(displayID: CGDirectDisplayID) -> Bool {
    prefs(for: displayID)?.offerSyntheticSizes ?? false
  }

  func storedSize(displayID: CGDirectDisplayID) -> SyntheticSizeDescriptor? {
    prefs(for: displayID)?.storedSyntheticSize
  }

  /// The DisplayPrefs persistence key, never `DisplayConfigIdentity.key`:
  /// reading one while writing the other makes an opt-in that saves and reads
  /// back false.
  private func prefs(for displayID: CGDirectDisplayID) -> DisplayPrefs? {
    persistenceKey(displayID).map { DisplayPrefs(persistenceKey: $0) }
  }

  // MARK: - Guards

  /// Why this display cannot take a synthesized size right now, or nil when it
  /// can. The order is the contract: hardware facts before the user's choices,
  /// and it stays aligned with `SynthesisReapplyPolicy` so the attended and
  /// unattended paths never refuse the same machine for different reasons.
  func refusalReason(for display: ConfiguredDisplay) -> Refusal.Reason? {
    if display.isBuiltIn { return .builtIn }
    guard offersSyntheticSizes(displayID: display.id) else { return .notOffered }
    if isInUserMirrorSet(display) { return .alreadyMirrored }
    if isHDREngaged(display.id) { return .hdrEngaged }
    return nil
  }

  /// The predicate in the direction nothing consulted before: this display is
  /// mirrored, and it is not one of OUR sets.
  ///
  /// The flag is CoreGraphics' own, so reading it alone would have every
  /// engaged synthesis set refuse the next request about itself. The exclusion
  /// asks the pairing snapshot first and the topology store second: asking only
  /// the store leaves a window between the mirror landing and the sampler
  /// running in which our own set reads as the user's.
  private func isInUserMirrorSet(_ display: ConfiguredDisplay) -> Bool {
    guard display.isInMirrorSet else { return false }
    if isEngaged(displayID: display.id) || masterIDs.contains(display.id) { return false }
    return !topologyStore.topology().isSynthesisSet(containing: display.id)
  }

  func note(_ reason: Refusal.Reason, for displayID: CGDirectDisplayID) {
    refusal = Refusal(displayID: displayID, reason: reason)
    log.error("synthesis refused on display \(displayID): \(String(describing: reason), privacy: .public)")
  }

  func dismissRefusal() {
    refusal = nil
  }

  // MARK: - Preview (driven by DisplayModeCoordinator, always inside its queue)

  /// Engages `size` as a preview. The caller holds the reconfiguration gate and has
  /// already ended every other outstanding preview.
  func beginPreview(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<PreviewedSynthesis, SynthesisPreviewRefusal> {
    let result = await engaging {
      await self.session.begin(size: size, onPhysical: displayID, identityKey: identityKey)
    }
    if case let .failure(refusal) = result {
      note(reason(for: refusal), for: displayID)
    }
    return result
  }

  func confirmPreview(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    await resolving(on: answered.physicalDisplayID) { await self.session.confirm(answered) }
  }

  func revertPreview(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    await resolving(on: answered.physicalDisplayID) { await self.session.revert(answered) }
  }

  /// The physical panel has gone. Disengages rather than dropping the record: a
  /// pairing is a virtual display that outlives the panel's departure and holds
  /// one of only two slots.
  func revertOnDeparture(displayID: CGDirectDisplayID) async -> SynthesisPreviewOutcome? {
    let outcome = await performing { await self.session.revertOnDeparture(displayID: displayID) }
    if let outcome { record(outcome, for: displayID) }
    return outcome
  }

  /// The countdown expired and the session resolved it. The clock reaches the
  /// session directly, so this is how the snapshot catches up.
  func adoptExpiry(_ outcome: SynthesisPreviewOutcome, on displayID: CGDirectDisplayID) async {
    await refreshSnapshot()
    record(outcome, for: displayID)
  }

  // MARK: - Unattended engage (the launch and arrival path)

  /// The reapply decision for one display and, on `.engage`, the engage itself.
  ///
  /// `resolved` must be `SyntheticSizeCatalog.size(matching:)`'s answer:
  /// `SynthesisReapplyPolicy` trusts that input and cannot tell a stale
  /// descriptor from a caller that skipped the lookup.
  ///
  /// Unattended: nothing is previewed, nothing writes a pref, and a refusal
  /// changes no state.
  @discardableResult
  func reapply(
    for display: ConfiguredDisplay,
    nativeLogicalWidth: Int?, nativeLogicalHeight: Int?,
    existingRows: [DisplayMode]
  ) async -> SynthesisReapplyDecision {
    let stored = storedSize(displayID: display.id)
    let resolved: SyntheticSize? = if let stored, let width = nativeLogicalWidth,
                                      let height = nativeLogicalHeight {
      SyntheticSizeCatalog.size(
        matching: stored, ofNativeWidth: width, nativeHeight: height,
        existingRows: existingRows,
        ceilingPixelWidth: VirtualDisplayIdentity.maxPixels.wide,
        ceilingPixelHeight: VirtualDisplayIdentity.maxPixels.high
      )
    } else {
      nil
    }
    let decision = SynthesisReapplyPolicy.decide(
      optedIn: offersSyntheticSizes(displayID: display.id),
      stored: stored,
      resolved: resolved,
      isBuiltIn: display.isBuiltIn,
      hdrEngaged: isHDREngaged(display.id),
      alreadyEngaged: engagedSize(displayID: display.id) == resolved && resolved != nil,
      alreadyMirrored: isInUserMirrorSet(display),
      freeSlots: freeSlots
    )
    guard case let .engage(size) = decision else {
      // Without this line, a skipped launch restore looks the same as a pass
      // that never ran.
      log.info(
        "synthesis reapply skipped on display \(display.id): \(String(describing: decision), privacy: .public)"
      )
      return decision
    }
    switch await engage(size, on: display) {
    case .success:
      log.info("synthesis reapply engaged \(size.logicalWidth)x\(size.logicalHeight) on display \(display.id)")
    case let .failure(failure):
      // Unattended, so this is the only record. No pref is rewritten: the
      // stored choice is what gets tried again at the next arrival.
      log.error("synthesis reapply failed on display \(display.id): \(String(describing: failure), privacy: .public)")
      note(.engine(failure), for: display.id)
    }
    return decision
  }

  /// The bare engage, with no preview and no persistence. The caller holds the
  /// gate.
  func engage(
    _ size: SyntheticSize, on display: ConfiguredDisplay
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    await engaging {
      await self.driver.engage(
        size, onPhysical: display.id, identityKey: display.identity.key
      )
    }
  }

  // MARK: - Persistence

  /// Records a kept synthesized size. The persist-after-verify ordering hangs off this moment:
  /// the engage has landed and been verified before anything is stored.
  ///
  /// `unwindWasIncomplete` is the one case where `.committed` is not evidence
  /// of a healthy set: a confirm following a FAILED revert returns the retained
  /// pairing, kept because something the engine tried to take down is still
  /// standing. The size is persisted either way and the unwind is surfaced.
  func persist(_ pairing: SynthesisPairing, unwindWasIncomplete: Bool) {
    guard let key = persistenceKey(pairing.physicalDisplayID) else {
      log.error("synthesis: nothing knows a persistence key for display \(pairing.physicalDisplayID); the kept size was not stored")
      return
    }
    DisplayPrefs(persistenceKey: key).setStoredSyntheticSize(
      SyntheticSizeDescriptor(
        logicalWidth: pairing.size.logicalWidth, logicalHeight: pairing.size.logicalHeight
      )
    )
    didWriteSynthesisPref(.storedSyntheticSize, key)
    if unwindWasIncomplete {
      log.error("synthesis: display \(pairing.physicalDisplayID) kept a size whose previous teardown did not finish; a virtual display or a mirror set may still be standing")
      note(.engine(.unwindIncomplete), for: pairing.physicalDisplayID)
    }
  }

  // MARK: - Opt-in

  /// Turns the per-display opt-in on or off.
  ///
  /// Off tears down BEFORE the pref persists (the mute-strand ordering shape).
  /// A pref written first would leave a synthesis set standing with the only
  /// rows that could take it down hidden behind the opt-in, so a failed
  /// disengage LEAVES THE DISPLAY OPTED IN.
  ///
  /// Returns false when nothing was written.
  @discardableResult
  func setOptIn(_ enabled: Bool, on display: ConfiguredDisplay) async -> Bool {
    guard let key = persistenceKey(display.id) else { return false }
    dismissRefusal()
    if enabled {
      DisplayPrefs(persistenceKey: key).setOfferSyntheticSizes(true)
      didWriteSynthesisPref(.offerSyntheticSizes, key)
      didChangeOffer(display.id)
      return true
    }
    guard await disengageForOptOut(display) else { return false }
    DisplayPrefs(persistenceKey: key).setOfferSyntheticSizes(false)
    didWriteSynthesisPref(.offerSyntheticSizes, key)
    didChangeOffer(display.id)
    return true
  }

  /// A per-display settings reset's synthesis half: disengage first, then clear
  /// BOTH keys (that ordering applies to reset paths too). Returns false
  /// when the teardown failed, in which case nothing was cleared.
  @discardableResult
  func reset(_ display: ConfiguredDisplay) async -> Bool {
    guard let key = persistenceKey(display.id) else { return false }
    dismissRefusal()
    guard await disengageForOptOut(display) else { return false }
    let prefs = DisplayPrefs(persistenceKey: key)
    prefs.setStoredSyntheticSize(nil)
    prefs.setOfferSyntheticSizes(false)
    didWriteSynthesisPref(.storedSyntheticSize, key)
    didWriteSynthesisPref(.offerSyntheticSizes, key)
    didChangeOffer(display.id)
    return true
  }

  /// The whole-app reset's synthesis half, run BEFORE `VirtualDisplayHost`'s
  /// `destroyAll` and before the domain wipe. Otherwise the host takes the
  /// slots down behind the engine's back, leaving the pairing table naming a
  /// virtual display that has departed.
  ///
  /// Returns false when it REFUSED, which is not the same as "nothing came
  /// down": the pairing table is empty for the whole of an engage, so a caller
  /// that reads the table to judge the teardown has to read this first.
  @discardableResult
  func disengageAllForReset() async -> Bool {
    // Checked FIRST: the snapshot below is empty for the whole multi-second
    // engage, so it answers "nothing is engaged" about a machine that is about
    // to have a synthesis set on it.
    guard !isWorking else {
      log.error("synthesis: a teardown was asked for while a hardware sequence was still running; nothing was taken down")
      return false
    }
    guard !pairings.isEmpty else { return true }
    // Result discarded on purpose, and this is the one path where that is
    // right: the reset is about to wipe the domain and rebuild, so a set left
    // standing because a preview refused to revert would outlive all of it
    // with nothing left that knows about it. The disengage below is the
    // teardown that matters.
    _ = await endOutstandingPreview()
    let claimed = await gate.claim(.displayModes).refusedBy == nil
    let engaged = pairings
    // Through the driver, so the panel comes back on the mode the user chose
    // rather than the HiDPI twin the engage tail re-timed it onto; the driver
    // also clears its own-mode record on success.
    await performing { [driver, log] in
      for pairing in engaged {
        let result = await driver.disengage(fromPhysical: pairing.physicalDisplayID)
        if case let .failure(failure) = result, failure != .notEngaged {
          log.error("synthesis reset: display \(pairing.physicalDisplayID) did not disengage (\(String(describing: failure), privacy: .public))")
        }
      }
    }
    // Through the funnel, never `gate.release` from here: see
    // `releaseClaimIfIdle`. Guarded on having been granted so a claim held by
    // another feature is not reconciled away by this pass.
    if claimed { await releaseClaimIfIdle() }
    return true
  }

  /// A picker-driven ordinary size choice over a COMMITTED set: the set
  /// comes down through the engine before any mode may touch the panel, which
  /// is otherwise a mirror slave the apply would land on invisibly. Returns
  /// false without touching anything when it refuses.
  ///
  /// `fromQueueContext: true` because the select path runs INSIDE the preview
  /// queue, and both `endOutstandingPreview` and `releaseClaimIfIdle` re-enter
  /// it: the select hung at the release holding the gate claim, and every later
  /// pick enqueued forever [MEASURED 2026-08-18]. The caller has already stood
  /// the previews down, and its own `adopt` releases the claim this leaves
  /// held.
  func disengageForModeChange(_ display: ConfiguredDisplay) async -> Bool {
    await disengageForOptOut(display, fromQueueContext: true)
  }

  /// Clears the stored stop without touching the opt-in or the machine. A kept
  /// ordinary size is a choice against the stored stop, which would otherwise
  /// re-engage at the next launch over the size the user just kept.
  func clearStoredSize(displayID: CGDirectDisplayID) {
    guard let key = persistenceKey(displayID) else { return }
    let prefs = DisplayPrefs(persistenceKey: key)
    guard prefs.storedSyntheticSize != nil else { return }
    prefs.setStoredSyntheticSize(nil)
    didWriteSynthesisPref(.storedSyntheticSize, key)
  }

  /// The verified disengage both opt-out paths share.
  ///
  /// Returns false without touching anything when it refuses, which is what
  /// keeps the persist-after-verify ordering honest: both callers write prefs only after this
  /// says the machine is clean.
  private func disengageForOptOut(
    _ display: ConfiguredDisplay, fromQueueContext: Bool = false
  ) async -> Bool {
    // BEFORE the `isEngaged` question: that reads the snapshot, which is empty
    // for the whole of an engage, so an in-flight one would answer "nothing to
    // take down", let the prefs be written, and then land behind an opt-in that
    // is now off and hides the rows that could take it down.
    guard !isWorking else {
      note(.busy, for: display.id)
      return false
    }
    guard isEngaged(displayID: display.id) else { return true }
    if !fromQueueContext {
      guard await endOutstandingPreview() else {
        note(.busy, for: display.id)
        return false
      }
    }
    // The reconfiguration gate, before the reconfiguration: a refusal has to cost nothing, and a
    // claim taken after the transaction is staged protects nobody.
    if let holder = await gate.claim(.displayModes).refusedBy {
      note(.blocked(by: holder), for: display.id)
      return false
    }
    // Through the driver for the twin restore: this is the one teardown where
    // the panel stays attached and the user is watching it.
    let result = await performing { [driver] in
      await driver.disengage(fromPhysical: display.id)
    }
    // Through the funnel, never `gate.release` from here: a select landing
    // inside the multi-second disengage is GRANTED the gate because it names
    // the same claimant. From the queue context the funnel would re-enter the
    // queue and hang with the claim held, so the calling select's own `adopt`
    // releases instead.
    if !fromQueueContext { await releaseClaimIfIdle() }
    switch result {
    case .success:
      return true
    case .failure(.notEngaged):
      // Nothing is synthesized, which is the state the teardown exists to
      // reach. Reporting it as a failure would refuse an opt-out over a set
      // that is not there.
      return true
    case let .failure(failure):
      note(.engine(failure), for: display.id)
      return false
    }
  }

  // MARK: - Departure

  /// Takes down every synthesis set whose physical panel has left. A pairing
  /// under PREVIEW goes through the session so its countdown goes with it; a
  /// kept one has no session record and would hold a slot for a panel that is
  /// not attached, and put a departed panel in the arrangement signature.
  func noteDepartures(live: Set<CGDirectDisplayID>) async {
    // A refusal names a display by its RUNTIME id, which the next arrival can
    // inherit, so it must not resurface on whatever takes that id.
    if let refusal, !live.contains(refusal.displayID) { dismissRefusal() }
    let departed = pairings.map(\.physicalDisplayID).filter { !live.contains($0) }
    guard !departed.isEmpty else { return }
    let previewed = await session.previewedSynthesis?.physicalDisplayID
    for displayID in departed {
      if displayID == previewed {
        _ = await revertOnDeparture(displayID: displayID)
        continue
      }
      // Through the driver: display IDs reassign across a replug, so its
      // own-mode record has to be cleared on this teardown rather than left
      // for whatever takes the id next.
      let result = await performing { [driver] in await driver.disengage(fromPhysical: displayID) }
      if case let .failure(failure) = result, failure != .notEngaged {
        log.error("synthesis: display \(displayID) departed and its set did not come down (\(String(describing: failure), privacy: .public))")
      }
    }
  }

  // MARK: - Snapshot maintenance

  /// Re-reads the pairing table and republishes it.
  ///
  /// Called only after an operation this object performed, never from a view:
  /// the engine's actor is busy for the whole of an engage, so this is a
  /// multi-second call in exactly the window a UI must not block in.
  private func refreshSnapshot() async {
    pairings = await engine.pairings()
    // Also the UN-STAMP. `init`'s hook over-stamps a virtual display before
    // the mirror lands; republishing the authoritative table takes a failed
    // engage's announcement back. A pairing the engine RETAINED after an
    // incomplete unwind stays stamped, which is correct: something is still
    // standing.
    topologyStore.noteSynthesisMasters(masterIDs)
  }

  /// Runs a hardware operation with the working depth raised and the snapshot
  /// re-read afterwards, so no path can perform one and forget either.
  /// Re-entrant: `engaging`'s departure sweep performs disengages of its own,
  /// and the depth keeps `isWorking` true across all of it.
  private func performing<T>(_ operation: () async -> T) async -> T {
    workDepth += 1
    let result = await operation()
    workDepth -= 1
    await refreshSnapshot()
    return result
  }

  /// `performing`, plus the departure sweep an ENGAGE has to run for itself.
  /// The depth is held across both halves rather than left to the inner
  /// `performing`: a teardown granted in the gap would run against a machine
  /// that is still being reconfigured.
  private func engaging<T>(_ operation: () async -> T) async -> T {
    workDepth += 1
    defer { workDepth -= 1 }
    let result = await performing(operation)
    await sweepDeparturesAfterEngage()
    return result
  }

  /// Takes down any pairing whose physical panel is no longer attached, once,
  /// straight after an engage.
  ///
  /// Every other departure sweep keys on the pairing SNAPSHOT, which is empty
  /// for the whole multi-second engage, so a panel leaving inside that window
  /// reaches no sweep and nothing re-runs them afterwards. The engage asks for
  /// itself, at the one moment the snapshot is fresh again.
  ///
  /// The live list, not the notification's: what matters is what is attached
  /// NOW.
  private func sweepDeparturesAfterEngage() async {
    guard !pairings.isEmpty else { return }
    await noteDepartures(live: Set(configurator.displays().map(\.id)))
  }

  private func resolving(
    on displayID: CGDirectDisplayID,
    _ operation: () async -> SynthesisPreviewOutcome
  ) async -> SynthesisPreviewOutcome {
    let outcome = await performing(operation)
    record(outcome, for: displayID)
    return outcome
  }

  /// The one place an outcome becomes a refusal the UI can render. `.committed`
  /// and `.reverted` are answers, so they clear whatever was on screen;
  /// `.stale` names a preview that is already gone.
  private func record(_ outcome: SynthesisPreviewOutcome, for displayID: CGDirectDisplayID) {
    switch outcome {
    case .committed, .reverted:
      dismissRefusal()
    case let .failed(failure):
      note(.engine(failure), for: displayID)
    case .busy:
      note(.busy, for: displayID)
    case .stale:
      break
    }
  }

  private func reason(for refusal: SynthesisPreviewRefusal) -> Refusal.Reason {
    switch refusal {
    case .busy: .busy
    case let .engine(failure): .engine(failure)
    }
  }
}
