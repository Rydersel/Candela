import CoreGraphics
import Foundation

/// One display's requested origin. `CGConfigureDisplayOrigin`'s two arguments,
/// named — a tuple would not be `Equatable`, and every test here asserts a whole
/// change list against an expected one (the same reason `MirrorChange` is a
/// struct).
public struct DisplayOriginChange: Sendable, Equatable {
  public let id: CGDirectDisplayID
  public let origin: DisplayPoint

  public init(id: CGDirectDisplayID, origin: DisplayPoint) {
    self.id = id
    self.origin = origin
  }
}

/// A layout change, staged as ONE transaction.
///
/// **AR4 is structural here, not a check.** The plan stores a whole
/// `DisplayArrangement` and *derives* `changes` from its tiles, so a partial
/// plan is not a value this type can hold — there is no initialiser that takes
/// a change list. That matters because CoreGraphics repositions any display
/// whose origin is not explicitly set: *"Any display whose origin is not
/// explicitly set in a reconfiguration will be repositioned to a location as
/// close as possible to its current location"* (`CGDisplayConfiguration.h:45-47`,
/// arrangement research §4.2). Naming one display and leaving the rest implicit
/// hands the rest to a heuristic, and the user never touched them.
///
/// **AR6:** mirror slaves get no tile, so they get no change. Setting the origin
/// of a display that is mirroring another *removes it from the mirror set*
/// (`CGDisplayConfiguration.h:49-50`), which is a silent, unrequested topology
/// change. `ArrangementTile.mirroredIDs` names them; `init` REFUSES an
/// arrangement in which a mirror slave also holds a tile, rather than quietly
/// dropping it — dropping it would produce exactly the partial plan above.
public struct ArrangementPlan: Sendable, Equatable {
  /// The layout being asked for, in display space.
  public let arrangement: DisplayArrangement

  public var changes: [DisplayOriginChange] {
    arrangement.tiles.map { DisplayOriginChange(id: $0.id, origin: $0.rect.origin) }
  }

  /// The display this layout puts at (0,0), which is what MAKES it main — there
  /// is no `CGSetMainDisplay` (arrangement research §3). `nil` when no tile sits
  /// at the origin, which is a layout macOS will re-anchor on a display of its
  /// own choosing; see `relativeLayout` for why that is compared for rather than
  /// forbidden.
  public var requestedMain: CGDirectDisplayID? { arrangement.mainDisplayID }

  /// Whether the achieved origins are allowed to differ from the requested ones.
  ///
  /// macOS adjusts a requested layout *"to remove gaps or overlaps"*
  /// (`CGDisplayConfiguration.h:25-26`) — so for a layout that has neither,
  /// there is nothing left for it to adjust, and a difference in the achieved
  /// relative layout is the platform not honouring the request (#53). For a
  /// layout that does have gaps or overlaps — a saved layout restored against
  /// displays that have since changed resolution — the adjustment is the
  /// documented behaviour, and `ArrangementOutcomePolicy` reports it as a
  /// notice instead.
  ///
  /// This is the whole reason the gate lives on the plan: it keeps the decision
  /// in a pure type, so `CoreGraphicsArrangementConfigurator` has none to make.
  public var expectsExactOrigins: Bool { ArrangementRules.isValid(arrangement) }

  /// `nil` when there is nothing to apply, or when the request cannot be
  /// applied as a whole:
  ///
  /// - **A no-op.** `arrangement == baseline` — every tile already sits where it
  ///   is being asked to sit. Equality is exact and NOT up to translation, on
  ///   purpose: "make this display main" is a pure translation of the whole
  ///   arrangement (`makingMain`) and is one of the most consequential changes
  ///   this feature makes, since the menu bar and Dock follow it.
  /// - **A different display set.** The baseline is what was on screen when the
  ///   gesture started; if a display has arrived or left since, the plan
  ///   describes a machine that no longer exists, and applying it would leave
  ///   the newcomer's origin unset (§4.2 again).
  /// - **A mirror slave holding a tile** (AR6, above).
  /// - **An origin outside `Int32`.** `CGConfigureDisplayOrigin` takes
  ///   `int32_t`, so an origin that does not fit is not a request that can be
  ///   made at all.
  public init?(applying arrangement: DisplayArrangement, to baseline: DisplayArrangement) {
    guard arrangement != baseline else { return nil }
    guard Set(arrangement.tiles.map(\.id)) == Set(baseline.tiles.map(\.id)) else { return nil }

    let mirrored = Set(arrangement.tiles.flatMap(\.mirroredIDs))
    guard !arrangement.tiles.contains(where: { mirrored.contains($0.id) }) else { return nil }

    let fits = arrangement.tiles.allSatisfy {
      Int32(exactly: $0.rect.x) != nil && Int32(exactly: $0.rect.y) != nil
    }
    guard fits else { return nil }

    self.arrangement = arrangement
  }
}

/// The same layout with its bounding box at the origin.
///
/// Two arrangements have the same `relativeLayout` **iff** one is a translation
/// of the other, which is the only comparison worth making about a layout:
/// macOS re-anchors the global space on whichever display ends up at (0,0)
/// (arrangement research §2.2), so absolute origins shift for a layout in which
/// nothing physically moved. §2.3 states the rule directly — *"Do not diff
/// layouts on absolute origins… normalizing to a canonical anchor first"*.
///
/// The anchor is the bounding box's minimum corner rather than the main display,
/// which §6.3 of the canvas design suggested, because a layout need not have a
/// tile at the origin at all (drag the origin display away from it and none
/// does) and `makingMain` returns the arrangement UNCHANGED for an id it does
/// not hold — so a main-anchored normalisation silently degrades to an absolute
/// comparison in exactly the case where the system did something unexpected.
/// Both anchors are translation-equivariant, so wherever both are defined they
/// answer identically.
extension DisplayArrangement {
  var relativeLayout: DisplayArrangement {
    let bounds = bounds
    return translated(dx: -bounds.x, dy: -bounds.y)
  }
}

/// The seam between arrangement policy and the display-configuration APIs.
/// Everything decidable is tested against `FakeArrangementConfigurator`; the
/// real conformance is a thin adapter with no judgement in it.
public protocol DisplayArrangementConfiguring: Sendable {
  /// The layout ON SCREEN now. Mirror slaves are folded into their master's
  /// `mirroredIDs` and get no tile of their own (AR6).
  func currentArrangement() -> DisplayArrangement

  /// Stages every change in the plan in ONE transaction, commits it, re-reads
  /// the result, and returns **what is on screen now** — never what was asked
  /// for. The return value is not discardable for that reason: macOS adjusts a
  /// requested layout silently, so a caller that assumed its request stands
  /// would be recording a layout the machine may not be in.
  ///
  /// Throws `DisplayConfigError` if the transaction cannot be begun, if any
  /// origin fails to STAGE, if the completion fails, or if the achieved layout
  /// is not the requested one on a plan that `expectsExactOrigins`.
  ///
  /// **That last throw is the one that can follow a committed change** — the
  /// same contract as `DisplayConfiguring.applyMirroring`, for the same reason:
  /// CoreGraphics accepted the transaction and did something else, and nothing
  /// here puts the machine back. Recovery is a retry computed from a live
  /// sample, never a replay of the plan that diverged.
  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement
}

/// The post-commit check every `DisplayArrangementConfiguring` owes its callers,
/// factored out so the real configurator and its test double are held to the
/// same rule.
///
/// **`CGCompleteDisplayConfiguration` returning `.success` is not evidence the
/// request was honoured** — measured twice on the mirroring hardware pass with
/// every stage AND the complete returning `.success` (#53,
/// `docs/spikes/2026-08-04-mirroring-hardware-pass.md` §6.2). `MirrorVerification`
/// is this rule for a topology; `CoreGraphicsDisplayConfigurator.apply` is it for
/// a mode. This is the third member of that family.
enum ArrangementVerification {
  /// The first change in the plan the achieved layout does not show, or `nil`
  /// when the layout stands.
  ///
  /// Compared on the RELATIVE layout: every successful apply comes back
  /// translated, because the space re-anchors on whichever display ended up at
  /// (0,0). Comparing absolute origins would report every apply as a failure.
  static func unhonoured(plan: ArrangementPlan, achieved: DisplayArrangement) -> DisplayOriginChange? {
    // A plan with gaps or overlaps ASKED macOS to adjust it (§4.1), so a
    // difference here is the documented behaviour rather than a divergence.
    // `ArrangementOutcomePolicy` reports that case; this one is for the
    // platform ignoring a request it had nothing to correct.
    guard plan.expectsExactOrigins else { return nil }

    let requested = plan.arrangement.relativeLayout
    // Restricted to the planned displays before normalising: a display that
    // arrived between the commit and the read-back would otherwise move the
    // achieved bounding box and mark every change unhonoured at once.
    let plannedIDs = Set(plan.changes.map(\.id))
    let achieved = DisplayArrangement(
      tiles: achieved.tiles.filter { plannedIDs.contains($0.id) }
    ).relativeLayout

    return plan.changes.first { change in
      guard let landed = achieved.tile(change.id) else { return true }
      return landed.rect.origin != requested.tile(change.id)?.rect.origin
    }
  }
}

/// What the system did that the request did not ask for. Read AFTER the apply,
/// from what is on screen — macOS adjusts a requested layout silently, so the
/// only trustworthy account of a layout change is the one read back.
public enum ArrangementApplyNotice: Sendable, Equatable {
  /// The system moved something. Carries the layout that is on screen NOW, not
  /// the one that was asked for.
  case adjusted(DisplayArrangement)
  /// The requested main display is not at the origin, so the menu bar did not
  /// move. Carries the display that was asked for. Expected when the target is
  /// a mirror slave, among other refusals the API does not report.
  case mainDisplayUnchanged(CGDirectDisplayID)
}

public enum ArrangementOutcomePolicy {
  /// Notices in decreasing order of scope: the layout first, then the main
  /// display, so a caller showing only the first shows the bigger fact.
  ///
  /// **A pure translation is not an adjustment.** The global space re-anchors on
  /// whichever display ends up at (0,0) (§2.2), so *every* successful apply
  /// comes back translated — a `.adjusted` notice on that would fire on every
  /// apply the feature ever makes, and a warning that always fires is read as
  /// noise the first time it means something. The two facts are separated
  /// exactly as §2.3 prescribes: compare the relative layout, and compare the
  /// main display's identity on its own.
  ///
  /// `requestedMain` is optional because `ArrangementPlan.requestedMain` is: a
  /// layout need not put any tile at the origin (drag the origin display away
  /// and none does), and `.mainDisplayUnchanged` has to NAME the display that
  /// was asked for. With nothing asked for there is nothing to report, so the
  /// main-display comparison is skipped rather than answered against a guess —
  /// the layout comparison below still runs, and it is the one that carries the
  /// bigger fact.
  public static func notices(
    requested: DisplayArrangement,
    resulting: DisplayArrangement,
    requestedMain: CGDirectDisplayID?
  ) -> [ArrangementApplyNotice] {
    var notices: [ArrangementApplyNotice] = []
    if requested.relativeLayout != resulting.relativeLayout {
      notices.append(.adjusted(resulting))
    }
    if let requestedMain, resulting.mainDisplayID != requestedMain {
      notices.append(.mainDisplayUnchanged(requestedMain))
    }
    return notices
  }
}
