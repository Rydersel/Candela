import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// App-side owner of the mirror topology, the toggle, and the preview
/// countdown. `DisplayModeCoordinator`'s shape, for its reasons:
///
/// 1. **Every session-touching operation is serialised** through `queue`.
///    Without it two fast clicks both suspend inside `begin()`, the actor
///    serialises them, and their main-actor continuations resume in an order
///    unrelated to the actor's.
/// 2. **The UI's state is rebuilt FROM the session** (`adopt`), never from what
///    a caller remembers passing in. The two disagree exactly when something
///    went wrong, and the session decides what is applied.
///
/// A view cannot own this: the countdown has to keep running after the panel
/// that started it has closed, which is the whole safety argument for previewing.
///
/// Replaces the fork's `Mirroring.engageMirror`, whose traced defects (a
/// permanent scope from a hotkey, discarded staged returns, no
/// `CGDisplayIsAlwaysInMirrorSet` check, a leaked `CGDisplayConfigRef`) are all
/// closed by going through `MirrorTopologyPolicy` and
/// `DisplayConfiguring.applyMirroring`. Do not open a transaction here.
@MainActor @Observable
final class MirroringCoordinator {
  /// A preview that has been applied and not yet resolved. Every field is a
  /// copy of the session's own answer.
  struct Preview: Equatable {
    let value: PreviewedMirrorTopology
    var secondsRemaining: Int
    /// Set when `confirm()`, `revert()` or the expiry threw. Nothing
    /// auto-retries, so silence leaves the user on a topology they never
    /// approved.
    var failure: DisplayConfigError?
    /// Reported by the session, not inferred: a failed expiry disarms the
    /// countdown while a failed commit deliberately leaves it armed.
    var isCountingDown: Bool
  }

  /// The latest sample AS ADOPTED. Never read outside `topology`, which is the
  /// value this object publishes.
  private var sample = MirrorTopology([])

  /// The latest sample, stamped with the synthesis pairing. Read by every
  /// surface and every command here; never re-derived in a view.
  ///
  /// Computed, and that closes a race with teeth. The store's masters are noted
  /// when `SynthesisCoordinator` refreshes its snapshot, while this object
  /// re-adopts only when a topology sample arrives, so an engage whose
  /// screen-parameters notification lands BEFORE the pairing note would leave a
  /// stored value un-stamped for the life of the engagement and every surface
  /// would present the synthesis set as mirroring the user did. Reading the
  /// snapshot here also makes it an observation dependency, so a late pairing
  /// redraws instead of being missed.
  ///
  /// The UNION of the two: same table read at two moments, and either can know
  /// first. Ambiguity resolves towards "this is synthesis", the failure the synthesis
  /// carve-outs exist to prevent. A stale positive lasts until the next adopt,
  /// which any teardown produces.
  var topology: MirrorTopology {
    let masters = sample.synthesisMasters.union(synthesis?.masterIDs ?? [])
    guard masters != sample.synthesisMasters else { return sample }
    return MirrorTopology(sample.displays, synthesisMasters: masters)
  }

  private(set) var preview: Preview?
  /// The last refusal, with its reason. `.onlyOneDisplay` never lands here: the
  /// key path falls through to a brightness step instead.
  private(set) var lastRefusal: MirrorRefusal?
  private(set) var lastFailure: DisplayConfigError?
  /// What is STILL mirrored after a break that succeeded only partly.
  ///
  /// Its own property rather than a flavour of `lastFailure`, because nothing
  /// failed: the transaction committed exactly what was staged, and a locked
  /// slave was never staged. The honest statement is "some of it, and here is
  /// what is left".
  private(set) var lastPartialBreak: [CGDirectDisplayID] = []
  /// The gate refused this request, and names who holds it. Not a
  /// `MirrorRefusal` case: that enum answers about the TOPOLOGY, and this is no
  /// fact about the topology.
  private(set) var blockedBy: ReconfigurationClaimant?
  private(set) var isApplying = false

  @ObservationIgnored weak var confirmation: (any MirrorConfirmationPresenting)?
  /// Friendly-name resolution belongs to the surfaces. Empty by default, not a
  /// hardware name, so an unwired coordinator looks unfinished in testing rather
  /// than plausibly right; `MirroringCopy` reads empty as "cannot name this
  /// display" and falls back to a count.
  @ObservationIgnored var displayName: (CGDirectDisplayID) -> String = { _ in "" }

  /// Tear the software-dimming leg down and let the engine rebuild it.
  ///
  /// **This is the orphaned-shade fix, not bookkeeping.** A shade is keyed by
  /// the display's DRAWABLE id. A display dimming under its OWN id that then
  /// becomes a mirror SLAVE has its controller resolve to the master from that
  /// instant, so nothing ever names the old key again, and
  /// `ShadeOverlay.repinFrames()` skips a slave (it has no `NSScreen`). The
  /// leftover is a full-screen black window at `CGShieldingWindowLevel()` on a
  /// display with no desktop, with no way out short of quitting.
  ///
  /// Only ENGAGE strands. A break cannot: the ex-master re-names its own key and
  /// the ex-slave gets a fresh shade. The call is unconditional because removing
  /// wholesale covers both.
  ///
  /// **The rebuild must be `reapplyAfterPrefChange()`.** Not
  /// `handleReconfigure(recapture:)`, which re-runs only the software leg and
  /// returns before applying anything in pure-DDC mode, and not
  /// `setBrightness(sameValue)`, which is memo-suppressed. A closure because it
  /// needs an AppKit island and the display list.
  @ObservationIgnored var rebuildSoftwareDimming: () -> Void = {}

  @ObservationIgnored private let configurator: any DisplayConfiguring
  @ObservationIgnored private let store: MirrorTopologyStore
  @ObservationIgnored private let modes: DisplayModeCoordinator
  /// The reconfiguration gate. Held from just before a mirror apply until nothing is outstanding.
  ///
  /// It does NOT replace the `modes.endOutstandingPreview()` await below: the
  /// gate refuses an OVERLAPPING preview, while that await orders this chain's
  /// `CGBeginDisplayConfiguration` after any mode transaction the queue is still
  /// finishing. With the gate in front of it the await is a backstop, not the
  /// mechanism.
  @ObservationIgnored private let gate: DisplayReconfigurationGate
  @ObservationIgnored private let session: MirrorPreviewSession
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
  @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
  /// Counted, not boolean: the first of two queued operations must not clear the
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
    // The SAME trigger the other samplers observe, and sampled the same way:
    // `configurator.displays()` (ONLINE) rather than `NSScreen.screens`, so it is
    // mirror-safe by construction.
    //
    // Rejected alternative, so nobody re-adds it:
    // `CGDisplayRegisterReconfigurationCallback` carries the mirror flags and
    // would be better targeted, but this notification already fires, the refresh
    // is one cheap `displays()` call, and the flag-discarding line in
    // `DisplayManager` carries a fork-parity ruling not worth reopening.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      // `nil`, not `.main`: the block runs synchronously at post time instead of
      // queueing behind whatever the main run loop is doing. AppKit posts on the
      // main thread either way, so the queueing is what is avoided, not the hop.
      queue: nil
    ) { [weak self] _ in
      // Sampled HERE, synchronously, and carried across the hop, never re-read
      // on the other side. `configurator` is `Sendable` and captured directly, so
      // nothing touches the main-actor object off the main actor. The hop's delay
      // is unbounded: main-actor work can starve for a whole menu tracking
      // session.
      let sample = MirrorTopology(configurator.displays())
      Task { @MainActor in self?.adoptTopology(sample) }
    }

    #if DEBUG
      // Screenshot validation only: posts a report card so layout,
      // contrast and truncation can be READ in an image. The confirmation window
      // cannot be produced on a single display, and the virtual-display rig
      // refuses to run while Candela runs.
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

      // The other half: the PREVIEW card has two answers, so it is where "which
      // is the primary?" can go wrong, and it is unreachable from a script (both
      // the Settings button and the hotkey need an Accessibility grant this
      // machine lacks). This posts the real `engage` path with the real
      // countdown, so it cannot strand a topology the feature would not revert.
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

  /// The notification tokens are not unregistered: they are not `Sendable`, so a
  /// nonisolated `deinit` cannot touch them. Harmless, since this object lives as
  /// long as the app and the blocks hold `self` weakly.
  deinit {
    countdown.stop()
    queue.cancel()
  }

  // MARK: - Topology

  /// Re-samples and republishes. Called at launch, on every screen-parameters
  /// notification, and after anything this app applies.
  func refreshTopology() {
    adoptTopology(MirrorTopology(configurator.displays()))
  }

  /// Re-samples, republishes, and hands back what was PUBLISHED, not what was
  /// sampled. They differ by the synthesis pairing: a raw sample cannot
  /// tell a set the app engaged for a synthesized size from one the user asked
  /// for. Every command below decides from this value.
  @discardableResult
  private func resampleAndPublish() -> MirrorTopology {
    refreshTopology()
    return topology
  }

  private func adoptTopology(_ arrived: MirrorTopology) {
    // The store's SECOND writer (`MirrorTopologySampler` is the first). Both
    // write a whole sample from the same source, so this is last-write-wins over
    // two values of one shape, never a field at a time. Worth doing because
    // `toggleUnlessSingleDisplay` samples LIVE here rather than waiting for a
    // notification, and every drawable-ID resolution reads the store.
    //
    // Written FIRST and read BACK, so what this publishes carries the synthesis
    // pairing. On an un-stamped sample every synthesis carve-out predicate
    // answers "ordinary mirror set".
    store.update(arrived)
    let stamped = store.topology()
    let changed = stamped != sample
    sample = stamped
    // Ordered AFTER the store write, and only when the topology actually moved.
    // The rebuild resolves drawable ids through the store, so a rebuild ahead of
    // the write would re-create the shade under the key it is trying to retire.
    if changed { rebuildSoftwareDimming() }
    // A member of the previewed set departed, so the preview is REVERTED, never
    // dropped. Dropping suits a mode, not a set: with two slaves, losing one
    // leaves the OTHER mirroring at `.preview` scope with the countdown cancelled
    // and the window dismissed, an unapproved topology with no UI and no timer.
    //
    // Asked of the SESSION, not of `preview`: the derived copy is nil for several
    // awaits after `begin()` succeeds.
    //
    // ONE call, not one per departed id; `min()` only makes the named id
    // deterministic. No `refreshTopology()` afterwards: this runs INSIDE
    // `adoptTopology`, so re-entering would spin while the revert keeps failing.
    // A successful revert posts its own screen-parameters notification.
    queue.enqueue {
      guard let outstanding = await self.session.previewedTopology else { return }
      let live = Set(arrived.displays.map(\.id))
      let members = Set([outstanding.confirmationDisplayID] + outstanding.applied.map(\.display))
      guard let departed = members.subtracting(live).min() else { return }
      switch await self.session.revertOnDeparture(displayID: departed) {
      case let .failed(error):
        // Still outstanding with the countdown armed, so the expiry retries.
        // Silence would leave the failure invisible.
        self.log.error("Reverting after display \(departed, privacy: .public) departed failed")
        await self.adopt(.set(error))
      case .reverted, .committed, .stale, nil:
        await self.adopt(.clear)
      }
    }
  }

  // MARK: - Commands

  /// The hotkey's entry point. Returns **false** only when there is nothing to
  /// mirror, and the caller then falls through to a brightness-down step (fork
  /// parity). Synchronous for that one question and queued for everything else:
  /// a keypress cannot wait on a task chain to learn what it was about.
  ///
  /// The sample is taken LIVE rather than from the store, since a keypress must
  /// not depend on a notification having landed.
  ///
  /// **A synthesized size comes down FIRST, through the engine.**
  /// `MirrorTopologyPolicy.toggle` would take a synthesis set apart with a
  /// null-master change, leaving the virtual display standing with nothing on
  /// it, a synthesis slot held, and the pairing table describing a set that no
  /// longer exists.
  ///
  /// What is LEFT follows `panicDecisionAfterUnwind`: the press can break a user
  /// set but never BUILD one. It still returns true there, because there IS work
  /// to do and the key must not fall through to a brightness step.
  @discardableResult
  func toggleUnlessSingleDisplay() -> Bool {
    let sample = resampleAndPublish()
    guard sample.synthesisMasters.isEmpty else {
      unwindingSynthesis(
        then: { fresh in
          guard fresh.synthesisMasters.isEmpty else {
            // `panicDecisionAfterUnwind` answers nothing here, and the reason
            // has to reach a surface: the hotkey has none of its own, so silence
            // reads as a dead key. Set directly, not through a `perform`, whose
            // first act is to clear the report this is the report of.
            self.log.error("A synthesis master is still standing after the unwind; the press staged nothing")
            self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
            self.syncConfirmation()
            return
          }
          guard let decision = Self.panicDecisionAfterUnwind(fresh) else { return }
          self.perform(decision, capturedFrom: fresh)
        },
        ifStuck: { fresh in
          // The engine could not take a synthesis set down, and the user's OWN
          // set must not be held hostage to that.
          //
          // `userVisibleMirrorSets` keeps a raw null-master change off the set
          // still standing. One transaction per set: the policy's machine-wide
          // break is `toggle`, and `toggle` would stage the synthesis set too.
          for members in fresh.userVisibleMirrorSets {
            guard let member = members.first else { continue }
            self.perform(
              MirrorTopologyPolicy.disengage(fresh, containing: member), capturedFrom: fresh
            )
          }
        }
      )
      return true
    }
    let decision = MirrorTopologyPolicy.toggle(sample)
    if case .refused(.onlyOneDisplay) = decision { return false }
    perform(decision, capturedFrom: sample)
    return true
  }

  /// What a panic press does with what is left once every synthesis set has come
  /// down, or nil for "the press's work is done".
  ///
  /// Pure and separately nameable so its one rule can be pinned: the post-unwind
  /// press acts ONLY on a break. `MirrorTopologyPolicy.toggle` is
  /// break-else-build, so on the common rig (one panel, one synthesized size, no
  /// user mirroring) the unwind removes the only set and the same call answers
  /// `.engage`, mirroring the built-in onto the panel behind a countdown. Both
  /// build-branch refusals mean the same thing over a state the press produced.
  ///
  /// `.refused(.setCannotBeBroken)` DOES come back, and it is no second action: a
  /// refusal stages nothing, it only names the set macOS would not release.
  /// Swallowing it leaves mirroring that survived a panic press unexplained.
  ///
  /// **A sample that still shows a synthesis master answers nothing at all.**
  /// The caller verifies against the pairing table, which is empty for the whole
  /// of an engage and so can read "everything came down" over a machine that has
  /// a synthesis set on it. No raw mirror change is staged over a standing
  /// synthesis set, and a decision made here would be exactly that.
  static func panicDecisionAfterUnwind(_ topology: MirrorTopology) -> MirrorToggleDecision? {
    guard topology.synthesisMasters.isEmpty else { return nil }
    let decision = MirrorTopologyPolicy.toggle(topology)
    switch decision {
    case .disengage: return decision
    case .engage: return nil
    case .refused(.setCannotBeBroken): return decision
    case .refused: return nil
    }
  }

  /// **Also unwinds synthesis first**, for a sharper reason than the toggle:
  /// `MirrorTopologyPolicy.engage` stages a change for every other display in the
  /// sample, the synthesis VD included, so a user set built while a synthesized
  /// size is engaged would point the virtual display at the panel mirroring ONTO
  /// it. The same rule, generalised: no raw mirror change over a standing synthesis set.
  func engage(master: CGDirectDisplayID) {
    let sample = resampleAndPublish()
    guard sample.synthesisMasters.isEmpty else {
      unwindingSynthesis { fresh in
        self.perform(MirrorTopologyPolicy.engage(fresh, master: master), capturedFrom: fresh)
      }
      return
    }
    perform(MirrorTopologyPolicy.engage(sample, master: master), capturedFrom: sample)
  }

  /// The UI's one-set break. The policy reads `setMembers(containing:)`, that
  /// display's own set, so nothing here stages a change against a synthesis
  /// member unless `member` is one.
  ///
  /// When it IS one, the set comes down through the engine. No surface
  /// offers Stop Mirroring for a synthesis set, so this is the defensive half of
  /// the rule: it binds any Stop Mirroring affordance, not just today's.
  func disengage(containing member: CGDirectDisplayID) {
    let sample = resampleAndPublish()
    guard !sample.isSynthesisSet(containing: member) else {
      // Takes down every synthesis set, not just this one: the engine's only
      // pref-free teardown is the all-sets one, and the virtual-display pool is capped small. A
      // per-display route belongs in `SynthesisCoordinator`, since its verified
      // sequence is the whole point of going through the engine.
      unwindingSynthesis { _ in }
      return
    }
    perform(MirrorTopologyPolicy.disengage(sample, containing: member), capturedFrom: sample)
  }

  /// The mode-synthesis coordinator, reached through the mode coordinator this
  /// object is already constructed with.
  ///
  /// Deliberately NOT a second injection point in `AppModel`:
  /// `displayModes.synthesis` is assigned in the same initialiser that produces
  /// `modes`, so this is non-nil for the life of the app. A closure of our own
  /// could sit at its no-op default with no symptom until a panic press orphaned
  /// a virtual display. nil means unwired (a fixture) and degrades to the
  /// pre-synthesis behaviour.
  private var synthesis: SynthesisCoordinator? { modes.synthesis }

  /// Takes every synthesis set down through the engine, VERIFIES from the pairing
  /// table that they are gone, and only then runs `body` against a fresh sample.
  ///
  /// Verified against the pairing table, not the disengage's own return: the
  /// house rule about achieved state. `SynthesisCoordinator` re-reads the
  /// engine's table after every operation, so an empty table is the engine's
  /// answer about what still stands, not a report of what it attempted.
  ///
  /// **The table is only evidence once the teardown has run.** The snapshot is
  /// EMPTY for the whole of an engage, so an unwind refused because one is in
  /// flight leaves an empty table describing a machine about to have a synthesis
  /// set on it. A refusal is therefore stuck, not clean.
  ///
  /// `disengageAllForReset()` is named for the whole-app reset but is the only
  /// pref-free teardown exposed. A panic press must not opt a display out of
  /// synthesized sizes, so `setOptIn` and `reset`, which write prefs, are wrong
  /// here.
  ///
  /// `body` is not run while anything is still engaged: staging a raw mirror
  /// change over a set the engine could not take down is what this ruling
  /// prevents. `ifStuck` is the caller's business, since the hotkey breaks the
  /// user's own sets anyway while an engage refuses outright.
  private func unwindingSynthesis(
    then body: @escaping (MirrorTopology) -> Void,
    ifStuck stuck: ((MirrorTopology) -> Void)? = nil
  ) {
    guard let synthesis else { return }
    // Raised synchronously, before any await: a control that queues work and
    // only then disables itself is a control two clicks get through. The unwind
    // runs for seconds, so this is the widest such window.
    inFlight += 1
    isApplying = true
    queue.enqueue {
      defer {
        self.inFlight -= 1
        if self.inFlight == 0 { self.isApplying = false }
      }
      let cameDown = await synthesis.disengageAllForReset()
      let remaining = synthesis.pairings
      guard cameDown, remaining.isEmpty else {
        self.log.error("Synthesis did not come down; refused=\(cameDown ? 0 : 1, privacy: .public), \(remaining.count, privacy: .public) still engaged")
        if let held = remaining.first {
          // The engine's own word, on the surface that renders synthesis
          // refusals: no `MirrorRefusal` case describes a synthesized size that
          // would not come down, and inventing one would talk about mirroring to
          // someone who never asked for it. That surface is the settings hub, so
          // the report below is raised too: the hotkey has no surface at all.
          synthesis.note(.engine(.unwindIncomplete), for: held.physicalDisplayID)
        }
        // Whatever this caller does instead, FIRST: both land through the same
        // serial queue, and a `perform` runs `dismissReport()` as its first act,
        // so a failure raised ahead of it would be wiped.
        stuck?(self.resampleAndPublish())
        self.queue.enqueue {
          // Raised on EVERY stuck unwind, partial ones included, so the sentence
          // it renders ("nothing was altered") is not the whole truth when a
          // partial teardown or the hotkey's `ifStuck` did change something.
          // Reported anyway: the hotkey's only surface is this card, and silence
          // reads as a dead key. The honest sentence needs a `MirroringCopy`
          // string this file does not own.
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.syncConfirmation()
        }
        return
      }
      // Re-sampled, not carried: the unwind destroyed a display and changed a
      // mirror set, so the entry sample describes a machine that is gone.
      body(self.resampleAndPublish())
    }
  }

  @discardableResult
  func confirm(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: true) }
  }

  @discardableResult
  func revert(_ answered: Preview) async -> PreviewOutcome {
    await queue.enqueueReturning { await self.resolve(answered, keeping: false) }
  }

  /// THE only place the report is cleared: the window renders it, so clearing
  /// and syncing are one operation, not two a caller is trusted to pair.
  func dismissReport() {
    lastRefusal = nil
    lastFailure = nil
    lastPartialBreak = []
    blockedBy = nil
    syncConfirmation()
  }

  // MARK: - Operations (always inside the queue)

  private func perform(_ decision: MirrorToggleDecision, capturedFrom captured: MirrorTopology) {
    // Raised synchronously, BEFORE any await: a control that queues main-actor
    // work and only then disables itself is a control two clicks get through.
    inFlight += 1
    isApplying = true
    queue.enqueue {
      defer {
        self.inFlight -= 1
        if self.inFlight == 0 { self.isApplying = false }
      }
      self.dismissReport()
      // The reconfiguration gate, asked before either apply arm, not for a refusal, which
      // reconfigures nothing. Granted when we already hold it: a break that
      // supersedes an outstanding engage is supported by `applyDisengage`.
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
        // preview and REFUSES if that revert failed, since reporting success
        // would strand a display nobody named on an unapproved mode. Awaited
        // inside THIS chain, so the mode revert completes before this path opens
        // a `CGBeginDisplayConfiguration` transaction.
        //
        // Both mirror directions are ordered this way, but the guarantee is NOT
        // general. `DisplayModeCoordinator.select` never asks the mirror side to
        // stand down, so the ordering holds in this direction only, and
        // `startCountdown`'s expiry runs `tick()` then `applyMirroring` on a
        // DETACHED task, ungated on the main actor, so it can overlap a mode
        // apply by construction. Making it general needs one serialisation point
        // owning every `CGBeginDisplayConfiguration` in the app, which two
        // `@MainActor @Observable` coordinators cannot share without being
        // merged.
        guard await self.modes.endOutstandingPreview() else {
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.log.error("Refused a mirror engage: an outstanding mode preview could not be reverted")
          // Through `adopt`, not a bare `syncConfirmation()`: this arm claimed
          // the gate and applies nothing, so a plain return strands the claim and
          // wedges every display feature for the session. `adopt` releases, and
          // `.keep` because a mirror preview already standing keeps its own
          // failure; this refusal is not about it.
          await self.adopt(.keep)
          return
        }
        self.log.info("Engaging mirror on \(master, privacy: .public), \(changes.count, privacy: .public) change(s)")
        switch await self.session.begin(.engage(master: master, changes: changes), from: captured) {
        case .success:
          // Cancelled BEFORE the await, not after `startCountdown()`: the
          // previous preview's driver is still looping, and a tick landing during
          // `adopt` knocks seconds off the fresh preview. This narrows the window
          // rather than closing it. A tick already inside `session.tick()` still
          // counts against the new preview, and closing that needs the session to
          // know WHICH preview a tick is for.
          self.stopCountdown()
          await self.adopt(.clear)
          self.startCountdown()
        case let .failure(error):
          self.lastFailure = error
          await self.adopt(.clear)
        }
      case let .disengage(changes, residualMembers):
        // NO countdown, deliberately: breaking a set returns every display to
        // its own desktop and cannot leave a screen unreadable, while a countdown
        // would re-mirror the rig the user just un-mirrored.
        //
        // Ordered against the mode side on the engage arm's terms, and refusing
        // on its terms: this opens a `CGBeginDisplayConfiguration` transaction
        // too, and an interleave that loses the break would report a success it
        // did not achieve. The refusal is visible and the mode preview keeps its
        // own retry, so pressing the button again is the recovery.
        guard await self.modes.endOutstandingPreview() else {
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.log.error("Refused a mirror break: an outstanding mode preview could not be reverted")
          // Through `adopt`, not a bare `syncConfirmation()`: this arm claimed
          // the gate and applies nothing, so a plain return strands the claim and
          // wedges every display feature for the session. `adopt` releases, and
          // `.keep` because a mirror preview already standing keeps its own
          // failure; this refusal is not about it.
          await self.adopt(.keep)
          return
        }
        if await self.session.hasOutstandingPreview {
          // Read for the LOG only: `applyDisengage` supersedes whatever is
          // outstanding when IT runs, and this answer is one actor hop old.
          self.log.info("Stopping mirroring supersedes an outstanding mirror preview")
        }
        // Through the SESSION, not straight at the configurator. An outstanding
        // mirror preview's fallback is the topology captured BEFORE it applied,
        // which can contain the set being broken here, so leaving it outstanding
        // lets the expiry bring that set back half a minute after an explicit
        // stop. Reverting would do the same thing immediately. `applyDisengage`
        // supersedes it, resolving without reverting, inside the actor that owns
        // the countdown, so no expiry lands between the two steps.
        //
        // The change list is still the one decided from the entry sample, and it
        // stays correct BECAUSE superseding applies nothing.
        switch await self.session.applyDisengage(changes) {
        case .success:
          // Reported, never inferred from the change list, which never mentions
          // the survivors. A locked slave keeps mirroring and keeps its master a
          // master, so "mirroring off" over a partly-broken set is a false
          // success. Set only on a SUCCESSFUL apply: a throw means nothing
          // changed and `lastFailure` is the whole story.
          self.lastPartialBreak = residualMembers
          if !residualMembers.isEmpty {
            self.log.info("Mirror break was partial; still mirrored: \(residualMembers, privacy: .public)")
          }
        case let .failure(error):
          self.lastFailure = error
        }
        // The card must not outlive the topology it asks about. Rebuilt FROM the
        // session like every write to `preview`, so this also cancels the
        // countdown DRIVER: a task still ticking against a resolved preview keeps
        // a live "Keep mirroring?" card over a machine that is not mirroring, and
        // one click on Keep re-mirrors it. Ordered after the writes above so it
        // syncs the report this apply produced.
        await self.adopt(.clear)
      case let .refused(reason):
        // Never a silent false: `engageMirror` returned a bare Bool whose two
        // falses meant different things. Every case of the enum that replaced it
        // has its own sentence in `MirroringCopy`, and nothing consuming it
        // carries a `default:` arm.
        self.lastRefusal = reason
        self.log.info("Mirror toggle refused: \(String(describing: reason), privacy: .public)")
      }
      self.refreshTopology()
      self.syncConfirmation()
    }
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
      // Nothing resolved: the outstanding preview is not the one this answer was
      // about, so keep the failure on screen. It belongs to the one still there.
      await adopt(.keep)
    }
    refreshTopology()
    return outcome
  }

  /// Rebuilds the UI's picture FROM the session. THE only writer of `preview`,
  /// so no path can leave the two disagreeing, a late countdown tick included:
  /// it reconciles here instead of being discarded.
  private func adopt(_ failure: FailureUpdate) async {
    guard let outstanding = await session.previewedTopology else {
      preview = nil
      stopCountdown()
      // THE release (the reconfiguration gate), here rather than at each call site: this funnel
      // already runs after every path that can end a preview. Unconditional,
      // since the gate refuses a release from a claimant not holding it.
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
  /// Every write to the report properties has to be followed by this call. An
  /// un-synced write leaves the window rendering a state that no longer exists,
  /// which shows up as an empty floating panel.
  private func syncConfirmation() {
    if let preview {
      confirmation?.presentMirrorConfirmation(.preview(preview.value.confirmationDisplayID))
      return
    }
    // A refusal, a failed apply or a partial break changed nothing (or not
    // everything) on screen, so silence looks exactly like the feature not
    // working, and the hotkey has no other surface.
    if lastFailure != nil || lastRefusal != nil || !lastPartialBreak.isEmpty || blockedBy != nil {
      confirmation?.presentMirrorConfirmation(.report)
      return
    }
    confirmation?.dismissMirrorConfirmation()
  }

  /// The countdown driver.
  ///
  /// Detached, with a fire-and-forget main-actor hop. Both halves matter: the
  /// tick and its revert run on the session's executor, and the next sleep is
  /// never gated on the main actor having drawn the last update. A main thread
  /// wedged by a synchronous reconfiguration callback must not stop the expiry,
  /// which is what rescues a rig nobody can see.
  ///
  /// The UI update goes through `enqueue`, not straight to `adopt`: a tick that
  /// lands mid-`begin()` must reconcile after it, not against a session half-way
  /// through changing.
  private func startCountdown() {
    let session = session
    countdown.start(tick: { await session.tick() }) { [weak self] outcome in
      guard let self else { return }
      // Through the queue, never straight to `adopt`: a tick landing mid-apply
      // would publish a picture the apply is about to replace.
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

/// A surface that reports on a mirror change independently of whichever view
/// started it. Declared here and AppKit-free, so the contract belongs to the
/// thing that needs it; the window implementing it is an app-target island.
@MainActor
protocol MirrorConfirmationPresenting: AnyObject {
  /// Must be idempotent for unchanged content: called again on every tick.
  func presentMirrorConfirmation(_ content: MirrorConfirmationContent)
  func dismissMirrorConfirmation()
}

/// What the standalone surface is showing. Two cases because the outcomes
/// differ: a preview is a question with a countdown, a report is a statement
/// with nothing outstanding.
enum MirrorConfirmationContent: Hashable {
  /// A preview waiting to be answered, placed on the MASTER: the display the
  /// request named has no `NSScreen` from the instant the preview applies.
  case preview(CGDirectDisplayID)
  /// A refusal, a failed apply, or a break that left something mirrored. Nothing
  /// outstanding; one button, which dismisses.
  case report
}
