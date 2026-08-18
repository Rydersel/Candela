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

  /// The latest sample AS ADOPTED, carrying whatever pairing the store had
  /// stamped at that instant. Never read outside `topology`, which is the value
  /// this object publishes.
  private var sample = MirrorTopology([])

  /// The latest sample, stamped with the synthesis pairing (SS1). Read by both
  /// UI surfaces, by the hero badge and by every command in this file; never
  /// re-derived in a view.
  ///
  /// **Computed, and that is the close on a race with teeth.** The store's
  /// masters are noted when `SynthesisCoordinator` refreshes its snapshot, while
  /// this object re-adopts only when a topology sample arrives. An engage whose
  /// screen-parameters notification lands BEFORE the pairing note would leave a
  /// stored value un-stamped for the whole life of the engagement, and all three
  /// surfaces would then present the synthesis set as mirroring the user did,
  /// with nothing left to correct them. Reading the snapshot here also makes it
  /// an observation dependency of every view that reads this, so a pairing that
  /// lands late redraws them instead of being missed.
  ///
  /// The UNION of the two, not one replacing the other: they are the same table
  /// read at two moments, and a stamp can reach the store before the engine
  /// returns the pairing (or after, when a sample is older than the snapshot).
  /// Whichever knows first wins, and ambiguity resolves towards "this is
  /// synthesis", because a synthesis set rendered as user mirroring is the
  /// failure the SS7 carve-outs exist to prevent. A stale positive lasts until
  /// the next adopt, which any teardown produces: it destroys a virtual display,
  /// and that is a screen-parameters change.
  var topology: MirrorTopology {
    let masters = sample.synthesisMasters.union(synthesis?.masterIDs ?? [])
    guard masters != sample.synthesisMasters else { return sample }
    return MirrorTopology(sample.displays, synthesisMasters: masters)
  }

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
  @ObservationIgnored private let queue = PreviewQueue()
  @ObservationIgnored private let countdown = PreviewCountdownDriver()
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
    countdown.stop()
    queue.cancel()
  }

  // MARK: - Topology

  /// Re-samples and republishes. Called at launch, on every screen-parameters
  /// notification, and after anything this app applies.
  func refreshTopology() {
    adoptTopology(MirrorTopology(configurator.displays()))
  }

  /// Re-samples, republishes, and hands back what was PUBLISHED rather than what
  /// was sampled. The two differ by the synthesis pairing (SS1): a
  /// `configurator.displays()` sample cannot tell a mirror set the app engaged to
  /// serve a synthesized size from one the user asked for, and the store is where
  /// that pairing is stamped on. Every command below decides from this value, so
  /// no decision in this file is taken on an un-stamped sample.
  @discardableResult
  private func resampleAndPublish() -> MirrorTopology {
    refreshTopology()
    return topology
  }

  private func adoptTopology(_ arrived: MirrorTopology) {
    // The store's SECOND writer (`MirrorTopologySampler` is the first). Both
    // write a whole sample from the same source, so this is last-write-wins over
    // two values of the same shape, never a field at a time. Worth doing because
    // a keypress samples LIVE here — `toggleUnlessSingleDisplay` cannot wait for
    // a notification to have landed — and every drawable-ID resolution in the
    // app reads the store.
    //
    // Written FIRST and then read BACK, so what this object publishes carries the
    // synthesis pairing the store stamps on (SS1). The three UI readers of
    // `topology` are the SS7 carve-out sites, and on an un-stamped sample every
    // one of their predicates answers "ordinary mirror set".
    store.update(arrived)
    let stamped = store.topology()
    let changed = stamped != sample
    sample = stamped
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
    queue.enqueue {
      guard let outstanding = await self.session.previewedTopology else { return }
      let live = Set(arrived.displays.map(\.id))
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
  ///
  /// **A synthesized size comes down FIRST, through the engine** (SS13). The
  /// panic button's job is to give someone their desktops back, and
  /// `MirrorTopologyPolicy.toggle` would happily take a synthesis set apart with
  /// a null-master change: that leaves the virtual display standing with nothing
  /// showing on it, one of only two synthesis slots held, and the engine's
  /// pairing table describing a set that no longer exists.
  ///
  /// What is LEFT is then treated exactly as today, with one carve-out that
  /// `panicDecisionAfterUnwind` states in full: the press can break a user set
  /// but can never BUILD one. A press that took a synthesized size down and
  /// answered by mirroring the built-in onto the panel, with a thirty-second
  /// countdown, would be the opposite of a panic button.
  ///
  /// It still returns true in that case. There IS something to do, so the key
  /// must not fall through to a brightness step, even on the rig where the
  /// answer arrives seconds later.
  @discardableResult
  func toggleUnlessSingleDisplay() -> Bool {
    let sample = resampleAndPublish()
    guard sample.synthesisMasters.isEmpty else {
      unwindingSynthesis(
        then: { fresh in
          guard fresh.synthesisMasters.isEmpty else {
            // `panicDecisionAfterUnwind` answers nothing over this sample, and
            // the reason has to reach a surface: the hotkey has none of its
            // own, so silence here reads as a dead key. Set directly rather
            // than through a `perform`, whose first act is to clear the report
            // this is the report of.
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
          // set must not be held hostage to that: a panic press stalling over
          // mirroring the person built is the failure this arm exists to avoid.
          //
          // `userVisibleMirrorSets` is what keeps a raw null-master change off
          // the set that is still standing, which was the sound half of simply
          // refusing here. One transaction per set: the policy's machine-wide
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
  /// Pure and separately nameable so the one rule it carries can be pinned: the
  /// post-unwind press acts ONLY on a break. `MirrorTopologyPolicy.toggle`
  /// evaluates break-else-build, so on the common rig (one panel, one synthesized
  /// size, no user mirroring) the unwind removes the only set on the machine and
  /// the very same call then answers `.engage`: the press would take the size
  /// down and immediately mirror the built-in onto the panel behind a
  /// thirty-second countdown. `.refused(.onlyOneDisplay)` and
  /// `.refused(.noEligibleMaster)` are the same answer wearing different words:
  /// each is the build branch reporting it found nothing to build with, over a
  /// machine state the press itself produced.
  ///
  /// `.refused(.setCannotBeBroken)` DOES come back, and it is not a second
  /// action: a refusal stages nothing and reconfigures nothing, it only names
  /// the set macOS would not release. Swallowing it would leave someone looking
  /// at mirroring that survived a panic press with nothing on screen about it.
  ///
  /// **A sample that still shows a synthesis master answers nothing at all.**
  /// The caller's own verification is the pairing table, and the table is empty
  /// for the whole of an engage, so it can read "everything came down" over a
  /// machine that has a synthesis set on it. This is the second reading, taken
  /// from the topology the decision would be made from: SS13's rule is that no
  /// raw mirror change is ever staged over a standing synthesis set, and a
  /// decision made here is exactly such a change. The caller reports it.
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

  /// **Also unwinds synthesis first**, and for a sharper reason than the toggle:
  /// `MirrorTopologyPolicy.engage` stages a change for every other display in the
  /// sample, the synthesis VD included, so a user set built while a synthesized
  /// size is engaged would point the virtual display at the panel that is
  /// currently mirroring ONTO it. Nothing in this app may hand CoreGraphics that
  /// (SS13's rule generalised: no raw mirror change is staged over a standing
  /// synthesis set).
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

  /// The UI's one-set break. A GENUINE user set on a machine that also has a
  /// synthesized size engaged breaks exactly as it does today: the policy reads
  /// `setMembers(containing:)`, which is that display's own set, so nothing here
  /// can stage a change against a synthesis member unless `member` is one.
  ///
  /// When it IS one, the set comes down through the engine instead (SS13). No
  /// surface offers Stop Mirroring for a synthesis set (both sections drop them
  /// from their listings), so this is the defensive half of that rule rather than
  /// a reachable path, and it is here because "any Stop Mirroring affordance" is
  /// what the ruling binds, not "the two we happen to have written".
  func disengage(containing member: CGDirectDisplayID) {
    let sample = resampleAndPublish()
    guard !sample.isSynthesisSet(containing: member) else {
      // Takes down every synthesis set, not just this one: the engine's only
      // pref-free teardown is the all-sets one, and SS6 caps the pool at two
      // slots. A per-display route would have to be added to
      // `SynthesisCoordinator` rather than reimplemented here, since the verified
      // sequence (SS10) is the whole point of going through the engine.
      unwindingSynthesis { _ in }
      return
    }
    perform(MirrorTopologyPolicy.disengage(sample, containing: member), capturedFrom: sample)
  }

  /// The mode-synthesis coordinator, reached through the mode coordinator this
  /// object is already constructed with.
  ///
  /// Deliberately NOT a second injection point in `AppModel`: `displayModes.synthesis`
  /// is assigned in the very initialiser that produces the `modes` reference
  /// below, so this is non-nil for as long as the app is, while a closure of our
  /// own would be one more thing a future wiring change could leave sitting at
  /// its no-op default, with no symptom until a panic press orphaned a virtual
  /// display. nil is the unwired case (a fixture), and it degrades to exactly the
  /// pre-synthesis behaviour.
  private var synthesis: SynthesisCoordinator? { modes.synthesis }

  /// Takes every synthesis set down through the engine, VERIFIES from the pairing
  /// table that they are gone, and only then runs `body` against a fresh sample
  /// (SS13).
  ///
  /// The verification is the pairing table rather than the disengage's own
  /// return, which is the house rule about achieved state applied to a caller
  /// that has one available: `SynthesisCoordinator` re-reads the engine's table
  /// after every operation it performs, so an empty table is the engine's answer
  /// about what is still standing rather than a report about what it attempted.
  ///
  /// **The table is only evidence once the teardown has actually run**, and that
  /// is what the return value below says. The snapshot is EMPTY for the whole of
  /// an engage, so an unwind refused because one is in flight leaves an empty
  /// table describing a machine that is about to have a synthesis set on it: an
  /// empty table read on its own would answer "everything came down" and let a
  /// raw mirror change be staged over it. A refusal is therefore stuck, not
  /// clean.
  ///
  /// `disengageAllForReset()` is the whole-app reset's method and its name says
  /// so, but it is also the only pref-free teardown the coordinator exposes: it
  /// ends outstanding previews, claims the gate, disengages each pairing through
  /// the engine and releases through the funnel, and it writes no pref. A panic
  /// press must not opt a display out of synthesized sizes, so the two paths that
  /// DO write prefs (`setOptIn`, `reset`) are the wrong ones here.
  ///
  /// `body` is not run when anything is still engaged: staging a raw mirror
  /// change over a set the engine could not take down is the exact outcome this
  /// ruling exists to prevent. `ifStuck` is what that caller does instead, and
  /// it is the caller's business rather than this helper's: the hotkey breaks
  /// the user's own sets anyway, while an engage refuses outright (breaking sets
  /// nobody asked about is not a failure mode of "start mirroring").
  private func unwindingSynthesis(
    then body: @escaping (MirrorTopology) -> Void,
    ifStuck stuck: ((MirrorTopology) -> Void)? = nil
  ) {
    guard let synthesis else { return }
    // Raised synchronously, before any await, for `perform`'s reason: a control
    // that queues work and only then disables itself is a control two clicks get
    // through. The unwind runs for seconds, so this is the window that matters
    // most.
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
          // The engine's own word for it, on the surface that renders synthesis
          // refusals: no `MirrorRefusal` case describes a synthesized size that
          // would not come down, and inventing one would put a sentence about
          // mirroring in front of a person who never asked for mirroring. That
          // surface is the settings hub, though, which is why the report below
          // is raised as well: the hotkey has no other surface at all.
          synthesis.note(.engine(.unwindIncomplete), for: held.physicalDisplayID)
        }
        // Whatever this caller does instead, FIRST: both it and the report land
        // through the same serial queue, and a `perform` runs `dismissReport()`
        // as its first act, so a failure raised ahead of it would be wiped by
        // the very break it is reporting alongside.
        stuck?(self.resampleAndPublish())
        self.queue.enqueue {
          // Raised on EVERY stuck unwind, partial ones included. The sentence it
          // renders ("The mirroring change did not take effect, and nothing was
          // altered") is then not the whole truth on two shapes: a partial
          // teardown did alter something, and the hotkey's `ifStuck` may have
          // broken a user set beside it. Reported anyway, because the hotkey's
          // only surface is this card and silence there reads as a dead key, and
          // an over-narrow claim is the lesser fault next to an unexplained
          // synthesized size that would not come down. The honest sentence needs
          // a `MirroringCopy` string this file does not own.
          self.lastFailure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
          self.syncConfirmation()
        }
        return
      }
      // Re-sampled rather than carried: the unwind destroyed a display and
      // changed a mirror set, so the entry sample describes a machine that no
      // longer exists, and it is what the staged changes would be decided from.
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
  //
  // The queue itself is `PreviewQueue` in CandelaKit (#68): four coordinators
  // held four byte-identical copies of it, and the countdown driver beside it.

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
