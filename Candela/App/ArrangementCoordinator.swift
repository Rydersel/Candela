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
/// 1. **Every session-touching operation is serialised** through `pending`.
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

  @ObservationIgnored weak var confirmation: (any ArrangementConfirmationPresenting)?
  /// Friendly-name resolution belongs to the surfaces. Empty by default so an
  /// unwired coordinator looks unfinished in testing rather than plausibly right.
  @ObservationIgnored var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  @ObservationIgnored private let configurator: any DisplayArrangementConfiguring
  /// AR12. Held from just before the layout applies until nothing is
  /// outstanding. Not defaulted — a per-coordinator default would compile, run,
  /// and exclude nobody.
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  @ObservationIgnored private let session: ArrangementPreviewSession
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var inFlight = 0
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "arrangement"
  )

  init(
    gate: DisplayReconfigurationGate,
    configurator: any DisplayArrangementConfiguring = CoreGraphicsArrangementConfigurator(),
    countdownSeconds: Int = 30
  ) {
    self.gate = gate
    self.configurator = configurator
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
  }

  /// The notification token is deliberately not unregistered here: it is not
  /// `Sendable`, so a nonisolated `deinit` cannot touch it. Harmless — this
  /// object lives as long as the app and the block holds `self` weakly, so a
  /// surviving registration is inert rather than dangling.
  deinit {
    countdown?.cancel()
    pending?.cancel()
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
    refreshArrangement()
    // A layout for a display set that has changed cannot be restored as a whole
    // (AR4), so offering it back would offer a button that can only fail.
    if let recoverableLayout,
       Set(recoverableLayout.tiles.map(\.id)) != Set(arrangement.tiles.map(\.id)) {
      self.recoverableLayout = nil
      syncConfirmation()
    }
    enqueue {
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
    // Raised HERE, synchronously, and not inside `enqueue`: a control that
    // queues main-actor work and only then disables itself is a control two
    // clicks get through — and `enqueue` also carries the screen-parameters
    // reconciliation, which is not an apply and must not grey out the answer
    // buttons every time anything on the machine reconfigures. Counted rather
    // than boolean, so two queued applies do not have the first one's
    // completion clear the flag for the second.
    inFlight += 1
    isApplying = true
    enqueue {
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

  /// `answered` is the preview the caller was LOOKING AT. It is carried into the
  /// session, which refuses an answer that no longer names the outstanding
  /// preview — so an answer can only ever resolve what the user was reading, and
  /// queue ordering is demoted to an optimisation.
  @discardableResult
  func confirm(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  /// Clears everything the report card renders, and syncs the window in the same
  /// operation rather than leaving a caller to pair the two.
  ///
  /// It is deliberately NOT claimed to be the only writer of these four:
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
    syncConfirmation()
  }

  // MARK: - Serialisation

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = pending
    pending = Task { @MainActor in
      _ = await previous?.value
      await operation()
    }
  }

  private func enqueueReturning<T: Sendable>(
    _ operation: @escaping @MainActor () async -> T
  ) async -> T {
    let previous = pending
    let task = Task { @MainActor () -> T in
      _ = await previous?.value
      return await operation()
    }
    // The chain is Void-typed, so the next operation waits on this one through
    // an erased wrapper rather than on its result.
    pending = Task { @MainActor in _ = await task.value }
    return await task.value
  }

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
    guard wanted != live else {
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

  private func resolve(_ answered: Preview, keeping: Bool) async -> ModePreviewOutcome {
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
    return outcome
  }

  /// What to do with the failure currently on screen when re-reading the session.
  private enum FailureUpdate { case clear, keep, set(DisplayConfigError) }

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
  /// Every write to `preview`, `lastInvalidLayout`, `lastFailure`, `blockedBy`
  /// or `recoverableLayout` has to be followed by this call. An un-synced write
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
      || recoverableLayout != nil {
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
    countdown?.cancel()
    let session = session
    countdown = Task.detached { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        let outcome = await session.tick()
        Task { @MainActor [weak self] in
          guard let self else { return }
          if case let .failed(error) = outcome {
            enqueue { await self.adopt(.set(error)) }
          } else {
            enqueue { await self.adopt(.keep) }
          }
        }
        // The countdown fires at most once; whatever it returned, it is spent.
        if outcome != nil { return }
      }
    }
  }

  private func stopCountdown() {
    countdown?.cancel()
    countdown = nil
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
