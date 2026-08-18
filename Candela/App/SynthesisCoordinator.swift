import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of the mode-synthesis engine, its preview session, and the
/// two per-display prefs behind synthesized sizes (SS4).
///
/// Deliberately NOT a fifth preview coordinator. A synthesized size is a SIZE,
/// so it is chosen from the same picker, answered in the same confirmation
/// surface and counted down by the same clock as every other size:
/// `DisplayModeCoordinator` owns all of that and reaches in here for the
/// hardware. What lives here is what only synthesis has: the engine, the
/// pairing snapshot every SS7 carve-out reads, the guards (SS9/SS14), and the
/// SS11 ordering that puts a verified disengage before the opt-in is written
/// false.
///
/// **`pairings` is a SNAPSHOT this object holds, never a question asked of the
/// engine.** `ModeSynthesisEngine.engage` and `.disengage` are non-async actor
/// methods that BLOCK for the whole hardware sequence (up to about 24 seconds
/// worst case: the appearance poll, the in-process retry, the helper semaphore,
/// then a destroy per unwind step), so every other call into the actor queues
/// behind them. A UI path that asked the actor would stall for that whole
/// window, and it would do it during the VD arrival that is firing topology
/// refreshes. So: this object re-reads the table after each operation IT
/// performed, and everything else reads the snapshot.
///
/// **The two key spaces are not interchangeable, and mixing them is silent.**
/// Prefs are keyed by `DisplayPrefs`' persistence key (the EDID UUID, what
/// `SettingsActions`' writer uses); the engine's pairing carries
/// `DisplayConfigIdentity.key` (vendor-model-serial, what `ModePersistence`
/// uses). Every parameter here says which one it wants.
@MainActor @Observable
final class SynthesisCoordinator {
  /// Why a synthesis request produced nothing, and which display it was about.
  ///
  /// Its own type rather than a case on `DisplayModeCoordinator.StartFailure`,
  /// for the reason `SynthesisPreviewOutcome` is not `PreviewOutcome`: that
  /// type's diagnostic line renders "CoreGraphics error <n>", and no synthesis
  /// refusal has a CGError behind it. A `.unwindIncomplete` reported that way
  /// would name a source it never came from.
  struct Refusal: Equatable {
    let displayID: CGDirectDisplayID
    let reason: Reason

    /// The copy lives in `SynthesisCopy` (Task 10 owns the wording); this is
    /// the distinction it renders.
    enum Reason: Equatable {
      /// SS14. The built-in panel is never a synthesis target in v1.
      case builtIn
      /// SS9. Engaging while HDR is on risks the silent HDR drop the
      /// revealed-mode work measured on mode changes.
      case hdrEngaged
      /// The display is in a mirror set the USER built. Synthesis mirrors the
      /// panel onto a virtual display, which a panel already showing another
      /// display's framebuffer cannot do, and the set is one the person asked
      /// for rather than one this feature may take apart.
      case alreadyMirrored
      /// The display's opt-in is off, so there was nothing to engage.
      case notOffered
      /// The size asked for is no longer one the catalog offers for this panel.
      case sizeNoLongerOffered
      /// A size this app renders was taken down for an ordinary pick, the pick
      /// did not stand, and something else claimed the displays before it could
      /// be put back. Not a refused request either: it explains a disappearance
      /// the person did not ask for and cannot otherwise account for.
      case restoreSuperseded
      /// The post-engage link bounce turned HDR on to renegotiate the wire
      /// and could not turn it back off. Not a refused request: the size is on
      /// the glass. It is the one state this feature can leave behind that a
      /// person has to clear themselves, and DDC is dead until they do.
      case hdrLeftStanding
      /// A hardware sequence was already running. THE one reason worth
      /// retrying: both busy shapes the session can answer with
      /// (`SynthesisPreviewRefusal.busy` and `SynthesisPreviewOutcome.busy`)
      /// land here, because a caller that cannot tell "never" from "again in a
      /// moment" gets one of them wrong.
      case busy
      /// AR12: another display-reconfiguring feature holds the gate.
      case blocked(by: ReconfigurationClaimant)
      /// The engine's sequence failed. Every case names the step it stopped at.
      case engine(SynthesisFailure)
    }
  }

  /// The engine's pairing table as of the last operation this object performed
  /// (SS1). Master-first ordering is `MirrorTopology`'s business, not this
  /// one's; here it is `physicalDisplayID`-ascending, as the engine returns it.
  private(set) var pairings: [SynthesisPairing] = []

  /// The last refusal, or nil. One value rather than one per display: a
  /// refusal is about the request just made, and the surfaces that render it
  /// check the display themselves.
  private(set) var refusal: Refusal?

  /// True while an engage or disengage this object started is still running.
  /// Observable so a surface can disable its own control rather than letting a
  /// second click queue behind a sequence that takes tens of seconds.
  ///
  /// It is also what the teardown paths below refuse on, so it has to stay true
  /// for the WHOLE of an operation and not merely for its innermost step.
  var isWorking: Bool { workDepth > 0 }

  /// A depth rather than a flag, and the difference is load-bearing.
  /// `performing` nests: an engage runs its own departure sweep when it lands,
  /// and that sweep performs disengages of its own. A boolean would be cleared
  /// by the inner operation returning, leaving `isWorking` false while the
  /// outer sequence is still running and every guard that reads it open.
  ///
  /// Not `@ObservationIgnored`: `isWorking` is computed from it, so this is the
  /// property observation has to track for a surface to see the flag change.
  private var workDepth = 0

  /// The preview session, reached DIRECTLY by the countdown driver.
  ///
  /// `nonisolated` deliberately: `PreviewCountdownDriver` runs detached so a
  /// wedged main thread cannot stop an expiry, and a tick routed through this
  /// main-actor object would put the main thread back on the clock's critical
  /// path. The driver awaits the actor; nothing else here does on a UI path.
  @ObservationIgnored nonisolated let session: SynthesisPreviewSession

  @ObservationIgnored private let engine: ModeSynthesisEngine
  /// The engage funnel: the engine plus the post-engage link bounce.
  @ObservationIgnored private let driver: BouncingSynthesisDriver
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  /// The same configurator the engine drives, kept for ONE question this object
  /// has to answer for itself: which displays are attached right now. See
  /// `sweepDeparturesAfterEngage`.
  @ObservationIgnored private let configurator: any DisplayConfiguring
  /// Where the pairing enters the app's topology (SS7). Stamped on the store
  /// rather than at each `MirrorTopology(...)` construction because the store
  /// has two writers and the other one samples CoreGraphics alone, which cannot
  /// know what the app engaged.
  @ObservationIgnored private let topologyStore: MirrorTopologyStore

  /// The DisplayPrefs persistence key for a display, or nil when nothing knows
  /// it (a display discovery has not seen, which is every virtual display).
  /// Wired by `AppModel`, which owns the join.
  @ObservationIgnored var persistenceKey: (CGDirectDisplayID) -> String? = { _ in nil }

  /// SS9's input, live. Wired by `AppModel` to the display's controller, which
  /// is the achieved state rather than the stored intent.
  @ObservationIgnored var isHDREngaged: (CGDirectDisplayID) -> Bool = { _ in false }

  /// D27: called after either synthesis pref is written, with the pref name and
  /// the display's persistence key, so the propagation seam hears about the
  /// write whichever surface asked. The same shape as
  /// `DisplayModeCoordinator.didStoreMode`, and for the same reason: the panel
  /// and the confirmation window have no `SettingsActions`.
  @ObservationIgnored var didWriteSynthesisPref: (PrefName, String) -> Void = { _, _ in }

  /// Re-enumerates one display's mode catalog. Wired by `AppModel` to
  /// `DisplayModeCoordinator.refreshCatalog(for:)`.
  ///
  /// The opt-in decides which ROWS the size picker holds (SS4), and the catalog
  /// is enumerated on demand rather than reactively: the settings hub refreshes
  /// it from a `.task` keyed on the display, and the pref rows fan out to
  /// `.refreshUI`, which re-renders panes without re-enumerating anything. So
  /// without this the toggle would change nothing visible until the display id
  /// changed or a reconfiguration fired, and no test could catch it.
  @ObservationIgnored var didChangeOffer: (CGDirectDisplayID) -> Void = { _ in }

  /// Ends whatever preview any surface currently has outstanding, and reports
  /// whether the machine came back. Wired by `AppModel` to
  /// `DisplayModeCoordinator.endOutstandingPreview()`, which is the exact
  /// mechanism `MirroringCoordinator` uses before its own applies: this object's
  /// standalone paths (the opt-out, the resets) reconfigure displays too, so
  /// they must not run over a preview whose fallback was captured before them.
  ///
  /// It enters `DisplayModeCoordinator`'s serial queue, so the standalone paths
  /// that call it must never themselves be called from inside that queue: they
  /// would wait on the operation doing the waiting. Every caller today is a
  /// settings surface or the app reset, which are outside it.
  @ObservationIgnored var endOutstandingPreview: () async -> Bool = { true }

  /// Gives the AR12 claim back THROUGH the coordinator's funnel, which releases
  /// only when nothing is outstanding.
  ///
  /// Never `gate.release(.displayModes)` from here, and the difference is not
  /// tidiness. The gate's contract is one releasing funnel per claimant, and
  /// synthesis shares `.displayModes` with the mode picker: a select granted
  /// during the multi-second disengage below (granted precisely BECAUSE it
  /// names the same claimant) would have its claim freed the moment this
  /// finished, leaving its preview standing unguarded for the rest of its
  /// countdown. Wired by `AppModel` to
  /// `DisplayModeCoordinator.releaseReconfigurationClaimIfIdle`.
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
    // The synthesis pairing enters the published topology HERE, before the
    // mirror it describes, and not at `refreshSnapshot` alone.
    //
    // The engine's engage runs for seconds and the mirror lands in the middle
    // of it. `MirrorTopologySampler` writes the store synchronously at
    // `didChangeScreenParameters`, deliberately un-debounced, so a stamp that
    // waited for the sequence to return would leave a window in which the store
    // answers `isInMirrorSet` true and `isSynthesisSet` false for the engaging
    // panel. Every SS7 carve-out reads user mirroring in that window, and OLED
    // care's forget edge wipes static-region history irreversibly on it: one
    // wrong answer, no second chance.
    //
    // Over-stamping is harmless in the other direction: a display nobody is
    // mirroring is in no set, so no predicate changes. The correction is
    // `refreshSnapshot`, which republishes the AUTHORITATIVE table after every
    // engage, successful or not, and is therefore also the un-stamp for a
    // failed one.
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
    // Both engage entry points route through the bouncing driver, so the
    // post-engage link bounce runs for a picked size and an unattended
    // restore alike. Disengage and the pairing read forward untouched.
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

  /// The virtual displays a synthesized size is mirrored onto right now (SS1).
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
  /// an engage or disengage is in flight (the snapshot is empty for its whole
  /// duration), or the display sits in a mirror set right now. The panel
  /// baseline's overwrite guard reads this: a catalog refresh landing inside
  /// the engage window read as not-engaged while the OS list already carried
  /// the mirror-published twins, and the poisoned ladder then suppressed the
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

  /// How many of SS6's two synthesis slots are unused, as the snapshot sees it.
  var freeSlots: Int {
    max(0, VirtualDisplayIdentity.synthesisSlotRange.count - pairings.count)
  }

  // MARK: - Prefs (SS4)

  func offersSyntheticSizes(displayID: CGDirectDisplayID) -> Bool {
    prefs(for: displayID)?.offerSyntheticSizes ?? false
  }

  func storedSize(displayID: CGDirectDisplayID) -> SyntheticSizeDescriptor? {
    prefs(for: displayID)?.storedSyntheticSize
  }

  /// Built from the DISPLAY PREFS persistence key, never from
  /// `DisplayConfigIdentity.key`: the synthesis accessors suffix on the former,
  /// matching every other per-display pref, and reading one while writing the
  /// other makes an opt-in that saves and reads back false.
  private func prefs(for displayID: CGDirectDisplayID) -> DisplayPrefs? {
    persistenceKey(displayID).map { DisplayPrefs(persistenceKey: $0) }
  }

  // MARK: - Guards (SS9, SS14)

  /// Why this display cannot take a synthesized size right now, or nil when it
  /// can. The order is the contract: hardware facts before the user's choices,
  /// so a built-in panel says what it is rather than reporting an opt-in.
  ///
  /// The mirror check sits where `SynthesisReapplyPolicy` puts its own, and the
  /// two orderings are kept aligned deliberately: the attended and unattended
  /// paths refusing for different reasons over the same machine is a difference
  /// nobody could explain from what is on screen.
  func refusalReason(for display: ConfiguredDisplay) -> Refusal.Reason? {
    if display.isBuiltIn { return .builtIn }
    guard offersSyntheticSizes(displayID: display.id) else { return .notOffered }
    if isInUserMirrorSet(display) { return .alreadyMirrored }
    if isHDREngaged(display.id) { return .hdrEngaged }
    return nil
  }

  /// SS7's predicate in the direction nothing consulted before: this display is
  /// mirrored, and it is not one of OUR sets.
  ///
  /// The halves come from different places on purpose. The flag is
  /// CoreGraphics' own, sampled with the display, so it describes the machine
  /// rather than what the app remembers. Reading it alone would have every
  /// engaged synthesis set refuse the next request about itself.
  ///
  /// The exclusion is asked of the pairing snapshot FIRST and the topology
  /// store second. SS1 makes the pairing the authority on synthesis topology
  /// and this object holds it, so the snapshot answers without a sample for
  /// both ends of a set this object engaged; the store answers for anything the
  /// snapshot has not caught up with. Asking only the store would put a window
  /// between the mirror landing and the sampler running in which our own set
  /// reads as the user's.
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

  /// Engages `size` as a preview. The caller holds the AR12 gate and has
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

  // MARK: - Unattended engage (SS9, SS14; the launch and arrival path)

  /// The reapply decision for one display and, on `.engage`, the engage itself.
  ///
  /// `resolved` is always `SyntheticSizeCatalog.size(matching:)`'s answer:
  /// `SynthesisReapplyPolicy` trusts that input and cannot tell a genuinely
  /// stale descriptor from a caller that skipped the lookup.
  ///
  /// Unattended, so nothing here is previewed and nothing here writes a pref.
  /// What the user stored is what is tried again; a refusal changes no state.
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
      // Unattended and otherwise invisible: without this line, a skipped
      // launch restore is indistinguishable from a pass that never ran.
      log.info(
        "synthesis reapply skipped on display \(display.id): \(String(describing: decision), privacy: .public)"
      )
      return decision
    }
    switch await engage(size, on: display) {
    case .success:
      log.info("synthesis reapply engaged \(size.logicalWidth)x\(size.logicalHeight) on display \(display.id)")
    case let .failure(failure):
      // Unattended, so this is the only record. No pref is rewritten: what the
      // user chose is what gets tried again next time the display shows up.
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

  /// Records a kept synthesized size (SS11's ordering hangs off this moment:
  /// the engage has landed and been verified before anything is stored).
  ///
  /// `unwindWasIncomplete` is the one case where a `.committed` outcome is not
  /// evidence of a healthy set: a confirm following a FAILED revert can return
  /// the identical retained pairing, which the engine kept precisely because
  /// something it tried to take down is still standing. The size is persisted
  /// either way (the user asked for it and it is on the glass), and the
  /// incomplete unwind is surfaced rather than papered over.
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

  // MARK: - Opt-in (SS11)

  /// Turns the per-display opt-in on or off.
  ///
  /// **Off tears down BEFORE the pref persists** (SS11, the D29 ordering
  /// shape). A pref written first would leave the app opted out with a
  /// synthesis set still standing and no surface that still offers to take it
  /// down: the picker's synthesized rows are exactly what the opt-in hides. So
  /// a failed disengage LEAVES THE DISPLAY OPTED IN, and says so.
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
  /// BOTH keys (SS11 applies to reset paths in the same order).
  ///
  /// Its own method rather than two more names in the pane's batch write,
  /// because a batch pref write cannot perform a verified disengage. Returns
  /// false when the teardown failed, in which case nothing was cleared.
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
  /// `destroyAll` and before the domain wipe.
  ///
  /// Without it the host takes the synthesis slots down behind the engine's
  /// back, leaving the pairing table describing a virtual display that has
  /// departed and a physical panel still mirroring nothing. The prefs are
  /// cleared by the wipe that follows, which is SS11's ordering: teardown
  /// first, keys after.
  ///
  /// **Returns false when it refused**, which is not the same as "nothing came
  /// down": the pairing table is EMPTY for the whole of an engage, so an empty
  /// table is only evidence of a clean machine while nothing is running. A
  /// caller that reads the table to decide whether the teardown worked has to
  /// read this first (`MirroringCoordinator.unwindingSynthesis` does).
  @discardableResult
  func disengageAllForReset() async -> Bool {
    // Refused rather than run, and it is the FIRST thing checked. The snapshot
    // below is empty for the whole multi-second engage, so every question asked
    // of it in that window answers "nothing is engaged" about a machine that is
    // about to have a synthesis set on it.
    guard !isWorking else {
      log.error("synthesis: a teardown was asked for while a hardware sequence was still running; nothing was taken down")
      return false
    }
    guard !pairings.isEmpty else { return true }
    // The result is DISCARDED, deliberately, and this is the one path where
    // that is right. Everywhere else a preview that would not stand down
    // refuses the operation; here the operation is the whole-app reset, which
    // is about to wipe the domain, drop every controller and rebuild. A
    // synthesis set left standing because a preview refused to revert would
    // outlive all of that with nothing left that knows about it, so the reset
    // proceeds and the engine's own disengage below is the teardown that
    // matters.
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

  /// A picker-driven ordinary size choice over a COMMITTED set (SS10): the
  /// set comes down through the engine before any mode may touch the panel,
  /// which is otherwise a mirror slave the apply would land on invisibly.
  /// Returns false without touching anything when it refuses; the caller
  /// refuses the mode change in turn.
  /// `fromQueueContext: true` because the select path runs INSIDE the preview
  /// queue: BOTH `endOutstandingPreview` and `releaseClaimIfIdle` re-enter the
  /// queue, which waits on the operation doing the waiting. Measured twice on
  /// 2026-08-18: the select hung at the release with the gate claim held, so
  /// every later pick enqueued forever and arrangements were refused with
  /// "displayModes is reconfiguring displays". The caller has already stood
  /// the previews down, and its own `adopt` is the AR12 releaser for the
  /// claim this leaves held.
  func disengageForModeChange(_ display: ConfiguredDisplay) async -> Bool {
    await disengageForOptOut(display, fromQueueContext: true)
  }

  /// Clears the stored stop without touching the opt-in or the machine.
  /// For the kept-ordinary-mode funnel: a kept normal size is an explicit
  /// choice against the stored stop, which would otherwise re-engage at the
  /// next launch over the size the user just kept.
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
  /// keeps SS11's ordering honest: both callers write prefs only after this
  /// says the machine is clean.
  private func disengageForOptOut(
    _ display: ConfiguredDisplay, fromQueueContext: Bool = false
  ) async -> Bool {
    // BEFORE the `isEngaged` question, not after. `isEngaged` reads the
    // snapshot, which is empty for the whole of an engage, so an in-flight
    // engage would otherwise answer "nothing to take down", let the prefs be
    // written, and then land: an engaged set with the rows that could take it
    // down hidden behind an opt-in that is now off.
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
    // AR12, asked before the reconfiguration for the reason every other
    // claimant asks before its apply: a refusal has to cost nothing, and a
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
    // Through the funnel, never `gate.release` from here: every preview was
    // ended before the claim, but the disengage above takes seconds, and a
    // select landing inside that window is GRANTED the gate because it names
    // the same claimant. See `releaseClaimIfIdle`. From the queue context the
    // funnel would re-enter the queue and hang with the claim held; the
    // calling select's own `adopt` releases instead.
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

  /// Takes down every synthesis set whose physical panel has left.
  ///
  /// Both halves matter. A pairing under PREVIEW goes through the session, so
  /// its record and its countdown go with it. A pairing already kept has no
  /// session record, and leaving it would hold a slot and a virtual display for
  /// a panel that is not attached, which is also what would put a departed
  /// panel's name in an arrangement signature.
  func noteDepartures(live: Set<CGDirectDisplayID>) async {
    // A refusal names a display by its RUNTIME id, and the next display to
    // arrive can inherit it, so one about a display that has gone has to go
    // with it rather than resurface on whatever takes its place.
    if let refusal, !live.contains(refusal.displayID) { dismissRefusal() }
    let departed = pairings.map(\.physicalDisplayID).filter { !live.contains($0) }
    guard !departed.isEmpty else { return }
    let previewed = await session.previewedSynthesis?.physicalDisplayID
    for displayID in departed {
      if displayID == previewed {
        _ = await revertOnDeparture(displayID: displayID)
        continue
      }
      // Through the driver: the restore skips a display that is gone (the
      // achieved read is nil), but the driver clears its own-mode record on
      // the successful teardown, and display IDs reassign across a replug,
      // so a stale record must not wait for whatever takes the ID next.
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
    // The pairing is the authority on synthesis topology (SS1), and the store
    // is where the app publishes topology, so this is where the two meet.
    //
    // It is also the UN-STAMP. The engine announces a virtual display before it
    // mirrors onto it (see the hook wired in `init`), which deliberately
    // over-stamps; this republishes the authoritative table, so a failed engage
    // takes its announcement back on the same path a successful one confirms
    // its own. A pairing the engine RETAINED after an incomplete unwind stays
    // stamped, which is correct: something is still standing.
    topologyStore.noteSynthesisMasters(masterIDs)
  }

  /// Runs a hardware operation with the working depth raised and the snapshot
  /// re-read afterwards, so no path can perform one and forget either.
  ///
  /// Re-entrant: `engaging` runs a departure sweep inside its own call, and the
  /// sweep performs disengages. The depth is what keeps `isWorking` true across
  /// all of that.
  private func performing<T>(_ operation: () async -> T) async -> T {
    workDepth += 1
    let result = await operation()
    workDepth -= 1
    await refreshSnapshot()
    return result
  }

  /// `performing`, plus the departure sweep an ENGAGE has to run for itself.
  ///
  /// The depth is held across BOTH halves rather than left to the inner
  /// `performing`: the sweep is part of the engage, and a teardown granted in
  /// the gap between them would be granted against a machine that is still
  /// being reconfigured.
  private func engaging<T>(_ operation: () async -> T) async -> T {
    workDepth += 1
    defer { workDepth -= 1 }
    let result = await performing(operation)
    await sweepDeparturesAfterEngage()
    return result
  }

  /// Take down any pairing whose physical panel is no longer attached, once,
  /// straight after an engage.
  ///
  /// Every other departure sweep keys on the pairing SNAPSHOT, and the snapshot
  /// is empty (or stale) for the whole of an engage, which runs for seconds. A
  /// panel that leaves inside that window therefore reaches no sweep at all,
  /// and nothing re-runs them once the engage lands: the pairing survives,
  /// naming a display that is not there, holding one of two slots, and putting
  /// a departed panel's name into the arrangement signature and the reapply
  /// pass. So the engage asks the question itself, at the one moment the
  /// snapshot is fresh again.
  ///
  /// The live list, not the notification's: this is about hardware to take
  /// down, so what matters is what is attached NOW. Same reading as
  /// `DisplayModeCoordinator.dropSynthesisOnDepartedDisplay`.
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

  /// The one place an outcome becomes a refusal the UI can render.
  ///
  /// `.committed` and `.reverted` are answers, not refusals, so they clear
  /// whatever was on screen. `.stale` is final and says nothing worth showing:
  /// the preview it named is gone, and the surface asking about it is about to
  /// be rebuilt from the session anyway.
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
