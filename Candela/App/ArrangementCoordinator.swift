import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of the display arrangement: the request, the preview
/// countdown, and the one surface that reports on either.
///
/// `DisplayModeCoordinator`'s shape, for its reasons, and they are not optional:
///
/// 1. **Every session-touching operation is serialised** through `queue`.
///    Without it two drops both suspend inside `begin()`, the actor serialises
///    them, and their main-actor continuations resume in an order unrelated to
///    the actor's — leaving the window describing one layout while "Keep"
///    commits the other, permanently.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session is the one that decides what is applied.
///
/// A view cannot own this: the countdown has to keep running after the canvas
/// that started it has gone, which is the entire safety argument for previewing
/// at all — an arrangement change can move the menu bar onto a display the user
/// is not looking at, or strand the pointer.
@MainActor @Observable
final class ArrangementCoordinator {
  /// A layout applied and not yet resolved. Every field is a copy of the
  /// session's own answer, except `notices`, which is read once from what the
  /// apply ACHIEVED (§6.3) — macOS adjusts a requested layout silently, and the
  /// achieved layout is captured at `begin` and does not change afterwards.
  struct Preview: Equatable {
    let value: PreviewedArrangement
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. Nothing
    /// auto-retries, so silence would leave the user on a layout they never
    /// approved.
    var failure: DisplayConfigError?
    /// Reported by the session, not inferred: a failed expiry disarms the
    /// countdown while a failed commit deliberately leaves it armed.
    var isCountingDown: Bool
    /// What the system did that was not asked for.
    var notices: [ArrangementApplyNotice]
  }

  /// The layout on screen, as last sampled. Read by the surfaces; never
  /// re-derived in a view.
  private(set) var arrangement = DisplayArrangement(tiles: [])
  private(set) var preview: Preview?
  /// AR7: the layout overlaps, or strands a display where nothing can reach it.
  /// Empty means "no such refusal", the same idiom `lastPartialBreak` uses —
  /// there is one refusal of this kind, so an enum with one case would be a type
  /// pretending to be a decision.
  private(set) var lastInvalidLayout: [ArrangementProblem] = []
  private(set) var lastFailure: DisplayConfigError?
  /// The four-way gate refused this request, and names who holds it (AR12).
  private(set) var blockedBy: ReconfigurationClaimant?
  /// The layout the machine was in before an apply that DIVERGED, kept so it can
  /// be offered back. See `noteRecoverableLayout`.
  private(set) var recoverableLayout: DisplayArrangement?
  private(set) var isApplying = false
  /// A saved layout that could not be restored exactly.
  ///
  /// Restore is unattended, so this is the ONLY way the user finds out. It
  /// survives until they dismiss it, or until a later restore pass has a newer
  /// outcome for the set that is attached then — the point is that it is still
  /// there the next time they look, not that it was true at the moment nobody
  /// was watching. Nothing clears it on a departure alone (SO8); the comment in
  /// `displaysChanged` says why that is deliberate rather than an oversight.
  /// `DisplayModeCoordinator.ReapplyReport`'s job,
  /// with one value rather than a per-display map: a layout is a fact about the
  /// whole set, so there is one of these at a time.
  private(set) var restoreNotice: ArrangementReapplyNotice?

  @ObservationIgnored weak var confirmation: (any ArrangementConfirmationPresenting)?
  /// Called after a commit actually wrote `savedArrangements`, so the
  /// propagation seam hears about it (D27) whichever surface answered. Owned
  /// here for `DisplayModeCoordinator.didStoreMode`'s reason: the answering view
  /// used to be trusted to fan out by hand, and the moment a second surface
  /// offers the same answer, one of them forgets.
  @ObservationIgnored var didSaveArrangement: () -> Void = {}
  /// Friendly-name resolution belongs to the surfaces. Empty by default so an
  /// unwired coordinator looks unfinished in testing rather than plausibly right.
  @ObservationIgnored var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  @ObservationIgnored private let configurator: any DisplayArrangementConfiguring
  /// AR12. Held from just before the layout applies until nothing is
  /// outstanding. Not defaulted — a per-coordinator default would compile, run,
  /// and exclude nobody.
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  @ObservationIgnored private let session: ArrangementPreviewSession
  @ObservationIgnored private let persistence: ArrangementPersistence
  /// Which reconfigurations count as an arrival for a LAYOUT. It lives in
  /// `CandelaKit` under test because its two failure directions are both timing
  /// and both are invisible from here: too eager fights the user forever, too
  /// shy silently fails to restore anything on the reconnect the feature is
  /// named for.
  @ObservationIgnored private var arrivals = TopologyArrivalTracker()
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
  @ObservationIgnored private var inFlight = 0
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "arrangement"
  )

  #if DEBUG
    @ObservationIgnored private var debugReportObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var debugPreviewObserver: (any NSObjectProtocol)?
  #endif

  init(
    gate: DisplayReconfigurationGate,
    configurator: any DisplayArrangementConfiguring = CoreGraphicsArrangementConfigurator(),
    persistence: ArrangementPersistence = ArrangementPersistence(),
    countdownSeconds: Int = 30
  ) {
    self.gate = gate
    self.configurator = configurator
    self.persistence = persistence
    session = ArrangementPreviewSession(
      configurator: configurator, countdownSeconds: countdownSeconds
    )
    arrangement = configurator.currentArrangement()
    // Observed here rather than in a pane: a display can depart while the canvas
    // is being dismissed for that very reason, and an outstanding preview over a
    // display set that no longer exists has to be dropped whether or not anything
    // is on screen.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.displaysChanged() }
    }

    #if DEBUG
      // Screenshot validation only, and permanent for the reason its three
      // siblings in `MirroringCoordinator` and `RotationCoordinator` are:
      // `ArrangementConfirmationWindow` cannot be reached from a script.
      // Clicking the pane's canvas needs an Accessibility grant this machine
      // does not have, and there is no arrangement hotkey. Until this existed,
      // that window was the ONE confirmation surface in the app whose layout,
      // contrast and truncation had never been looked at.
      //
      // Compiled out of Release BY CONSTRUCTION, not by remembering to delete
      // it; the standing review step (grep every Mach-O in the Release bundle,
      // with a Debug positive control) still applies.
      debugReportObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.rydersel.Candela.debug.showArrangementReport"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          // Real display ids where there are two, so the NAMED sentence renders
          // rather than the unnamed fallback — the named one is the longer of
          // the two and the one that can truncate.
          let ids = self.arrangement.tiles.map(\.id)
          self.lastInvalidLayout = [.overlap(ids.first ?? 1, ids.dropFirst().first ?? 2)]
          self.syncConfirmation()
        }
      }

      // The other half: the PREVIEW card is the one with two answers, so it is
      // the one where "which is the primary?" can go wrong. It posts the genuine
      // request through the genuine path, with the real countdown behind it —
      // and it asks `ArrangementDockPolicy` for the destination, so what it
      // applies is a layout that is legal by construction. **Never the
      // built-in**: it is the owner's working screen, and moving it is how the
      // menu bar ends up somewhere nobody asked for.
      debugPreviewObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.rydersel.Candela.debug.showArrangementPreview"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let topology = self.configurator.currentTopology()
          let movable = topology.displays.filter { !$0.isBuiltIn && !$0.isMirrorSlave }
          for display in movable {
            for direction in ArrangementDirection.allCases {
              if let moved = ArrangementDockPolicy.move(
                display.id, direction, in: topology.arrangement
              ) {
                self.apply(moved)
                return
              }
            }
          }
          self.log.info("debug preview: no external display has a legal move")
        }
      }
    #endif
  }

  /// The notification token is deliberately not unregistered here: it is not
  /// `Sendable`, so a nonisolated `deinit` cannot touch it. Harmless — this
  /// object lives as long as the app and the block holds `self` weakly, so a
  /// surviving registration is inert rather than dangling.
  deinit {
    countdown.stop()
    queue.cancel()
  }

  // MARK: - Sampling

  /// Re-reads the layout on screen. Called at launch, on every screen-parameters
  /// change, and after anything this app applies.
  func refreshArrangement() {
    arrangement = configurator.currentArrangement()
  }

  /// Something reconfigured — which is most of the time NOT a display arriving
  /// or leaving, since this app's own applies post the same notification.
  ///
  /// So it does not decide anything about the preview itself. It re-samples, and
  /// asks the SESSION whether the display set has moved out from under its
  /// capture: the session owns the one predicate every revert path shares, so
  /// this proactive call and a countdown expiring a moment later cannot disagree
  /// about it.
  func displaysChanged() {
    let topology = configurator.currentTopology()
    arrangement = topology.arrangement
    // A departure is what makes the next appearance an arrival, so it is
    // recorded HERE — synchronously inside the screen-parameters handler, from
    // the ONLINE list — rather than only where the restore pass runs. That pass
    // hangs off the app's debounced topology stream, whose one-second quiet
    // window would coalesce an unplug and a replug into a single event with the
    // display present at both ends, and the layout saved for the set that came
    // back would never be restored.
    arrivals.noteObserved(live: Set(topology.displays.map(\.id)))
    // `restoreNotice` is deliberately NOT cleared here. It is written by the
    // restore pass and only there, and every set change produces an arrival that
    // runs that pass — which writes the new outcome, including "nothing to say".
    // Clearing it on any reconfiguration would take the report away on the next
    // resolution change, which is not a set change and says nothing about it.
    //
    // A layout for a display set that has changed cannot be restored as a whole
    // (AR4), so offering it back would offer a button that can only fail.
    if let recoverableLayout,
       Set(recoverableLayout.tiles.map(\.id)) != Set(arrangement.tiles.map(\.id)) {
      self.recoverableLayout = nil
      syncConfirmation()
    }
    queue.enqueue {
      guard await self.session.discardIfTopologyChanged() else { return }
      self.log.info("Dropped an unanswered arrangement preview: the display set changed")
      await self.adopt(.clear)
    }
  }

  // MARK: - Commands

  /// Requests `wanted`: previews it and starts the countdown, or refuses it with
  /// a reason and applies nothing.
  ///
  /// Synchronous and fire-and-forget on purpose — the queue owns the ordering, so
  /// no caller can create a second in-flight apply by spawning its own task.
  func apply(_ wanted: DisplayArrangement) {
    // Raised HERE, synchronously, and not inside the queue: a control that
    // queues main-actor work and only then disables itself is a control two
    // clicks get through, and the queue also carries the screen-parameters
    // reconciliation, which is not an apply and must not grey out the answer
    // buttons every time anything on the machine reconfigures. Counted rather
    // than boolean, so two queued applies do not have the first one's
    // completion clear the flag for the second.
    inFlight += 1
    isApplying = true
    queue.enqueue {
      await self.performApply(wanted)
      self.inFlight -= 1
      if self.inFlight == 0 { self.isApplying = false }
    }
  }

  /// Puts the machine back where it was before an apply that diverged.
  ///
  /// Goes through `apply`, so the restoration gets the same preview, the same
  /// countdown and the same refusals as any other layout change. It is a
  /// reconfiguration like any other and there is no reason for it to be trusted
  /// more than the one that produced the mess.
  func restoreRecoverableLayout() {
    guard let recoverableLayout else { return }
    apply(recoverableLayout)
  }

  /// Restores the saved layout for the display set that has just ARRIVED.
  ///
  /// Called from launch and from the app's debounced
  /// `CGDisplayReconfigurationCallBack` intake, and from nowhere else — never on
  /// a pref write, never on a timer.
  ///
  /// The arrival gate is the substance of this, not bookkeeping. A
  /// reconfiguration event is ALSO what the user dragging displays in System
  /// Settings produces, so a pass that restored on every event would undo that
  /// change within a second, permanently, and make the arrangement pane of
  /// System Settings unusable. Candela's opinion applies when the display set
  /// changes; from then until it changes again, the layout belongs to the user.
  ///
  /// Deliberately NOT a preview. Nobody is watching, and a thirty-second
  /// countdown that defaults to revert would undo every remembered layout a
  /// moment after every reconnect — the exact opposite of the feature. It
  /// commits at `ArrangementReapplyPolicy.scope` directly, which is also why it
  /// never calls `ArrangementPreviewSession.begin`: `begin` would arm a
  /// countdown against nobody, and its capture would become the fallback for the
  /// next preview a person actually asks for.
  ///
  /// It writes NO preferences. A layout that could not be restored is not
  /// rewritten to whatever the machine settled on — what the user saved is what
  /// gets tried again the next time that display set shows up.
  ///
  /// **Awaitable, and its one caller awaits it.** `UnattendedRestoreSequence`
  /// runs the stored-mode reapply and then this, as one operation: the two claim
  /// the same gate, and a refused pass cannot rely on the winner producing a
  /// reconfiguration event when the winner applied nothing.
  func restoreSavedArrangement() async {
    await queue.enqueueReturning { await self.performRestore() }
  }

  /// `answered` is the preview the caller was LOOKING AT. It is carried into the
  /// session, which refuses an answer that no longer names the outstanding
  /// preview — so an answer can only ever resolve what the user was reading, and
  /// queue ordering is demoted to an optimisation.
  @discardableResult
  func confirm(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  /// Clears everything the report card renders, and syncs the window in the same
  /// operation rather than leaving a caller to pair the two.
  ///
  /// It is deliberately NOT claimed to be the only writer of these five:
  /// `recoverableLayout` is also dropped in `displaysChanged`, because a layout
  /// naming a display set that no longer exists cannot be restored as a whole
  /// (AR4) and offering it would offer a button that can only fail. The rule that
  /// does hold everywhere is the one below `syncConfirmation`: every write to any
  /// of them is followed by that call.
  func dismissReport() {
    lastInvalidLayout = []
    lastFailure = nil
    blockedBy = nil
    recoverableLayout = nil
    restoreNotice = nil
    syncConfirmation()
  }

  // MARK: - Serialisation
  //
  // The queue itself is `PreviewQueue` in CandelaKit (#68): four coordinators
  // held four byte-identical copies of it, and the countdown driver beside it.

  // MARK: - Operations (always inside the queue)

  private func performApply(_ wanted: DisplayArrangement) async {
    dismissReport()
    let live = configurator.currentArrangement()

    // A no-op. `ArrangementPreviewSession.begin` refuses one with
    // `illegalArgument` — correctly, since arming a countdown over a change that
    // changes nothing is the shape the mirroring defect took — but "illegal
    // argument" is not a sentence to show someone who dropped a display back
    // where it started. Filtered here rather than reported; Task 6's proposal
    // type will filter it a step earlier, and this stays as the backstop.
    // Compared on the ANCHORED form, the same one the plan will stage: an
    // unanchored translation (dragging the only display, say) changes nothing
    // relative to anything and must land here, not in the error card.
    guard (wanted.anchored(preservingMainOf: live) ?? wanted) != live else {
      log.debug("arrangement request is a no-op")
      return
    }

    // AR7. macOS cannot be made to hold an overlapping or disconnected layout —
    // it silently moves things somewhere of its own choosing instead — so an
    // invalid request is refused rather than sent and reported on. It is also
    // the case `ArrangementPlan.expectsExactOrigins` turns the post-commit check
    // OFF for, which is precisely when a divergence would go unnoticed.
    let problems = ArrangementRules.problems(in: wanted)
    guard problems.isEmpty else {
      lastInvalidLayout = problems
      log.info("Refused an arrangement: \(problems.count, privacy: .public) problem(s)")
      syncConfirmation()
      return
    }

    // AR12, asked BEFORE the apply because that is what makes a refusal cost
    // nothing: no transaction has been opened and no display has moved. Granted
    // when we are already the holder — a second drop during a preview is a
    // supported operation, and the session keeps the ORIGINAL fallback across it.
    if let holder = await gate.claim(.arrangement).refusedBy {
      blockedBy = holder
      log.info("Refused an arrangement: \(holder.rawValue, privacy: .public) is reconfiguring displays")
      syncConfirmation()
      return
    }

    switch await session.begin(wanted) {
    case .success:
      // Cancelled BEFORE the await, not after `startCountdown()` gets to it: a
      // previous preview's driver is still looping, and a tick landing during
      // `adopt` would knock the fresh preview from 30 seconds to 14. It narrows
      // the window rather than closing it — a tick already inside `session.tick()`
      // still counts against the new preview, and closing that needs the session
      // to know WHICH preview a tick is for.
      stopCountdown()
      await adopt(.clear)
      startCountdown()
    case let .failure(error):
      lastFailure = error
      await noteRecoverableLayout(before: live)
      // Rebuilt FROM the session, which also releases the gate when nothing is
      // outstanding — and after a failed begin, usually nothing is.
      await adopt(.clear)
    }
    refreshArrangement()
  }

  private func performRestore() async {
    // ONE enumeration for both halves: the completeness check below is only
    // meaningful if the display list and the layout describe the same instant.
    let topology = configurator.currentTopology()
    arrangement = topology.arrangement

    let claimed = arrivals.claimArrivals(online: topology.displays)
    guard !claimed.isEmpty else { return }

    // An outstanding preview outranks a saved layout: a person is looking at a
    // change right now, and restoring under them would move the displays out
    // from beneath a fallback that was captured before it. Every claim goes
    // back — this is "not now", not "never" — and resolving the preview is
    // itself a reconfiguration, so the event it produces calls this again.
    guard await session.previewedArrangement == nil else {
      release(claimed)
      return
    }
    // AR12, asked BEFORE anything is staged, so a refusal costs nothing. Note
    // the guard above is what makes the release at the end ours to make: with no
    // preview outstanding, a claim taken here is protecting this pass alone.
    //
    // The claims go back on a refusal, which needs something to call this pass
    // again — and that is NOT something the gate promises. It is true only of a
    // claimant holding the gate around an outstanding reconfiguration or
    // preview, whose resolution is itself a reconfiguration. The one claimant it
    // was false for was the stored-mode reapply, which usually applies nothing;
    // `UnattendedRestoreSequence` runs that pass to completion before this one
    // starts, so it can no longer be the holder here.
    if let holder = await gate.claim(.arrangement).refusedBy {
      log.info("Deferred a layout restore: \(holder.rawValue, privacy: .public) is reconfiguring displays")
      release(claimed)
      return
    }

    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: persistence.isRestoreEnabled,
      arrivals: claimed,
      stored: persistence.savedArrangement(for: TopologySignature(topology.arrangement)),
      attached: topology.displays,
      current: topology.arrangement
    )

    if decision.isDeferred {
      // The layout read could not describe every attached display, so it cannot
      // be acted on as a whole (AR4). The claims go back and the next topology
      // event tries again with a machine that can answer.
      release(claimed)
    } else {
      // The two are handled independently rather than as an either/or, because
      // the decision type does not promise they are exclusive — a policy that
      // one day both applies something and has something to say about it must
      // not have the apply silently skipped by a `??`.
      var notice = decision.notice
      if let layout = decision.arrangementToApply {
        notice = apply(restored: layout, over: topology.arrangement) ?? notice
      }
      restoreNotice = notice
      if let restoreNotice {
        log.error("Could not restore the saved layout: \(String(describing: restoreNotice), privacy: .public)")
      }
      syncConfirmation()
      refreshArrangement()
    }

    // Nothing here opens a preview, so the claim this pass took is spent — but
    // the release is still guarded, because between the check above and here the
    // session is the only authority on whether anything is outstanding, and
    // freeing a claim that is protecting a preview is the interleave the gate
    // exists to prevent.
    if await session.previewedArrangement == nil { await gate.release(.arrangement) }
  }

  /// Commits a restored layout. Returns `nil` on success, or what to report.
  private func apply(
    restored layout: DisplayArrangement, over live: DisplayArrangement
  ) -> ArrangementReapplyNotice? {
    guard let plan = ArrangementPlan(applying: layout, to: live) else {
      // A structural refusal of the layout as a whole — an origin outside
      // `Int32`, or a display that has become a mirror slave since the read.
      // Reported rather than swallowed: unattended, silence is indistinguishable
      // from a restore that worked.
      return .failed(DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue))
    }
    do {
      _ = try configurator.apply(plan, scope: ArrangementReapplyPolicy.scope)
      log.log("Restored the saved layout for \(plan.changes.count, privacy: .public) displays")
      return nil
    } catch let error as DisplayConfigError {
      // `apply` throws when a stage or the completion fails AND when the
      // achieved layout is not the requested one (#53). On the unattended path
      // that second case is precisely what must not be swallowed: the machine is
      // in a layout CoreGraphics chose, and `try?` here would leave the app
      // reporting a successful restore.
      return .failed(error)
    } catch {
      return .failed(DisplayConfigError(cgErrorCode: -1))
    }
  }

  private func release(_ claimed: Set<CGDirectDisplayID>) {
    for id in claimed { arrivals.release(id) }
  }

  // MARK: - The saved-layout opt-in

  /// Read live from prefs rather than mirrored into a stored bool, for the
  /// reason `SMAppService.mainApp.status` is (D10): the settings reset wipes the
  /// whole domain, and a mirror would survive it.
  var isRestoringLayout: Bool { persistence.isRestoreEnabled }

  /// Turning it ON also saves the layout on screen now.
  ///
  /// `DisplayModeCoordinator.setRemembering`'s reason exactly: without that, the
  /// toggle does nothing until the next arrangement change, so it reads as
  /// broken on the very reconnect it was turned on for — and the restore engine
  /// would ship with nothing to restore. Turning it OFF leaves the saved layout
  /// alone, matching `ArrangementPersistence.clear`'s ruling that "forget this
  /// layout" and "stop restoring layouts" are separate answers.
  ///
  /// The `savedArrangements` fan-out is NOT the caller's job: it is announced
  /// from inside `saveIfRestoring` (D27). A view trusted to fan out by hand is
  /// the arrangement that lost the announcement the first time.
  func setRestoringLayout(_ restoring: Bool) {
    persistence.setRestoreEnabled(restoring)
    guard restoring else { return }
    queue.enqueue {
      // NOT while a preview stands. The layout on screen during a countdown is
      // one nobody has approved, and saving it would file the very arrangement
      // the user is about to revert — the settings window and the confirmation
      // panel are on screen together for thirty seconds, so this is reachable.
      // Asked of the SESSION rather than of `preview`, which is nil for several
      // awaits after a `begin()` succeeds and so cannot answer it. Nothing is
      // lost by waiting: keeping the change saves it through `resolve`.
      guard await self.session.previewedArrangement == nil else { return }
      // A fresh sample rather than the last one this coordinator happens to
      // hold: the pane can sit open across a reconfiguration, and saving a stale
      // layout would file an arrangement the machine is not in under the set it
      // is in.
      self.refreshArrangement()
      self.saveIfRestoring()
    }
  }

  /// Records the layout the user just approved, so the next time this display
  /// set shows up it comes back.
  ///
  /// From the ACHIEVED layout, never from what was requested — macOS adjusts a
  /// requested layout silently, and saving the request would store an
  /// arrangement the machine was never in.
  private func saveIfRestoring() {
    guard persistence.isRestoreEnabled else { return }
    persistence.save(arrangement)
    didSaveArrangement()
  }

  /// Remembers the layout to offer back after an apply that DIVERGED.
  ///
  /// Task 10's accepted cost, carried forward: a `begin` whose apply diverged
  /// (#53 — CoreGraphics accepts a transaction, reports `.success`, and achieves
  /// something else) leaves the session holding nothing, so the layout the user
  /// started from is gone and the next preview would capture the diverged one as
  /// the thing to fall back to. The session will not hold it. If it is to be
  /// offered back, it has to be held here.
  ///
  /// Offered ONLY when the machine actually moved, which is why this compares
  /// rather than assuming: `begin` also fails without applying anything — an
  /// unreadable sweep, a plan it could not express as a whole — and an undo for
  /// a machine that never moved is a button that does nothing.
  private func noteRecoverableLayout(before live: DisplayArrangement) async {
    guard await session.previewedArrangement == nil else { return }
    guard configurator.currentArrangement() != live else { return }
    recoverableLayout = live
    log.error("An arrangement apply diverged; holding the previous layout so it can be restored")
  }

  private func resolve(_ answered: Preview, keeping: Bool) async -> PreviewOutcome {
    let outcome = keeping
      ? await session.confirm(answered.value)
      : await session.revert(answered.value)
    switch outcome {
    case .committed, .reverted:
      await adopt(.clear)
    case let .failed(error):
      await adopt(.set(error))
    case .stale:
      // Nothing was resolved: the outstanding preview is not the one this answer
      // was about. Keep whatever failure is on screen — it belongs to the
      // preview that is still there, not to this answer.
      await adopt(.keep)
    }
    refreshArrangement()
    // AFTER the re-read, and only for a layout the user kept: this is the one
    // moment a layout is known to be both on screen and approved. Saving the
    // requested layout instead would store an arrangement the machine was never
    // in, since macOS adjusts a request silently.
    if case .committed = outcome { saveIfRestoring() }
    return outcome
  }

  /// Rebuilds the UI's picture FROM the session. THE only writer of `preview`,
  /// so no path can leave the two disagreeing — including a countdown tick that
  /// resumes late, which reconciles here instead of being discarded. A discarded
  /// outcome is exactly how a preview with a disarmed countdown and no driver
  /// gets created.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewedArrangement else {
      preview = nil
      stopCountdown()
      // THE release (AR12). Here rather than at each call site because this
      // funnel already runs after every path that can end a preview — a failed
      // begin, an answer, an expiry, and the display set changing with nobody
      // watching. Unconditional: the gate refuses a release from a claimant that
      // is not holding it.
      await gate.release(.arrangement)
      syncConfirmation()
      return
    }
    let carried: DisplayConfigError? = switch failure {
    case .clear: nil
    case .keep: preview?.value == outstanding ? preview?.failure : nil
    case let .set(error): error
    }
    let counting = await session.isCountingDown
    preview = Preview(
      value: outstanding,
      secondsRemaining: await session.secondsRemaining,
      failure: carried,
      isCountingDown: counting,
      // Read from the ACHIEVED layout the session captured after the apply, not
      // from a fresh sample: the notice is about what THIS apply did, and a
      // sample taken later would fold in anything that happened since.
      notices: ArrangementOutcomePolicy.notices(
        requested: outstanding.requested,
        resulting: outstanding.achieved,
        requestedMain: outstanding.plan.requestedMain
      )
    )
    if !counting { stopCountdown() }
    syncConfirmation()
  }

  /// Points the window at whatever there is to say, or at nothing. Called on
  /// every countdown tick, so the presenter must treat a repeat present of
  /// unchanged content as a no-op.
  ///
  /// Every write to `preview`, `lastInvalidLayout`, `lastFailure`, `blockedBy`,
  /// `recoverableLayout` or `restoreNotice` has to be followed by this call. An
  /// un-synced write
  /// does not merely leave the window stale — it leaves it rendering a state
  /// that no longer exists, i.e. an empty floating panel.
  private func syncConfirmation() {
    if let preview {
      // `confirmationDisplayID` is the display at the origin of the ACHIEVED
      // layout — the one holding the menu bar while the preview stands (§6.2).
      // It is nil only when nothing landed at the origin, which a read that
      // skipped an unreadable display can produce; `CGMainDisplayID()` is then
      // the honest fallback, being by definition a display with the menu bar on
      // it. The alternative the session suggested — the display the user dragged
      // — is knowledge this type does not have either.
      confirmation?.presentArrangementConfirmation(
        .preview(preview.value.confirmationDisplayID ?? CGMainDisplayID())
      )
      return
    }
    if !lastInvalidLayout.isEmpty || lastFailure != nil || blockedBy != nil
      || recoverableLayout != nil || restoreNotice != nil {
      confirmation?.presentArrangementConfirmation(.report)
      return
    }
    confirmation?.dismissArrangementConfirmation()
  }

  /// The countdown driver.
  ///
  /// Detached, and its main-actor hop is fire-and-forget. Both halves matter:
  /// the tick and the revert it triggers run on the session's executor, and the
  /// loop's next sleep is never gated on the main actor having run the previous
  /// UI update. A main thread wedged by a synchronous reconfiguration callback
  /// or by blocking work in a view must not be able to stop the expiry — the
  /// expiry is what rescues a layout nobody can navigate.
  ///
  /// The UI update goes through `enqueue`, not straight to `adopt`: a tick that
  /// lands mid-`begin()` must reconcile after it, not against a session that is
  /// half-way through changing.
  private func startCountdown() {
    let session = session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      // Through the queue, never straight to `adopt`: a tick that landed
      // mid-apply would otherwise publish a picture the apply is about to
      // replace.
      if case let .failed(error) = outcome {
        queue.enqueue { await self.adopt(.set(error)) }
      } else {
        queue.enqueue { await self.adopt(.keep) }
      }
    }
  }

  private func stopCountdown() {
    countdown.stop()
  }
}

/// The surface that reports on an arrangement change independently of whichever
/// view started it. Declared beside the coordinator and AppKit-free, so the
/// contract belongs to the thing that needs it — the window that implements it
/// is an app-target island like every other.
@MainActor
protocol ArrangementConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every tick.
  func presentArrangementConfirmation(_ content: ArrangementConfirmationContent)
  func dismissArrangementConfirmation()
}

/// What the standalone surface is showing. Two cases, not one, because the two
/// outcomes are genuinely different: a preview is a question with a countdown
/// behind it, and a report is a statement with nothing outstanding.
enum ArrangementConfirmationContent: Hashable {
  /// A layout applied and waiting to be answered, placed on the display holding
  /// the menu bar while it stands.
  case preview(CGDirectDisplayID)
  /// A refusal, a failed apply, or a layout offered back after a divergence.
  case report
}
