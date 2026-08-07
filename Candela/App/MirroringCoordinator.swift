import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of the mirror topology, the toggle, and the preview
/// countdown. `DisplayModeCoordinator`'s shape, for its reasons:
///
/// 1. **Every session-touching operation is serialised** through `pending`.
///    Without it two fast clicks both suspend inside `begin()`, the actor
///    serialises them, and their main-actor continuations resume in an order
///    unrelated to the actor's.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session is the one that decides what is applied.
///
/// A view cannot own this: the countdown has to keep running after the panel
/// that started it has closed, which is the entire safety argument for
/// previewing at all.
///
/// **It replaces `Mirroring.engageMirror`**, a transplant from the fork with
/// four traced defects: `kCGConfigurePermanently` for both directions (from a
/// hotkey, naming a scope `DisplayConfigScope` deliberately does not have);
/// every staged return discarded, so a transaction that staged nothing still
/// reported `true`; no `CGDisplayIsAlwaysInMirrorSet` check, so the toggle stuck
/// off forever on such a rig; and a leaked `CGDisplayConfigRef` on both
/// early-return paths. All four are closed by going through
/// `MirrorTopologyPolicy` and `DisplayConfiguring.applyMirroring` — none of them
/// is re-fixed here.
@MainActor @Observable
final class MirroringCoordinator {
  /// A preview that has been applied and not yet resolved. Every field is a
  /// copy of the session's own answer.
  struct Preview: Equatable {
    let value: PreviewedMirrorTopology
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. Nothing
    /// auto-retries, so silence would leave the user on a topology they never
    /// approved, held only until the app exits.
    var failure: DisplayConfigError?
    /// Reported by the session, not inferred: a failed expiry disarms the
    /// countdown while a failed commit deliberately leaves it armed.
    var isCountingDown: Bool
  }

  /// The latest sample. Read by both UI surfaces; never re-derived in a view.
  private(set) var topology = MirrorTopology([])
  private(set) var preview: Preview?
  /// The last refusal, with its reason. `.onlyOneDisplay` never lands here —
  /// the key path handles it by falling through to a brightness step.
  private(set) var lastRefusal: MirrorRefusal?
  private(set) var lastFailure: DisplayConfigError?
  /// What is STILL mirrored after a break that succeeded only partly.
  ///
  /// Its own property rather than a flavour of `lastFailure`, because nothing
  /// failed: the transaction committed exactly what was staged, and a locked
  /// slave was never staged. Reporting this as a failure would be as wrong as
  /// reporting it as a success — the honest statement is "some of it, and here
  /// is what is left".
  private(set) var lastPartialBreak: [CGDirectDisplayID] = []
  /// The four-way gate refused this request, and names who is holding it
  /// (AR12). Its own property rather than another `MirrorRefusal` case: that enum
  /// is `MirrorTopologyPolicy`'s answer about the TOPOLOGY, and this is not a
  /// fact about the topology at all.
  private(set) var blockedBy: ReconfigurationClaimant?
  private(set) var isApplying = false

  @ObservationIgnored weak var confirmation: (any MirrorConfirmationPresenting)?
  /// Friendly-name resolution belongs to the surfaces, not here. The default is
  /// deliberately empty rather than a hardware name: an unwired coordinator
  /// should look unfinished in testing, not plausibly right. `MirroringCopy`
  /// treats an empty name as "cannot name this display" and falls back to a
  /// count, so the default degrades to a true sentence rather than a blank one.
  @ObservationIgnored var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  /// Tear the software-dimming leg down and let the engine rebuild it.
  ///
  /// **This is the orphaned-shade fix, and it is not bookkeeping.** A shade is
  /// created, framed, alpha'd and removed under the display's DRAWABLE id. A
  /// display that is software-dimming under its OWN id and then becomes a mirror
  /// SLAVE has its controller resolve to the master from that instant on, so the
  /// engine writes the master's key and nothing ever names the old one again.
  /// `ShadeOverlay.repinFrames()` explicitly skips it — the slave has no
  /// `NSScreen`, and the deliberate choice there is to leave the window alone
  /// rather than guess a frame — which leaves a full-screen black window at
  /// `CGShieldingWindowLevel()` on a display with no desktop, with no route out
  /// of it inside the app short of quitting.
  ///
  /// The ENGAGE direction is the one that strands. A break cannot: the ex-master
  /// resolves to itself (it was never a slave) and re-names its own key on the
  /// next re-apply, and the ex-slave gets a fresh shade under its own id.
  /// Removing wholesale covers both anyway, which is why the call is
  /// unconditional and the direction is documented rather than branched on.
  ///
  /// **D28: the rebuild must be `reapplyAfterPrefChange()`.** Not
  /// `handleReconfigure(recapture:)`, which re-runs only the software leg and
  /// returns before applying anything in pure-DDC mode, and not
  /// `setBrightness(sameValue)`, which is memo-suppressed. Injected as a closure
  /// because it needs an AppKit island and the display list, neither of which
  /// belongs to this type.
  @ObservationIgnored var rebuildSoftwareDimming: () -> Void = {}

  @ObservationIgnored private let configurator: any DisplayConfiguring
  @ObservationIgnored private let store: MirrorTopologyStore
  @ObservationIgnored private let modes: DisplayModeCoordinator
  /// AR12. Held from just before a mirror apply until nothing is outstanding.
  ///
  /// It does NOT replace the `modes.endOutstandingPreview()` await below, and the
  /// two are not the same guarantee: the gate refuses an OVERLAPPING preview,
  /// while that await is what orders this chain's `CGBeginDisplayConfiguration`
  /// after any mode transaction the queue is still finishing. With the gate in
  /// front of it the await is now reached only when the mode side holds nothing,
  /// so it is a backstop rather than the mechanism — stated here because the
  /// narrow guarantee is the one the code delivers.
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  @ObservationIgnored private let session: MirrorPreviewSession
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  /// Counted rather than boolean, for `DisplayModeCoordinator.select`'s reason:
  /// two queued operations must not have the first one's completion clear the
  /// flag while the second is still running.
  @ObservationIgnored private var inFlight = 0
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "topology"
  )

  #if DEBUG
    @ObservationIgnored private var debugObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var debugPreviewObserver: (any NSObjectProtocol)?
  #endif

  init(
    store: MirrorTopologyStore,
    modes: DisplayModeCoordinator,
    gate: DisplayReconfigurationGate,
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator()
  ) {
    self.store = store
    self.modes = modes
    self.gate = gate
    self.configurator = configurator
    session = MirrorPreviewSession(configurator: configurator)
    refreshTopology()
    // The SAME trigger `MirrorTopologySampler` and `DisplayModeCoordinator`
    // already observe, and sampled the same way: through
    // `configurator.displays()` (ONLINE) rather than `NSScreen.screens`, so it
    // is mirror-safe by construction. AppKit posts this for any reconfiguration,
    // mirror changes included.
    //
    // Rejected alternative, recorded so nobody re-adds it:
    // `CGDisplayRegisterReconfigurationCallback` carries
    // `kCGDisplayMirrorFlag`/`kCGDisplayUnMirrorFlag` and would be a
    // better-TARGETED trigger — but this notification already fires, the refresh
    // is one cheap `displays()` call, and the flag-discarding line in
    // `DisplayManager` carries a fork-parity ruling this feature has no cause to
    // reopen.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      // `nil`, not `.main`: the block then runs synchronously at post time
      // rather than being enqueued behind whatever the main run loop is doing.
      // AppKit posts this on the main thread, so this is the same thread either
      // way — it is the queueing that is being avoided, not the thread.
      queue: nil
    ) { [weak self] _ in
      // Sampled HERE, synchronously, and carried across the hop — never re-read
      // on the other side. `configurator` is `Sendable` and captured directly,
      // so nothing touches the main-actor object off the main actor. The hop's
      // delay is unbounded: this codebase documents main-actor work being
      // starved for the whole of a menu tracking session.
      let sample = MirrorTopology(configurator.displays())
      Task { @MainActor in self?.adoptTopology(sample) }
    }

    #if DEBUG
      // Screenshot validation only (DT6): posts a report card so the window's
      // layout, contrast and truncation can be READ in an image — the
      // confirmation window cannot be produced on a single display, and the
      // virtual-display rig refuses to run while Candela runs. Compiled out of
      // Release BY CONSTRUCTION rather than by remembering to delete it, and the
      // standing rule of grepping every Mach-O in the Release bundle for debug
      // markers still applies as a review step.
      debugObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.rydersel.Candela.debug.showMirrorReport"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.lastRefusal = .setCannotBeBroken([1])
          self.syncConfirmation()
        }
      }

      // The other half of the same problem: the PREVIEW card is the one with two
      // answers, so it is the one where "which is the primary?" can go wrong —
      // and it is unreachable from a script. Driving Settings' own button needs
      // an Accessibility grant this machine does not have, and the hotkey needs
      // the same grant. So this posts the real thing: the genuine `engage` path
      // on the main display, with the genuine countdown behind it. It cannot
      // strand a topology the feature would not itself revert.
      debugPreviewObserver = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.rydersel.Candela.debug.showMirrorPreview"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.engage(master: CGMainDisplayID())
        }
      }
    #endif
  }

  /// The notification tokens are not unregistered here: they are not
  /// `Sendable`, so a nonisolated `deinit` cannot touch them. Harmless — this
  /// object lives as long as the app and the blocks hold `self` weakly, so a
  /// surviving registration is inert rather than dangling.
  deinit {
    countdown?.cancel()
    pending?.cancel()
  }

  // MARK: - Topology

  /// Re-samples and republishes. Called at launch, on every screen-parameters
  /// notification, and after anything this app applies.
  func refreshTopology() {
    adoptTopology(MirrorTopology(configurator.displays()))
  }

  private func adoptTopology(_ sample: MirrorTopology) {
    let changed = sample != topology
    topology = sample
    // The store's SECOND writer (`MirrorTopologySampler` is the first). Both
    // write a whole sample from the same source, so this is last-write-wins over
    // two values of the same shape, never a field at a time. Worth doing because
    // a keypress samples LIVE here — `toggleUnlessSingleDisplay` cannot wait for
    // a notification to have landed — and every drawable-ID resolution in the
    // app reads the store.
    store.update(sample)
    // Ordered AFTER the store write, and only when the topology actually moved.
    // The rebuild resolves drawable ids through the store, so a rebuild ahead of
    // the write would re-create the shade under the key it is trying to retire.
    if changed { rebuildSoftwareDimming() }
    // A member of the previewed set has departed, so the preview is REVERTED —
    // never dropped. Dropping is what `DisplayModeCoordinator` does for a mode,
    // and it is wrong for a set: with two slaves, losing one would leave the
    // OTHER still mirroring at `.preview` scope with the countdown cancelled and
    // the window dismissed, i.e. an unapproved topology with no UI and no timer,
    // recoverable only by quitting. See
    // `MirrorPreviewSession.revertOnDeparture(displayID:)`.
    //
    // Asked of the SESSION rather than of `preview`, for
    // `DisplayModeCoordinator.dropPreviewOnDepartedDisplay`'s reason: the
    // derived copy is nil for several awaits after `begin()` succeeds.
    //
    // ONE call, not one per departed id: the whole preview resolves at once, and
    // `min()` only makes which id gets named deterministic. And no
    // `refreshTopology()` afterwards, deliberately — this block runs INSIDE
    // `adoptTopology`, so re-entering it here would spin whenever the revert
    // keeps failing. A successful revert reconfigures displays and the
    // screen-parameters notification brings the next sample in on its own.
    enqueue {
      guard let outstanding = await self.session.previewedTopology else { return }
      let live = Set(sample.displays.map(\.id))
      let members = Set([outstanding.confirmationDisplayID] + outstanding.applied.map(\.display))
      guard let departed = members.subtracting(live).min() else { return }
      switch await self.session.revertOnDeparture(displayID: departed) {
      case let .failed(error):
        // The preview is still outstanding and its countdown still armed, so the
        // expiry retries. Silence here would leave the failure invisible.
        self.log.error("Reverting after display \(departed, privacy: .public) departed failed")
        await self.adopt(.set(error))
      case .reverted, .committed, .stale, nil:
        await self.adopt(.clear)
      }
    }
  }

  // MARK: - Commands

  /// The hotkey's entry point. Returns **false** when there is nothing to
  /// mirror, and only then — the caller falls through to a plain
  /// brightness-down step, which is fork parity and the one behaviour of
  /// `Mirroring.engageMirror` worth keeping.
  ///
  /// The sample is taken LIVE here rather than from the store: a keypress must
  /// not depend on a notification having already landed.
  ///
  /// Synchronous for exactly this question and queued for everything else. A
  /// keypress cannot wait for a task chain to learn whether it was a keypress
  /// about brightness.
  @discardableResult
  func toggleUnlessSingleDisplay() -> Bool {
    let sample = MirrorTopology(configurator.displays())
    adoptTopology(sample)
    let decision = MirrorTopologyPolicy.toggle(sample)
    if case .refused(.onlyOneDisplay) = decision { return false }
    perform(decision, capturedFrom: sample)
    return true
  }

  func engage(master: CGDirectDisplayID) {
    let sample = MirrorTopology(configurator.displays())
    adoptTopology(sample)
    perform(MirrorTopologyPolicy.engage(sample, master: master), capturedFrom: sample)
  }

  func disengage(containing member: CGDirectDisplayID) {
    let sample = MirrorTopology(configurator.displays())
    adoptTopology(sample)
    perform(MirrorTopologyPolicy.disengage(sample, containing: member), capturedFrom: sample)
  }

  @discardableResult
  func confirm(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> ModePreviewOutcome {
    await enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  /// THE only place the report is cleared, for the same reason `adopt` is the
  /// only writer of `preview`: the window renders this, so clearing it and
  /// syncing the window are one operation, not two a caller is trusted to pair.
  func dismissReport() {
    lastRefusal = nil
    lastFailure = nil
    lastPartialBreak = []
    blockedBy = nil
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

  private func perform(_ decision: MirrorToggleDecision, capturedFrom captured: MirrorTopology) {
    // Raised synchronously, BEFORE any await: a control that queues main-actor
    // work and only then disables itself is a control two clicks get through.
    inFlight += 1
    isApplying = true
    enqueue {
      defer {
        self.inFlight -= 1
        if self.inFlight == 0 { self.isApplying = false }
      }
      self.dismissReport()
      // AR12, asked before either apply arm and not for a refusal, which
      // reconfigures nothing and so has nothing to exclude. Granted when we are
      // already the holder: a break that supersedes an outstanding engage is a
      // supported operation, and `applyDisengage` is built for it.
      switch decision {
      case .engage, .disengage:
        if let holder = await self.gate.claim(.mirroring).refusedBy {
          self.blockedBy = holder
          self.log.info("Refused a mirror change: \(holder.rawValue, privacy: .public) is reconfiguring displays")
          // The hotkey has no other surface at all, so silence here reads as the
          // key being dead.
          self.syncConfirmation()
          return
        }
      case .refused:
        break
      }
      switch decision {
      case let .engage(master, changes):
        // The ordering rule: a mirror engage first ends any outstanding MODE
        // preview, and REFUSES if that revert failed — reporting success would
        // leave a display nobody named stranded on an unapproved mode. Awaited
        // from inside THIS chain, so the mode revert has completed before this
        // path opens a `CGBeginDisplayConfiguration` transaction.
        //
        // BOTH MIRROR DIRECTIONS ARE ORDERED THIS WAY — the `.disengage` arm
        // below makes the same call on the same terms — but the guarantee is
        // still not general. Two ways the two coordinators reach CoreGraphics
        // concurrently: `DisplayModeCoordinator.select` never asks the mirror
        // side to stand down, so the ordering holds in this direction only; and
        // `startCountdown`'s expiry runs `tick()` → `applyMirroring` on a
        // DETACHED task, deliberately ungated on the main actor, so it can
        // overlap a mode apply by construction. Making it general needs one
        // serialisation point that owns every `CGBeginDisplayConfiguration` in
        // the app — two `@MainActor @Observable` coordinators cannot share a
        // task chain without being merged — and that is a change neither this
        // task nor DT19 makes. What is claimed here is what is enforced here.
        guard await self.modes.endOutstandingPreview() else {
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.log.error("Refused a mirror engage: an outstanding mode preview could not be reverted")
          // Through `adopt`, not a bare `syncConfirmation()`: this arm claimed
          // the gate a few lines up and applies nothing, so a plain return here
          // would strand the claim and wedge every display feature in the app
          // for the rest of the session. `adopt` is the releaser, and `.keep`
          // rather than `.clear` because any mirror preview already standing
          // keeps its own failure — this refusal is not about it.
          await self.adopt(.keep)
          return
        }
        self.log.info("Engaging mirror on \(master, privacy: .public), \(changes.count, privacy: .public) change(s)")
        switch await self.session.begin(.engage(master: master, changes: changes), from: captured) {
        case .success:
          // Cancelled BEFORE the await, not after `startCountdown()` gets to it:
          // the previous preview's driver is still looping, and a tick that
          // lands during `adopt` would knock the fresh preview from 30 seconds
          // to 14. It narrows the window rather than closing it — a tick already
          // past its sleep and inside `session.tick()` still counts against the
          // new preview, and closing that needs the session to know WHICH
          // preview a tick is for.
          self.stopCountdown()
          await self.adopt(.clear)
          self.startCountdown()
        case let .failure(error):
          self.lastFailure = error
          await self.adopt(.clear)
        }
      case let .disengage(changes, residualMembers):
        // NO countdown, deliberately: breaking a set returns every display to
        // its own desktop and cannot leave a screen unreadable, and a countdown
        // here would re-mirror a rig the user just un-mirrored while they were
        // still looking for the window on a screen that had only just come back.
        //
        // ORDERED against the mode side on exactly the engage arm's terms, and
        // REFUSING on exactly its terms: this is about to open a
        // `CGBeginDisplayConfiguration` transaction too, and an interleave that
        // loses the break would have this arm report a success it did not
        // achieve — the one defect class this whole path exists to close. The
        // refusal is visible (`lastFailure`, hence the report card) and the mode
        // preview keeps its own window and its own retry, so refusing parks
        // nobody: pressing the button again is the recovery.
        guard await self.modes.endOutstandingPreview() else {
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.log.error("Refused a mirror break: an outstanding mode preview could not be reverted")
          // Through `adopt`, not a bare `syncConfirmation()`: this arm claimed
          // the gate a few lines up and applies nothing, so a plain return here
          // would strand the claim and wedge every display feature in the app
          // for the rest of the session. `adopt` is the releaser, and `.keep`
          // rather than `.clear` because any mirror preview already standing
          // keeps its own failure — this refusal is not about it.
          await self.adopt(.keep)
          return
        }
        if await self.session.hasOutstandingPreview {
          // Read for the LOG only. `applyDisengage` supersedes whatever is
          // outstanding at the instant IT runs; this answer is one actor hop
          // old, and nothing below depends on it.
          self.log.info("Stopping mirroring supersedes an outstanding mirror preview")
        }
        // Through the SESSION rather than straight at the configurator, and the
        // reason is not tidiness. An outstanding mirror preview's fallback is
        // the topology captured BEFORE it applied, which can contain the very
        // set being broken here: leaving it outstanding lets the expiry re-apply
        // that capture and bring the set back half a minute after an explicit
        // stop, with no further interaction and no explanation. Reverting it
        // instead would do the same thing immediately. `applyDisengage`
        // supersedes it — resolves it without reverting — inside the actor that
        // owns the countdown, so no expiry can land between the two steps.
        //
        // The change list is still the one decided from the entry sample, and
        // that stays correct precisely BECAUSE superseding applies nothing: the
        // topology the decision described is the topology this stages against.
        switch await self.session.applyDisengage(changes) {
        case .success:
          // Reported, never inferred from the change list — which does not
          // mention the survivors at all. A locked slave keeps mirroring and
          // keeps its master a master, so "mirroring off" over a partly-broken
          // set is the same false success `engageMirror` used to report, one
          // layer out. Set only on a SUCCESSFUL apply: a throw means nothing
          // changed, and `lastFailure` is the whole story then.
          self.lastPartialBreak = residualMembers
          if !residualMembers.isEmpty {
            self.log.info("Mirror break was partial; still mirrored: \(residualMembers, privacy: .public)")
          }
        case let .failure(error):
          self.lastFailure = error
        }
        // The card must not outlive the topology it is asking about. Rebuilt
        // FROM the session like every other write to `preview`, so this also
        // cancels the countdown DRIVER — a task still ticking against a resolved
        // preview keeps a live "Keep mirroring?" card on screen over a machine
        // that is not mirroring, and one click on Keep re-mirrors the rig the
        // user just un-mirrored. Ordered after the writes above so the report it
        // syncs is the one this apply just produced.
        await self.adopt(.clear)
      case let .refused(reason):
        // Never a silent false. `engageMirror` returned a bare Bool whose two
        // falses meant different things, and the enum it was replaced by has
        // EIGHT cases — each with its own sentence in `MirroringCopy`, and no
        // `default:` arm anywhere that consumes it.
        self.lastRefusal = reason
        self.log.info("Mirror toggle refused: \(String(describing: reason), privacy: .public)")
      }
      self.refreshTopology()
      self.syncConfirmation()
    }
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
      // Nothing resolved: the outstanding preview is not the one this answer
      // was about. Keep whatever failure is on screen — it belongs to the
      // preview that is still there.
      await adopt(.keep)
    }
    refreshTopology()
    return outcome
  }

  /// Rebuilds the UI's picture FROM the session. THE only writer of `preview`,
  /// so no path can leave the two disagreeing — including a countdown tick that
  /// resumes late, which reconciles here instead of being discarded.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewedTopology else {
      preview = nil
      stopCountdown()
      // THE release (AR12). Here rather than at each call site because this
      // funnel already runs after every path that can end a preview — a failed
      // begin, a break that superseded one, an expiry, and a member of the set
      // departing with nobody watching. Unconditional: the gate refuses a
      // release from a claimant that is not holding it.
      await gate.release(.mirroring)
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
      isCountingDown: counting
    )
    if !counting { stopCountdown() }
    syncConfirmation()
  }

  /// Points the window at whatever there is to say, or at nothing. Called on
  /// every countdown tick, so the presenter must treat a repeat present of
  /// unchanged content as a no-op.
  ///
  /// Every write to `preview`, `lastRefusal`, `lastFailure`, `lastPartialBreak`
  /// or `blockedBy` has to be followed by this call. An un-synced write does
  /// not merely leave the window stale — it leaves it rendering a state that no
  /// longer exists, i.e. an empty floating panel.
  private func syncConfirmation() {
    if let preview {
      confirmation?.presentMirrorConfirmation(.preview(preview.value.confirmationDisplayID))
      return
    }
    // A refusal, a failed apply or a partial break changed nothing (or not
    // everything) on screen, so silence here is indistinguishable from the
    // feature not working — and the hotkey has no other surface at all.
    if lastFailure != nil || lastRefusal != nil || !lastPartialBreak.isEmpty || blockedBy != nil {
      confirmation?.presentMirrorConfirmation(.report)
      return
    }
    confirmation?.dismissMirrorConfirmation()
  }

  /// The countdown driver.
  ///
  /// Detached, and its main-actor hop is fire-and-forget. Both halves matter:
  /// the tick and the revert it triggers run on the session's executor, and the
  /// loop's next sleep is never gated on the main actor having run the previous
  /// UI update. A main thread wedged by a synchronous reconfiguration callback
  /// must not be able to stop the expiry — the expiry is what rescues a rig
  /// nobody can see.
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

/// A surface that reports on a mirror change independently of whichever view
/// started it. Declared beside the coordinator and AppKit-free, so the contract
/// belongs to the thing that needs it — the window that implements it is an
/// app-target island like every other.
@MainActor
protocol MirrorConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every tick.
  func presentMirrorConfirmation(_ content: MirrorConfirmationContent)
  func dismissMirrorConfirmation()
}

/// What the standalone surface is showing. Two cases, not one, because the two
/// outcomes are genuinely different: a preview is a question with a countdown
/// behind it, and a report is a statement with nothing outstanding.
enum MirrorConfirmationContent: Hashable {
  /// A preview waiting to be answered, placed on the MASTER — the display the
  /// request named has no `NSScreen` from the instant the preview applies.
  case preview(CGDirectDisplayID)
  /// A refusal, a failed apply, or a break that left something mirrored.
  /// Nothing is outstanding; one button, which dismisses.
  case report
}
