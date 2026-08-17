import CoreGraphics
import Foundation

/// What the restore pass has to TELL the user about a saved layout.
///
/// Restore runs unattended — at launch and when displays arrive — so there is
/// nobody watching to notice that the layout they saved is not the layout they
/// got. `ModeReapplyNotice`'s reasoning, one level up: staying quiet would mean
/// the user saved one arrangement, silently received another, and had no way to
/// find out.
public enum ArrangementReapplyNotice: Sendable, Equatable {
  /// **AR11.** The identity keys the layout names that each describe more than
  /// one attached display. Nothing was changed, and nothing will be: this is a
  /// refusal, not a failure, and the remedy is outside the app.
  case ambiguousIdentity([String])
  /// The saved layout is about a different display set than the one attached.
  /// Nothing was changed — a layout is a statement about a whole set, and half
  /// of one is a different arrangement rather than a smaller one.
  case setDiffers(missing: [String], extra: [String])
  /// **AR7.** The saved origins do not tile the displays they are about, at the
  /// very sizes those displays were recorded at. A resolution change is NOT this
  /// case and must not be reported as it (#180); see `savedForDifferentGeometry`.
  /// What is left is data that never described a legal layout at all, which a
  /// layout saved from an achieved one cannot be: hand-edited or corrupt
  /// preferences. Kept as the backstop, because it is the one refusal that stops
  /// an illegal layout from being sent.
  ///
  /// Nothing was changed. macOS cannot be made to hold an invalid layout — it
  /// silently moves things somewhere of its own choosing — and it is exactly the
  /// case `ArrangementPlan.expectsExactOrigins` turns the post-commit check OFF
  /// for, so sending it unattended would be committing a layout nobody chose
  /// with nothing left able to notice.
  case layoutNoLongerFits([ArrangementProblem])
  /// **#180.** The right displays are attached and at least one is not the size
  /// the layout was measured against, so its origins are about a machine that no
  /// longer exists. Names the identity keys that changed. Nothing was applied.
  ///
  /// Distinct from `layoutNoLongerFits`, and the distinction is the whole bug:
  /// the origins DID tile, on the footprints they were recorded on. Rebuilding
  /// them onto today's footprints and reporting the result as an overlap
  /// described a collision that existed only inside the app, in the sentence
  /// written for a user who had just dragged one display onto another.
  case savedForDifferentGeometry([String])
  /// The apply itself failed, including the post-commit check that fires when
  /// CoreGraphics reports success for a layout it did not achieve (#53).
  case failed(DisplayConfigError)

  /// Whether this is worth putting a surface in front of somebody for.
  ///
  /// Restore runs unattended, so the default is yes: silence about an attempt
  /// that went wrong is indistinguishable from one that worked. A stale
  /// footprint is the one thing here that is neither. Nothing was attempted, the
  /// machine is in a layout macOS derived from the saved one when the size
  /// changed, and the decision is PERMANENT: the saved layout is deliberately
  /// never rewritten, so the same answer is reached at every launch and every
  /// reconnect until the user arranges the displays themselves. A panel for that
  /// is not a report; it is a recurring alarm with nothing in it to act on.
  ///
  /// It is still a notice, and it still reaches the arrangement pane, where
  /// somebody has come looking and the sentence answers a question they are
  /// already asking.
  ///
  /// Exhaustive on purpose: a case added later has to decide.
  public var isWorthInterrupting: Bool {
    switch self {
    case .savedForDifferentGeometry: false
    case .ambiguousIdentity, .setDiffers, .layoutNoLongerFits, .failed: true
    }
  }
}

/// One restore decision: what to put on screen, and what to say.
///
/// The two are independent for `ModeReapplyDecision`'s reason — a refusal
/// changes nothing and still has to be reported.
public struct ArrangementReapplyDecision: Sendable, Equatable {
  /// nil means "change nothing". When set, it is the layout to COMMIT — see
  /// `ArrangementReapplyPolicy.scope`; there is no preview and no countdown.
  public let arrangementToApply: DisplayArrangement?
  /// nil means "the saved layout was honoured exactly" — the only case that
  /// says nothing at all.
  public let notice: ArrangementReapplyNotice?
  /// "Not now" as distinct from "nothing to do". Nothing is applied and nothing
  /// is reported, and the caller is being told to give the arrivals back
  /// (`TopologyArrivalTracker.release`) so a later event tries again.
  ///
  /// A third outcome is needed because the two fields above cannot express it:
  /// they say what to DO about this arrival, and this says the arrival has not
  /// been dealt with at all. Silently returning `.doNothing` would mark the
  /// displays handled, and — since a display that never leaves is never an
  /// arrival again — "not now" would quietly mean "never until replug".
  public let isDeferred: Bool

  public init(
    arrangementToApply: DisplayArrangement?,
    notice: ArrangementReapplyNotice?,
    isDeferred: Bool = false
  ) {
    self.arrangementToApply = arrangementToApply
    self.notice = notice
    self.isDeferred = isDeferred
  }

  public static let doNothing = ArrangementReapplyDecision(
    arrangementToApply: nil, notice: nil
  )
  public static let deferred = ArrangementReapplyDecision(
    arrangementToApply: nil, notice: nil, isDeferred: true
  )
}

/// The unattended half of saved layouts: given what was saved and what is on
/// screen, decide whether to rearrange the machine and what to report.
///
/// Pure and separate from the CoreGraphics calls because this is the path with
/// no user in front of it. `ModeReapplyPolicy`'s shape and its reasons, with the
/// stakes raised: a layout change moves the menu bar and the Dock, and a preview
/// that goes wrong is answered by a person within thirty seconds while a restore
/// that goes wrong is discovered days later.
public enum ArrangementReapplyPolicy {
  /// **Restore is a COMMIT, not a preview.** Nobody is watching, so a countdown
  /// that defaults to revert would undo every remembered layout a moment after
  /// every reconnect — the exact opposite of the feature.
  ///
  /// It is a constant here rather than a literal at the call site so the rule
  /// has somewhere to be tested: `.preview` scope is `kCGConfigureForAppOnly`,
  /// which unwinds when the process exits, and a restore committed at that scope
  /// would silently evaporate on quit. `.permanent` is what the rest of the
  /// arrangement feature commits at (§6.1) — the layout is what macOS itself
  /// persists per display set, so anything weaker is lost at logout and reads as
  /// the feature not working.
  public static let scope: DisplayConfigScope = .permanent

  /// - Parameters:
  ///   - isEnabled: the app-level opt-in
  ///     (`ArrangementPersistence.isRestoreEnabled`). Deliberately part of THIS
  ///     decision rather than a call-site guard, for `ModeReapplyPolicy`'s
  ///     reason: "a machine nobody opted in for is never rearranged" is the
  ///     property most worth having under test.
  ///   - arrivals: the displays claimed as having just arrived
  ///     (`TopologyArrivalTracker.claimArrivals`). **Empty means do nothing**,
  ///     and that is the whole of the arrival rule: a reconfiguration event is
  ///     also what the user dragging displays in System Settings produces, so a
  ///     pass that restored on every event would undo their change a second
  ///     later, forever. From the arrival until the set changes, the layout
  ///     belongs to the user.
  ///   - attached: every ONLINE display — active, mirrored, or asleep. Never an
  ///     active list: with the displays asleep the measurement was `online=3,
  ///     active=0`, so an active list makes a sleep read as a departure on every
  ///     display and the wake as three arrivals.
  ///   - current: the layout on screen, as `ArrangementSnapshot` read it.
  ///     Compared against `attached` rather than trusted — see the guard below.
  public static func decide(
    isEnabled: Bool,
    arrivals: Set<CGDirectDisplayID>,
    stored: SavedArrangement?,
    attached: [ConfiguredDisplay],
    current: DisplayArrangement
  ) -> ArrangementReapplyDecision {
    guard isEnabled else { return .doNothing }
    // Before the deferral gates, and deliberately: with nothing having arrived
    // there is no outstanding work to hand back, so deferring would hold a claim
    // nobody took.
    guard !arrivals.isEmpty else { return .doNothing }

    // **AR4 can be lost on the READ side.** `ArrangementSnapshot` SKIPS a
    // display whose `CGDisplayBounds` is unreadable, so that display gets no
    // tile and no origin — and a plan built from those tiles stays structurally
    // total while describing an incomplete world. Applying it would hand the
    // missing display to CoreGraphics' "repositioned to a location as close as
    // possible to its current location" heuristic, moving a display the user
    // never touched, silently.
    //
    // Deferred rather than resolved, and BEFORE the stored layout is consulted:
    // an incomplete read also signs as a different topology, so resolving here
    // would report a set difference about a machine that merely had a display
    // it could not describe for a moment.
    guard describesEveryPositionableDisplay(current, of: attached) else { return .deferred }

    guard let stored else { return .doNothing }

    switch ArrangementPersistence.resolve(stored, against: current) {
    case let .exact(layout):
      // The skip is not an optimisation. Applying the layout the machine is
      // already in still triggers a full CoreGraphics reconfiguration — which
      // blanks the screens, fires the topology callback, and would arrive back
      // here as another event.
      guard layout != current else { return .doNothing }
      // AR7, and checked HERE rather than at the apply for the reason the
      // interactive path checks it before staging: an invalid layout is the one
      // case the post-commit verification is turned off for, so sending it
      // unattended would leave nothing able to notice what macOS did instead.
      let problems = ArrangementRules.problems(in: layout)
      guard problems.isEmpty else {
        return ArrangementReapplyDecision(
          arrangementToApply: nil, notice: .layoutNoLongerFits(problems)
        )
      }
      return ArrangementReapplyDecision(arrangementToApply: layout, notice: nil)

    case let .ambiguous(identities):
      return ArrangementReapplyDecision(
        arrangementToApply: nil, notice: .ambiguousIdentity(identities)
      )

    case let .setDiffers(missing, extra):
      return ArrangementReapplyDecision(
        arrangementToApply: nil, notice: .setDiffers(missing: missing, extra: extra)
      )

    case let .geometryDiffers(identities):
      // A refusal, not "not now": nothing later restores a display to a size it
      // no longer has, so holding the arrivals would retry this on every event
      // forever.
      return ArrangementReapplyDecision(
        arrangementToApply: nil, notice: .savedForDifferentGeometry(identities)
      )

    case .none:
      // Nothing was saved for this set worth restoring. Not a failure, and
      // nothing to say about it.
      return .doNothing
    }
  }

  /// Whether the layout accounts for every display that can HOLD a position.
  ///
  /// Mirror slaves are expected to be absent: a slave has no independent origin
  /// and setting one would remove it from the mirror set (AR6), so it gets no
  /// tile by design. Anything else missing is a display the read could not place.
  private static func describesEveryPositionableDisplay(
    _ arrangement: DisplayArrangement, of attached: [ConfiguredDisplay]
  ) -> Bool {
    let described = Set(arrangement.tiles.map(\.id))
    return attached.allSatisfy { $0.isMirrorSlave || described.contains($0.id) }
  }
}

/// Which reconfigurations count as an ARRIVAL for a whole LAYOUT.
///
/// `DisplayArrivalTracker` answers "which displays arrived", which is the right
/// question for a per-display stored mode and only half of the right one for a
/// layout. A layout is a statement about a SET, so the event that matters is the
/// set changing — and a DEPARTURE is such an event while producing no arrival at
/// all: unplug the third display and the two that remain never left, so a
/// per-display tracker reports nothing and the layout saved for the pair never
/// comes back.
///
/// So this composes the tracker rather than replacing it. The tracker still owns
/// "seen absent since", which is what makes a fast unplug/replug count as a
/// departure even when both handlers run after the display is back; this adds
/// the set-level trigger: **when the topology signature changes, every display
/// in the new topology counts as having arrived.**
///
/// What it deliberately does NOT treat as an arrival:
///
/// - A display going to sleep. `attached` is the ONLINE list, and online means
///   active *or mirrored or sleeping*, so a sleeping display never leaves the
///   signature and never leaves the tracker.
/// - The user rearranging displays in System Settings. The set is unchanged, no
///   display arrived, and the layout stays theirs.
/// - This app's own restore. Applying a layout posts a reconfiguration event
///   with the same signature and the same displays, which claims nothing.
public struct TopologyArrivalTracker: Sendable, Equatable {
  private var displays = DisplayArrivalTracker()
  /// The topology the last claim was made against. `nil` until the first claim,
  /// which is what makes launch an arrival for every display.
  private var signature: TopologySignature?

  public init() {}

  /// Records a display set observed at some point in time — in particular, one
  /// sampled inside a notification block before any hop to another executor.
  /// Passed straight through; see `DisplayArrivalTracker.noteObserved`.
  public mutating func noteObserved(live: Set<CGDirectDisplayID>) {
    displays.noteObserved(live: live)
  }

  /// The displays whose arrival has not been acted on, marked handled as they
  /// are returned.
  ///
  /// Takes the ONLINE list rather than the layout: the signature has to survive
  /// a display whose bounds are momentarily unreadable, which drops it from the
  /// layout but not from the machine. A reset over that transient would make the
  /// whole set read as newly arrived and re-assert a saved layout over a change
  /// the user had just made by hand.
  public mutating func claimArrivals(online: [ConfiguredDisplay]) -> Set<CGDirectDisplayID> {
    let signature = TopologySignature(online: online)
    if signature != self.signature {
      self.signature = signature
      // The SET changed, so every display in it is part of an arrangement that
      // has not been decided yet — including displays that never physically
      // left. Dropping the per-display state is what expresses that.
      displays = DisplayArrivalTracker()
    }
    return displays.claimArrivals(live: Set(online.map(\.id)))
  }

  /// Gives a claimed display back, so the next pass treats it as an arrival
  /// again. For work that was claimed and then deliberately not done.
  public mutating func release(_ displayID: CGDirectDisplayID) {
    displays.release(displayID)
  }
}
