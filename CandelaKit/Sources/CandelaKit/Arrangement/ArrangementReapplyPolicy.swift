import CoreGraphics
import Foundation

/// What the restore pass has to TELL the user about a saved layout.
///
/// Restore runs unattended, at launch and on arrival, so nobody is watching to notice
/// that the layout they saved is not the layout they got.
public enum ArrangementReapplyNotice: Sendable, Equatable {
  /// **The identity-ambiguity rule.** Identity keys the layout names that each
  /// describe more than one attached display. A refusal rather than a failure; the
  /// remedy is outside the app.
  case ambiguousIdentity([String])
  /// The saved layout is about a different display set. Nothing was changed: half a
  /// layout is a different arrangement, not a smaller one.
  case setDiffers(missing: [String], extra: [String])
  /// **The spring-back rule.** The saved origins do not tile the displays they are
  /// about, at the very sizes those displays were recorded at. A resolution change
  /// is NOT this case; see
  /// `savedForDifferentGeometry`. What is left is data that never described a legal
  /// layout, which is hand-edited or corrupt preferences.
  ///
  /// Kept as the backstop that stops an illegal layout from being sent. macOS cannot
  /// be made to hold one, and this is exactly the case
  /// `ArrangementPlan.expectsExactOrigins` turns the post-commit check OFF for, so
  /// sending it unattended commits a layout nobody chose with nothing able to notice.
  case layoutNoLongerFits([ArrangementProblem])
  /// The right displays are attached and at least one is not the size the layout was
  /// measured against, so its origins describe a machine that no longer exists.
  ///
  /// Distinct from `layoutNoLongerFits`, and the distinction is the whole bug: the
  /// origins DID tile, on the footprints they were recorded on. Rebuilding them onto
  /// today's footprints and reporting an overlap described a collision that existed
  /// only inside the app.
  case savedForDifferentGeometry([String])
  /// The apply failed, including the post-commit check that fires when CoreGraphics
  /// reports success for a layout it did not achieve.
  case failed(DisplayConfigError)

  /// Whether this is worth putting a surface in front of somebody for.
  ///
  /// Restore runs unattended, so the default is yes: silence about an attempt that
  /// went wrong is indistinguishable from one that worked. A stale footprint is the
  /// exception. Nothing was attempted, and the answer is PERMANENT, since the saved
  /// layout is never rewritten, so every launch reaches it again until the user
  /// arranges the displays themselves. A panel for that is a recurring alarm with
  /// nothing to act on.
  ///
  /// Still a notice, and it still reaches the arrangement pane, where somebody has
  /// come looking. Exhaustive on purpose: a case added later has to decide.
  public var isWorthInterrupting: Bool {
    switch self {
    case .savedForDifferentGeometry: false
    case .ambiguousIdentity, .setDiffers, .layoutNoLongerFits, .failed: true
    }
  }
}

/// One restore decision: what to put on screen, and what to say.
///
/// The two are independent: a refusal changes nothing and still has to be reported.
public struct ArrangementReapplyDecision: Sendable, Equatable {
  /// nil means "change nothing". When set, the layout to COMMIT: no preview, no
  /// countdown (`ArrangementReapplyPolicy.scope`).
  public let arrangementToApply: DisplayArrangement?
  /// nil means the saved layout was honoured exactly, the only silent case.
  public let notice: ArrangementReapplyNotice?
  /// "Not now" as distinct from "nothing to do": the caller gives the arrivals back
  /// (`TopologyArrivalTracker.release`) so a later event tries again.
  ///
  /// Returning `.doNothing` instead would mark the displays handled, and since a
  /// display that never leaves is never an arrival again, "not now" would quietly
  /// mean "never until replug".
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
/// Pure and separate from the CoreGraphics calls because no user is in front of this
/// path. `ModeReapplyPolicy`'s shape, with the stakes raised: a layout change moves
/// the menu bar and the Dock, and a bad restore is discovered days later.
public enum ArrangementReapplyPolicy {
  /// **Restore is a COMMIT, not a preview.** Nobody is watching, so a countdown that
  /// defaults to revert would undo every remembered layout a moment after every
  /// reconnect.
  ///
  /// A constant rather than a literal at the call site so the rule has somewhere to be
  /// tested. `.preview` is `kCGConfigureForAppOnly` and unwinds when the process
  /// exits; macOS persists the layout per display set, so anything weaker than
  /// `.permanent` is lost at logout and reads as the feature not working (§6.1).
  public static let scope: DisplayConfigScope = .permanent

  /// - Parameters:
  ///   - isEnabled: the app-level opt-in (`ArrangementPersistence.isRestoreEnabled`),
  ///     part of THIS decision rather than a call-site guard so "a machine nobody
  ///     opted in for is never rearranged" is testable.
  ///   - arrivals: displays claimed as having just arrived
  ///     (`TopologyArrivalTracker.claimArrivals`). **Empty means do nothing.** The
  ///     user dragging displays in System Settings also produces a reconfiguration
  ///     event, so a pass that restored on every event would undo their change a
  ///     second later, forever.
  ///   - attached: every ONLINE display: active, mirrored, or asleep. Never an active
  ///     list. With the displays asleep the measurement was `online=3, active=0`, so
  ///     an active list makes a sleep read as a departure on every display and the
  ///     wake as three arrivals.
  ///   - current: the layout on screen, as `ArrangementSnapshot` read it. Compared
  ///     against `attached` rather than trusted; see the guard below.
  ///   - substituting: the synthesis-substitution map, the same one the layout was
  ///     saved under, so a layout saved for the panel is matched against the pair showing its picture
  ///     rather than reported as a display set the user has never seen.
  public static func decide(
    isEnabled: Bool,
    arrivals: Set<CGDirectDisplayID>,
    stored: SavedArrangement?,
    attached: [ConfiguredDisplay],
    current: DisplayArrangement,
    substituting: [CGDirectDisplayID: String] = [:]
  ) -> ArrangementReapplyDecision {
    guard isEnabled else { return .doNothing }
    // Before the deferral gates: with nothing arrived there is no work to hand back,
    // so deferring would hold a claim nobody took.
    guard !arrivals.isEmpty else { return .doNothing }

    // **The whole-arrangement rule can be lost on the READ side.** `ArrangementSnapshot`
    // SKIPS a display
    // whose `CGDisplayBounds` is unreadable, so a plan built from those tiles stays
    // structurally total while describing an incomplete world. Applying it hands the
    // missing display to CoreGraphics' reposition-nearby heuristic, moving a display
    // the user never touched.
    //
    // Deferred BEFORE the stored layout is consulted: an incomplete read also signs as
    // a different topology, so resolving here would report a set difference about a
    // machine that merely could not describe a display for a moment.
    guard describesEveryPositionableDisplay(current, of: attached) else { return .deferred }

    guard let stored else { return .doNothing }

    switch ArrangementPersistence.resolve(stored, against: current, substituting: substituting) {
    case let .exact(layout):
      // Not an optimisation. Applying the layout the machine is already in still
      // triggers a full CoreGraphics reconfiguration, which blanks the screens, fires
      // the topology callback, and arrives back here as another event.
      guard layout != current else { return .doNothing }
      // The spring-back rule, checked HERE rather than at the apply: an invalid
      // layout is the one case
      // the post-commit verification is turned off for, so sending it unattended
      // leaves nothing able to notice what macOS did instead.
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
      // A refusal, not "not now": nothing later restores a display to a size it no
      // longer has, so holding the arrivals would retry forever.
      return ArrangementReapplyDecision(
        arrangementToApply: nil, notice: .savedForDifferentGeometry(identities)
      )

    case .none:
      // Nothing saved for this set. Not a failure, and nothing to say.
      return .doNothing
    }
  }

  /// Whether the layout accounts for every display that can HOLD a position.
  ///
  /// Mirror slaves are expected to be absent: a slave has no independent origin and
  /// setting one removes it from the mirror set. Anything else missing is a
  /// display the read could not place.
  private static func describesEveryPositionableDisplay(
    _ arrangement: DisplayArrangement, of attached: [ConfiguredDisplay]
  ) -> Bool {
    let described = Set(arrangement.tiles.map(\.id))
    return attached.allSatisfy { $0.isMirrorSlave || described.contains($0.id) }
  }
}

/// Which reconfigurations count as an ARRIVAL for a whole LAYOUT.
///
/// `DisplayArrivalTracker` answers "which displays arrived", which is only half the
/// question for a layout. A DEPARTURE changes the set while producing no arrival:
/// unplug the third display and the two that remain never left, so a per-display
/// tracker reports nothing and the layout saved for the pair never comes back.
///
/// So this composes the tracker rather than replacing it. The tracker still owns
/// "seen absent since", which makes a fast unplug/replug count as a departure even
/// when both handlers run after the display is back. This adds the set-level trigger:
/// **when the topology signature changes, every display in the new topology counts as
/// having arrived.**
///
/// What it deliberately does NOT treat as an arrival:
///
/// - A display going to sleep. `attached` is the ONLINE list, and online means active
///   *or mirrored or sleeping*, so a sleeping display never leaves the signature.
/// - The user rearranging displays in System Settings. The set is unchanged.
/// - This app's own restore. Applying a layout posts a reconfiguration event with the
///   same signature and the same displays.
public struct TopologyArrivalTracker: Sendable, Equatable {
  private var displays = DisplayArrivalTracker()
  /// `nil` until the first claim, which is what makes launch an arrival for every
  /// display.
  private var signature: TopologySignature?

  public init() {}

  /// Records a display set observed at some point in time, in particular one sampled
  /// inside a notification block before any hop to another executor.
  public mutating func noteObserved(live: Set<CGDirectDisplayID>) {
    displays.noteObserved(live: live)
  }

  /// The displays whose arrival has not been acted on, marked handled as they
  /// are returned.
  ///
  /// Takes the ONLINE list rather than the layout: the signature has to survive a
  /// display whose bounds are momentarily unreadable, which drops it from the layout
  /// but not from the machine. A reset over that transient makes the whole set read as
  /// newly arrived and re-asserts a saved layout over a change the user just made.
  ///
  /// **The synthesis-substitution map**: `substituting` makes engaging or dropping a
  /// synthesized size not a change of display SET. Without it every display reads as newly arrived the moment
  /// a size engages. Runtime IDs, handed in with the sample; nothing here stores one.
  public mutating func claimArrivals(
    online: [ConfiguredDisplay], substituting: [CGDirectDisplayID: String] = [:]
  ) -> Set<CGDirectDisplayID> {
    let signature = TopologySignature(online: online, substituting: substituting)
    if signature != self.signature {
      self.signature = signature
      // The SET changed, so every display in it is part of an undecided arrangement,
      // including displays that never physically left.
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
