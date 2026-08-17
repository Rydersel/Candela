import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The restore path has nobody watching it and moves the menu bar, so every rule
/// it follows is pinned here rather than left to its one call site.
@Suite("Arrangement reapply policy (#13/#14)")
struct ArrangementReapplyPolicyTests {
  private static func identity(_ name: String) -> DisplayConfigIdentity {
    switch name {
    case "mag": DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    case "dell": DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    default: DisplayConfigIdentity(vendor: 0, model: 0, serial: 0, isBuiltIn: true)
    }
  }

  private func display(
    _ id: CGDirectDisplayID, _ name: String, mirrors: CGDirectDisplayID = kCGNullDirectDisplay
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id, identity: Self.identity(name), name: name,
      isBuiltIn: name == "builtIn", mirrorsDisplay: mirrors
    )
  }

  private func tile(
    _ id: CGDirectDisplayID, _ name: String, _ rect: DisplayRect,
    mirroredIDs: [CGDirectDisplayID] = []
  ) -> ArrangementTile {
    ArrangementTile(
      id: id, identity: Self.identity(name), name: name, rect: rect, mirroredIDs: mirroredIDs
    )
  }

  private var left: DisplayRect { DisplayRect(x: 0, y: 0, width: 1920, height: 1080) }
  private var right: DisplayRect { DisplayRect(x: 1920, y: 0, width: 1920, height: 1080) }

  /// MAG (id 3) at the origin, Dell (id 2) to its right.
  private var onScreen: DisplayArrangement {
    DisplayArrangement(tiles: [tile(3, "mag", left), tile(2, "dell", right)])
  }

  private var attached: [ConfiguredDisplay] { [display(3, "mag"), display(2, "dell")] }
  private var bothArrived: Set<CGDirectDisplayID> { [2, 3] }

  /// The saved layout puts the Dell on the LEFT — the opposite of what is on
  /// screen, so a restore is a visible change and a skipped restore is visible
  /// too.
  private var saved: SavedArrangement {
    SavedArrangement(DisplayArrangement(tiles: [tile(2, "dell", left), tile(3, "mag", right)]))
  }

  // MARK: - The opt-in

  @Test func restoreIsSkippedEntirelyWhenTheOptInIsOff() {
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: false, arrivals: bothArrived, stored: saved,
      attached: attached, current: onScreen
    )
    #expect(decision == .doNothing)
    // Not deferred either: an opted-out machine has no outstanding work to hand
    // back, and holding the arrivals would retry the same refusal forever.
    #expect(!decision.isDeferred)
  }

  @Test func nothingSavedForThisSetIsNothingToDo() {
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: nil,
      attached: attached, current: onScreen
    )
    #expect(decision == .doNothing)
  }

  // MARK: - Arrival gating

  /// The rule the whole feature rests on. A reconfiguration event is ALSO what
  /// the user dragging displays in System Settings produces, so a pass that
  /// restored on every event would undo their change a second later, forever.
  @Test func restoreHappensOnArrivalNotOnEveryReconfiguration() {
    let onArrival = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: onScreen
    )
    #expect(onArrival.arrangementToApply != nil)

    let onAnyOtherEvent = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: [], stored: saved,
      attached: attached, current: onScreen
    )
    #expect(onAnyOtherEvent == .doNothing)
  }

  /// The "forever" bug, at the level the policy can see it: with the displays
  /// already handled, a layout that disagrees with the saved one is left alone.
  @Test func aManualChangeAfterRestoreIsNotUndone() {
    var arrivals = TopologyArrivalTracker()
    #expect(arrivals.claimArrivals(online: attached) == [2, 3])

    // The user drags the displays back. Same set, same displays, another
    // reconfiguration event — and nothing is claimed by it.
    let manual = onScreen.moving(2, to: DisplayPoint(x: -1920, y: 0))
    let claimed = arrivals.claimArrivals(online: attached)
    #expect(claimed.isEmpty)

    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: claimed, stored: saved,
      attached: attached, current: manual
    )
    #expect(decision == .doNothing)
  }

  /// Online means active **or mirrored or sleeping** — measured `online=3,
  /// active=0` with the displays asleep. Reading an active list here makes one
  /// sleep look like a departure on every display and the wake like three
  /// arrivals, which silently re-asserts the saved layout over a manual change,
  /// daily. That exact bug shipped in this repo once.
  @Test func aSleepingDisplayIsNotTreatedAsADeparture() {
    var arrivals = TopologyArrivalTracker()
    #expect(arrivals.claimArrivals(online: attached) == [2, 3])

    // Everything asleep. The ONLINE list is unchanged, so this is not a
    // departure and the wake is not an arrival.
    #expect(arrivals.claimArrivals(online: attached).isEmpty)
    #expect(arrivals.claimArrivals(online: attached).isEmpty)
  }

  /// The set-level half of the rule. Unplug the third display and the two that
  /// remain never left, so a per-display tracker reports nothing — and the
  /// layout saved for the pair would never come back.
  @Test func aDepartureMakesTheRemainingDisplaysArriveAsANewSet() {
    var arrivals = TopologyArrivalTracker()
    let three = attached + [display(1, "builtIn")]
    #expect(arrivals.claimArrivals(online: three) == [1, 2, 3])
    #expect(arrivals.claimArrivals(online: three).isEmpty)

    #expect(arrivals.claimArrivals(online: attached) == [2, 3])
  }

  /// A replug, whatever ID the display comes back under.
  @Test func aDisplayThatLeavesAndReturnsArrivesAgain() {
    var arrivals = TopologyArrivalTracker()
    #expect(arrivals.claimArrivals(online: attached) == [2, 3])
    #expect(arrivals.claimArrivals(online: [display(3, "mag")]) == [3])
    // Back, with the IDs reassigned the way a dock cycle reassigns them.
    let reassigned = [display(2, "mag"), display(3, "dell")]
    #expect(arrivals.claimArrivals(online: reassigned) == [2, 3])
  }

  /// A claim that is deliberately not acted on goes back, or "not now" becomes
  /// "never until replug": nothing else re-arms an arrival for a display that
  /// stays put.
  @Test func aReleasedClaimIsAnArrivalAgain() {
    var arrivals = TopologyArrivalTracker()
    #expect(arrivals.claimArrivals(online: attached) == [2, 3])
    arrivals.release(3)
    #expect(arrivals.claimArrivals(online: attached) == [3])
  }

  /// This app's own restore posts a reconfiguration event. It must not claim
  /// anything, or the restore would arrive back here and reapply forever.
  @Test func theRestoresOwnReconfigurationEventClaimsNothing() {
    var arrivals = TopologyArrivalTracker()
    _ = arrivals.claimArrivals(online: attached)
    #expect(arrivals.claimArrivals(online: attached).isEmpty)
  }

  /// The arrival gate reads the ONLINE list and the storage key reads the
  /// layout. They have to be talking about the same topology, so the agreement
  /// is pinned rather than argued.
  @Test func bothSpellingsOfTheSignatureAgreeOnACompleteRead() {
    #expect(TopologySignature(online: attached) == TopologySignature(onScreen))

    // And a mirror slave changes neither: it has no tile (AR6) and is filtered
    // out of the online list for the same reason.
    let mirrored = attached + [display(9, "mag", mirrors: 3)]
    let withMirror = DisplayArrangement(tiles: [
      tile(3, "mag", left, mirroredIDs: [9]), tile(2, "dell", right),
    ])
    #expect(TopologySignature(online: mirrored) == TopologySignature(withMirror))
    #expect(TopologySignature(online: mirrored) == TopologySignature(online: attached))
  }

  // MARK: - The read-side trap (AR4)

  /// **`ArrangementSnapshot` SKIPS a display whose `CGDisplayBounds` is
  /// unreadable**, so it gets no tile and no origin. The plan stays structurally
  /// total while describing an incomplete world, and applying it hands the
  /// missing display to CoreGraphics' "as close as possible to its current
  /// location" heuristic — a display the user never touched, moved silently.
  @Test func restoreIsDeferredWhenTheTopologyCannotBeReconfigured() {
    let incomplete = DisplayArrangement(tiles: [tile(3, "mag", left)])
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: incomplete
    )
    #expect(decision == .deferred)
    #expect(decision.arrangementToApply == nil)
    #expect(decision.notice == nil)
    #expect(decision.isDeferred)
  }

  /// An empty read is every display unreadable at once, which is the same
  /// transient rather than every display having departed.
  @Test func anEmptyLayoutReadIsDeferredNotTreatedAsAnEmptyMachine() {
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: DisplayArrangement(tiles: [])
    )
    #expect(decision == .deferred)
  }

  /// Deferred BEFORE the saved layout is consulted, for
  /// `ModeReapplyPolicy`'s reason: an incomplete read also signs as a different
  /// topology, so resolving against it would report a set difference about a
  /// machine that merely had a display it could not describe for a moment.
  @Test func anIncompleteReadIsNotReportedAsASetDifference() {
    let incomplete = DisplayArrangement(tiles: [tile(3, "mag", left)])
    for stored in [saved, nil] {
      let decision = ArrangementReapplyPolicy.decide(
        isEnabled: true, arrivals: bothArrived, stored: stored,
        attached: attached, current: incomplete
      )
      #expect(decision == .deferred)
      #expect(decision.notice == nil)
    }
  }

  /// A mirror slave is EXPECTED to have no tile — it has no independent origin
  /// and setting one would remove it from the mirror set (AR6). Deferring on it
  /// would mean never restoring anything while a mirror is engaged.
  @Test func aMirrorSlaveWithNoTileIsNotAnIncompleteRead() {
    let mirrored = attached + [display(9, "mag", mirrors: 3)]
    let withMirror = DisplayArrangement(tiles: [
      tile(3, "mag", left, mirroredIDs: [9]), tile(2, "dell", right),
    ])
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: [2, 3, 9], stored: saved,
      attached: mirrored, current: withMirror
    )
    #expect(!decision.isDeferred)
    #expect(decision.arrangementToApply != nil)
  }

  // MARK: - Outcomes

  @Test func anExactMatchIsAppliedAndSaysNothing() throws {
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: onScreen
    )
    let layout = try #require(decision.arrangementToApply)
    #expect(decision.notice == nil)
    #expect(layout.tile(2)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(layout.tile(3)?.rect.origin == DisplayPoint(x: 1920, y: 0))
    // AR4: the layout names every display that can hold a position, so the plan
    // built from it cannot leave one to the heuristic.
    #expect(Set(layout.tiles.map(\.id)) == Set(onScreen.tiles.map(\.id)))
  }

  /// Applying the layout the machine is already in still costs a full
  /// CoreGraphics reconfiguration — blanked screens, another topology event, and
  /// this same decision again. At launch, for nothing.
  @Test func aMachineAlreadyInItsSavedLayoutIsLeftAlone() {
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: SavedArrangement(onScreen),
      attached: attached, current: onScreen
    )
    #expect(decision == .doNothing)
  }

  /// **AR11.** Two attached displays share an identity and nothing separates
  /// them, so nothing says which saved position belongs to which screen. Refused
  /// and reported — a coin flip that swaps the user's screens is worse than not
  /// restoring.
  @Test func aTwinCollisionIsRefusedAndReportedRatherThanGuessed() {
    let twins = [display(2, "mag"), display(3, "mag")]
    let twinLayout = DisplayArrangement(tiles: [tile(2, "mag", left), tile(3, "mag", right)])
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: [2, 3], stored: SavedArrangement(twinLayout),
      attached: twins, current: twinLayout
    )
    #expect(decision.arrangementToApply == nil)
    #expect(decision.notice == .ambiguousIdentity([Self.identity("mag").key]))
    // A refusal, not "not now": no later event separates identical panels, so
    // holding the arrivals would retry the same refusal on every event forever.
    #expect(!decision.isDeferred)
  }

  /// **§7.4, and #180 is what it costs to get this wrong.** Stored MODES are
  /// reapplied before the layout is, so a display really can be a different size
  /// than it was when the layout was captured. Its recorded origins are then
  /// about a machine that no longer exists, and nothing is applied.
  ///
  /// What must NOT happen is the app rebuilding the old origins onto the new
  /// footprints, discovering that its own reconstruction overlaps, and reporting
  /// that overlap as a refusal. That is what shipped: a panel at every launch
  /// telling the user two displays covered each other while they sat side by
  /// side.
  @Test func aSavedLayoutRecordedAtDifferentSizesAppliesNothingAndReportsNoOverlap() {
    // The Dell is now twice as wide, and macOS has already moved the MAG right
    // to make room, so the machine on screen is perfectly legal.
    let resized = DisplayArrangement(tiles: [
      tile(2, "dell", DisplayRect(x: 0, y: 0, width: 3840, height: 1080)),
      tile(3, "mag", DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementRules.problems(in: resized).isEmpty)

    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: resized
    )
    #expect(decision.arrangementToApply == nil)
    #expect(decision.notice == .savedForDifferentGeometry([Self.identity("dell").key]))
    #expect(!decision.isDeferred)
  }

  /// The state is permanent: the saved layout is not rewritten, so this same
  /// decision is reached again on every launch and every reconnect until the
  /// user arranges the displays themselves. A surface that interrupts them for
  /// it is therefore not a report, it is a recurring alarm with no off switch,
  /// and there is nothing in it for them to act on.
  ///
  /// Genuine restore failures are unaffected: unattended, silence about an
  /// attempt that went wrong is indistinguishable from one that worked, and that
  /// is a different thing from silence about deciding not to attempt.
  @Test func onlyAStaleFootprintIsKeptOffTheConfirmationSurface() {
    #expect(!ArrangementReapplyNotice.savedForDifferentGeometry(["a"]).isWorthInterrupting)

    let interrupting: [ArrangementReapplyNotice] = [
      .ambiguousIdentity(["a"]),
      .setDiffers(missing: ["a"], extra: ["b"]),
      .layoutNoLongerFits([.overlap(1, 2)]),
      .failed(DisplayConfigError(cgErrorCode: 1000)),
    ]
    for notice in interrupting {
      #expect(notice.isWorthInterrupting, "\(notice) must still reach the user")
    }
  }

  /// **AR7 stays as the backstop it was**, reachable now only for a stored
  /// layout that does not tile at the very sizes it recorded: hand-edited or
  /// corrupt data, since a layout is only ever saved from one the machine
  /// achieved. macOS cannot be made to hold an invalid layout, and this is the
  /// exact case `expectsExactOrigins` turns the post-commit check off for, so
  /// sending it unattended would commit a layout nobody chose with nothing left
  /// able to notice.
  @Test func aStoredLayoutThatDoesNotTileAtItsOwnRecordedSizesIsStillRefused() {
    let overlapping = SavedArrangement(entries: [
      SavedArrangementEntry(
        identity: Self.identity("dell").key, x: 0, y: 0, width: 1920, height: 1080
      ),
      SavedArrangementEntry(
        identity: Self.identity("mag").key, x: 960, y: 0, width: 1920, height: 1080
      ),
    ])
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: overlapping,
      attached: attached, current: onScreen
    )
    #expect(decision.arrangementToApply == nil)
    #expect(decision.notice == .layoutNoLongerFits([.overlap(2, 3)]))
    #expect(!decision.isDeferred)
  }

  @Test func aDifferentDisplaySetIsReportedRatherThanPartlyApplied() {
    let magOnly = [display(3, "mag")]
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: [3], stored: saved,
      attached: magOnly, current: DisplayArrangement(tiles: [tile(3, "mag", left)])
    )
    #expect(decision.arrangementToApply == nil)
    #expect(decision.notice == .setDiffers(missing: [Self.identity("dell").key], extra: []))
  }

  // MARK: - Not a preview

  /// Restore commits at a scope that OUTLIVES the process. `.preview` is
  /// `kCGConfigureForAppOnly`, which unwinds on exit — a restore committed there
  /// would evaporate on quit — and `.session` is dropped at logout, which reads
  /// as the feature not working.
  @Test func restoreCommitsDirectlyWithoutACountdown() {
    #expect(ArrangementReapplyPolicy.scope == .permanent)
    #expect(ArrangementReapplyPolicy.scope != .preview)
    // The decision is an instruction, not a question: there is nothing in it to
    // keep or revert, and no outcome that means "applied, pending an answer".
    let decision = ArrangementReapplyPolicy.decide(
      isEnabled: true, arrivals: bothArrived, stored: saved,
      attached: attached, current: onScreen
    )
    #expect(decision.arrangementToApply != nil)
    #expect(!decision.isDeferred)
  }
}
