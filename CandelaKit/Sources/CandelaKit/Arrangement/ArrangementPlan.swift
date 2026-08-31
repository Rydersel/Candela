import CoreGraphics
import Foundation

/// One display's requested origin. A struct rather than a tuple so a whole change
/// list is `Equatable`, the same reason `MirrorChange` is one.
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
/// `DisplayArrangement` and derives `changes` from its tiles, so no initialiser takes
/// a change list and a partial plan is unrepresentable. CoreGraphics repositions any
/// display whose origin is not explicitly set (`CGDisplayConfiguration.h`,
/// arrangement research §4.2), so naming one display hands the rest to a heuristic.
///
/// **AR6:** mirror slaves get no tile, so they get no change. Setting the origin of a
/// display that is mirroring another *removes it from the mirror set*
/// (`CGDisplayConfiguration.h`), a silent unrequested topology change. `init` REFUSES
/// an arrangement where a mirror slave also holds a tile rather than dropping it,
/// because dropping it produces the partial plan above.
public struct ArrangementPlan: Sendable, Equatable {
  /// The layout being asked for, in display space.
  public let arrangement: DisplayArrangement

  public var changes: [DisplayOriginChange] {
    arrangement.tiles.map { DisplayOriginChange(id: $0.id, origin: $0.rect.origin) }
  }

  /// The display this layout puts at (0,0), which is what MAKES it main: there is no
  /// `CGSetMainDisplay` (arrangement research §3). `nil` when no tile sits at the
  /// origin, a layout macOS re-anchors on a display of its own choosing.
  public var requestedMain: CGDirectDisplayID? { arrangement.mainDisplayID }

  /// Whether the achieved origins are allowed to differ from the requested ones.
  ///
  /// macOS adjusts a requested layout *"to remove gaps or overlaps"*
  /// (`CGDisplayConfiguration.h`), so for a layout with neither there is nothing left
  /// to adjust and a difference in the achieved relative layout is the platform
  /// accepting and ignoring the request. A layout that does have gaps or overlaps gets
  /// the documented adjustment, and `ArrangementOutcomePolicy` reports it as a notice.
  ///
  /// The gate lives on the plan so the decision stays in a pure type and
  /// `CoreGraphicsArrangementConfigurator` has none to make.
  ///
  /// **No production call site can make it `false`** [audited 2026-08-05]: all three
  /// plan-building sites refuse an invalid layout before a plan exists. Kept because a
  /// blanket throw instead would make `.adjusted` unreportable the moment a caller
  /// does need the documented gap/overlap adjustment. Do not describe it as the live
  /// path: a reader who believes the post-commit check is routinely off will reason
  /// wrongly about accept-and-ignore.
  public var expectsExactOrigins: Bool { ArrangementRules.isValid(arrangement) }

  /// `nil` when there is nothing to apply, or when the request cannot be
  /// applied as a whole:
  ///
  /// - **A no-op.** The ANCHORED arrangement equals the baseline. Comparing the
  ///   anchored form changes one family of cases: an unanchored pure translation
  ///   moves nothing relative to anything and is a no-op, while `makingMain` puts a
  ///   DIFFERENT tile at (0,0) and is still a plan, since the menu bar follows it.
  /// - **A layout that cannot be anchored.** CG's global space is defined with the
  ///   main display at (0,0). Measured live (2026-08-07): staging a non-zero origin
  ///   for the main display is silently dropped, every stage and the complete return
  ///   `.success`, and nothing moves. `anchored(preservingMainOf:)` re-expresses such
  ///   a layout on the baseline's main; only a baseline with no main either is refused.
  /// - **A different display set.** The baseline is what was on screen when the
  ///   gesture started, so applying it after an arrival or departure would leave the
  ///   newcomer's origin unset (§4.2 again).
  /// - **A mirror slave holding a tile** (AR6, above).
  /// - **An origin outside `Int32`.** `CGConfigureDisplayOrigin` takes `int32_t`.
  ///   Checked on the anchored form, since those are the origins actually staged.
  public init?(applying arrangement: DisplayArrangement, to baseline: DisplayArrangement) {
    guard Set(arrangement.tiles.map(\.id)) == Set(baseline.tiles.map(\.id)) else { return nil }
    guard let anchored = arrangement.anchored(preservingMainOf: baseline) else { return nil }
    guard anchored != baseline else { return nil }

    let mirrored = Set(anchored.tiles.flatMap(\.mirroredIDs))
    guard !anchored.tiles.contains(where: { mirrored.contains($0.id) }) else { return nil }

    let fits = anchored.tiles.allSatisfy {
      Int32(exactly: $0.rect.x) != nil && Int32(exactly: $0.rect.y) != nil
    }
    guard fits else { return nil }

    self.arrangement = anchored
  }
}

extension DisplayArrangement {
  /// The same layout, expressed in coordinates CoreGraphics can honour.
  ///
  /// The display space is anchored on the main display: the tile at (0,0) IS main
  /// (AR5), and a request that puts no tile there is one CG accepts and ignores (see
  /// `ArrangementPlan.init`). A layout with no main, which is what moving the main
  /// display's own tile produces, is translated so the BASELINE's main returns to
  /// (0,0): moving the main display does not change which display is main, so the move
  /// is every other display shifting by the inverse delta. `nil` when the baseline has
  /// no main either, which nothing can anchor.
  public func anchored(preservingMainOf baseline: DisplayArrangement) -> DisplayArrangement? {
    if mainDisplayID != nil { return self }
    guard let main = baseline.mainDisplayID, let anchor = tile(main) else { return nil }
    return translated(dx: -anchor.rect.x, dy: -anchor.rect.y)
  }
}

/// The same layout with its bounding box at the origin.
///
/// Two arrangements have the same `relativeLayout` **iff** one is a translation of
/// the other, which is the only comparison worth making: macOS re-anchors the global
/// space on whichever display ends up at (0,0) (arrangement research §2.2), so
/// absolute origins shift for a layout in which nothing physically moved.
///
/// The anchor is the bounding box's minimum corner rather than the main display,
/// because a layout need not have a tile at the origin and `makingMain` returns the
/// arrangement UNCHANGED for an id it does not hold. A main-anchored normalisation
/// would degrade to an absolute comparison in exactly the case where the system did
/// something unexpected. Both anchors are translation-equivariant.
extension DisplayArrangement {
  var relativeLayout: DisplayArrangement {
    let bounds = bounds
    return translated(dx: -bounds.x, dy: -bounds.y)
  }
}

/// The seam between arrangement policy and the display-configuration APIs. The real
/// conformance is a thin adapter with no judgement in it.
public protocol DisplayArrangementConfiguring: Sendable {
  /// The layout ON SCREEN now. Mirror slaves are folded into their master's
  /// `mirroredIDs` and get no tile of their own (AR6).
  func currentArrangement() -> DisplayArrangement

  /// The layout AND the online display list it was derived from, from ONE
  /// enumeration.
  ///
  /// One call rather than two, because the restore path compares them:
  /// `ArrangementSnapshot` skips a display whose bounds are unreadable, so an online
  /// display with no tile is the AR4-on-the-read-side case the reapply policy defers
  /// on. Two questions a moment apart would let an arrival look exactly like that,
  /// and a departure look like nothing at all.
  func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement)

  /// Stages every change in ONE transaction, commits, re-reads, and returns **what is
  /// on screen now**, never what was asked for. Not discardable for that reason: macOS
  /// adjusts a requested layout silently, so a caller assuming its request stands
  /// records a layout the machine may not be in.
  ///
  /// Throws `DisplayConfigError` if the transaction cannot be begun, if any origin
  /// fails to STAGE, if the completion fails, or if the achieved layout is not the
  /// requested one on a plan that `expectsExactOrigins`.
  ///
  /// **That last throw follows a COMMITTED change**, the same contract as
  /// `DisplayConfiguring.applyMirroring`: CoreGraphics accepted the transaction and
  /// did something else, and nothing here puts the machine back. Recovery is a retry
  /// computed from a live sample, never a replay of the plan that diverged.
  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement
}

/// The post-commit check every `DisplayArrangementConfiguring` owes its callers,
/// factored out so the real configurator and its test double are held to the
/// same rule.
///
/// **`CGCompleteDisplayConfiguration` returning `.success` is not evidence the
/// request was honoured**: measured twice on the mirroring hardware pass with every
/// stage AND the complete returning `.success`
/// (`docs/spikes/2026-08-04-mirroring-hardware-pass.md` §6.2). `MirrorVerification`
/// is this rule for a topology, `CoreGraphicsDisplayConfigurator.apply` for a mode.
enum ArrangementVerification {
  /// The first change in the plan the achieved layout does not show, or `nil`
  /// when the layout stands.
  ///
  /// Compared on the RELATIVE layout: every successful apply comes back translated,
  /// because the space re-anchors on whichever display ended up at (0,0).
  static func unhonoured(plan: ArrangementPlan, achieved: DisplayArrangement) -> DisplayOriginChange? {
    // A plan with gaps or overlaps ASKED macOS to adjust it (§4.1), which
    // `ArrangementOutcomePolicy` reports. This is for the platform ignoring a request
    // it had nothing to correct.
    guard plan.expectsExactOrigins else { return nil }

    let requested = plan.arrangement.relativeLayout
    // Restricted to the planned displays before normalising: a display arriving
    // between commit and read-back would move the achieved bounding box and mark
    // every change unhonoured at once.
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

/// What the system did that the request did not ask for. Read AFTER the apply, from
/// what is on screen: macOS adjusts a layout silently, so the only trustworthy
/// account is the one read back.
public enum ArrangementApplyNotice: Sendable, Equatable {
  /// The system moved something. Carries the layout on screen NOW, not the one asked
  /// for.
  ///
  /// **The case it was designed for is unreachable in production** [audited
  /// 2026-08-05]: it exists for macOS' documented gap/overlap adjustment, which only
  /// reaches a plan that does not `expectExactOrigins`, and no production path builds
  /// one.
  ///
  /// What stays reachable is narrower: the verification compares origins and this
  /// compares whole tiles, so a display whose FOOTPRINT changed between commit and
  /// read-back still lands here. Do not read this as "macOS rearranged your displays"
  /// without checking which of the two produced it.
  case adjusted(DisplayArrangement)
  /// The requested main display is not at the origin, so the menu bar did not move.
  /// Expected when the target is a mirror slave, among other refusals the API does
  /// not report.
  case mainDisplayUnchanged(CGDirectDisplayID)
}

public enum ArrangementOutcomePolicy {
  /// Notices in decreasing order of scope, so a caller showing only the first shows
  /// the bigger fact.
  ///
  /// **A pure translation is not an adjustment.** The global space re-anchors on
  /// whichever display ends up at (0,0) (§2.2), so *every* successful apply comes back
  /// translated, and an `.adjusted` notice on that would fire every time. Compare the
  /// relative layout, and compare the main display's identity on its own (§2.3).
  ///
  /// `requestedMain` is optional because a layout need not put any tile at the origin.
  /// With nothing asked for, the main-display comparison is skipped rather than
  /// answered against a guess.
  public static func notices(
    requested: DisplayArrangement,
    resulting: DisplayArrangement,
    requestedMain: CGDirectDisplayID?
  ) -> [ArrangementApplyNotice] {
    var notices: [ArrangementApplyNotice] = []
    // Restricted to the REQUESTED displays before normalising, as
    // `ArrangementVerification.unhonoured` does. A display arriving between commit and
    // read-back, or one whose `CGDisplayBounds` was momentarily unreadable at `begin`,
    // moves the achieved bounding box, so every requested tile normalises to a
    // different point and a layout nothing touched compares unequal. Unfiltered, this
    // reported `.adjusted` where verification passed, and the confirmation card told
    // the user macOS had rearranged their displays about a change macOS had honoured.
    //
    // The MAIN-display comparison below is deliberately NOT filtered: if a newcomer
    // took the origin, the menu bar genuinely is not on the display that was asked
    // for.
    let requestedIDs = Set(requested.tiles.map(\.id))
    let compared = DisplayArrangement(
      tiles: resulting.tiles.filter { requestedIDs.contains($0.id) }
    )
    if requested.relativeLayout != compared.relativeLayout {
      // The FULL layout on screen, not the restriction: the caller reconciles against
      // the machine, not against the part of it we planned.
      notices.append(.adjusted(resulting))
    }
    if let requestedMain, resulting.mainDisplayID != requestedMain {
      notices.append(.mainDisplayUnchanged(requestedMain))
    }
    return notices
  }
}
