import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Saved layouts, and the refusal that is the shipped answer to the twin case
/// (AR11). Every rule here runs unattended, so each one is pinned rather than
/// left to its single call site.
@Suite("Arrangement persistence (#13)")
struct ArrangementPersistenceTests {
  /// A tile whose IDENTITY is stated independently of its display ID — the
  /// distinction the whole suite is about. `ArrangementFixtures.tile` derives
  /// identity FROM the id, which cannot express either a replug or a twin.
  private func tile(
    id: CGDirectDisplayID, identity: String, _ rect: DisplayRect,
    mirroredIDs: [CGDirectDisplayID] = []
  ) -> ArrangementTile {
    ArrangementTile(
      id: id,
      identity: identity == "builtIn"
        ? DisplayConfigIdentity(vendor: 0, model: 0, serial: 0, isBuiltIn: true)
        : Self.identity(named: identity),
      name: "Display \(id)",
      rect: rect,
      mirroredIDs: mirroredIDs
    )
  }

  /// Two panels whose `DisplayConfigIdentity` differs, named by hand so a test
  /// can hand the same identity to two different display IDs.
  private static func identity(named name: String) -> DisplayConfigIdentity {
    switch name {
    case "mag": DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    case "dell": DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    default: DisplayConfigIdentity(vendor: 0xDEAD, model: 0xBEEF, serial: 0, isBuiltIn: false)
    }
  }

  private static let magKey = identity(named: "mag").key
  private static let dellKey = identity(named: "dell").key

  private var left: DisplayRect { DisplayRect(x: 0, y: 0, width: 1920, height: 1080) }
  private var right: DisplayRect { DisplayRect(x: 1920, y: 0, width: 1920, height: 1080) }

  /// The MAG at the origin, the Dell to its right.
  private var deskLayout: DisplayArrangement {
    DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", left),
      tile(id: 2, identity: "dell", right),
    ])
  }

  // MARK: - Keying

  /// The key is the sorted identity set, never the display IDs — and "sorted"
  /// is load-bearing: `CGGetOnlineDisplayList`'s order is not documented as
  /// stable, so an enumeration-ordered key would file the same machine under
  /// two names.
  @Test func aLayoutIsKeyedByTheSortedIdentitySetNotByDisplayID() {
    let oneOrder = TopologySignature(deskLayout)
    let otherOrder = TopologySignature(DisplayArrangement(tiles: [
      tile(id: 90, identity: "dell", right),
      tile(id: 91, identity: "mag", left),
    ]))
    #expect(oneOrder == otherOrder)
    #expect(oneOrder.key == [Self.dellKey, Self.magKey].sorted().joined(separator: "+"))
    // Nothing in the key mentions 3 or 2.
    #expect(!oneOrder.key.contains("3+"))
  }

  /// The measured failure this keying exists for: the MAG went 3→2 and the Dell
  /// 2→3 across one dock cycle. A layout keyed on `CGDirectDisplayID` would
  /// restore each display to the other one's position.
  @Test func aLayoutSurvivesDisplayIDReassignment() throws {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)

    // Same two panels, IDs swapped.
    let afterReplug = DisplayArrangement(tiles: [
      tile(id: 2, identity: "mag", right),
      tile(id: 3, identity: "dell", left),
    ])
    let saved = try #require(store.savedArrangement(for: TopologySignature(afterReplug)))
    guard case let .exact(restored) = ArrangementPersistence.resolve(saved, against: afterReplug)
    else {
      Issue.record("a replugged pair should still match its saved layout")
      return
    }
    // The MAG goes back to the origin whatever ID it now holds.
    #expect(restored.tile(2)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(restored.tile(3)?.rect.origin == DisplayPoint(x: 1920, y: 0))
  }

  @Test func aLayoutForADifferentDisplaySetDoesNotMatch() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)

    let laptopOnly = DisplayArrangement(tiles: [tile(id: 1, identity: "builtIn", left)])
    #expect(store.savedArrangement(for: TopologySignature(laptopOnly)) == nil)
  }

  /// A subset is not a smaller layout, it is a different one: every absent
  /// display's slot would be filled by CoreGraphics' gap-removal, producing an
  /// arrangement nobody chose.
  @Test func aStoredLayoutIsNotAppliedToASubsetOrASuperset() {
    let saved = SavedArrangement(deskLayout)
    let magOnly = DisplayArrangement(tiles: [tile(id: 3, identity: "mag", left)])
    #expect(ArrangementPersistence.resolve(saved, against: magOnly)
      == .setDiffers(missing: [Self.dellKey], extra: []))

    let plusLaptop = DisplayArrangement(tiles: deskLayout.tiles + [
      tile(id: 1, identity: "builtIn", DisplayRect(x: 0, y: 1080, width: 1440, height: 900)),
    ])
    #expect(ArrangementPersistence.resolve(saved, against: plusLaptop)
      == .setDiffers(missing: [], extra: ["builtIn"]))
  }

  /// Compared as a MULTISET. A set comparison would accept a layout naming two
  /// identical panels against a machine holding one, then resolve both entries
  /// onto the same display and leave the layout half-described.
  @Test func aLayoutNamingTwoIdenticalPanelsDoesNotMatchOne() {
    let twins = SavedArrangement(entries: [
      SavedArrangementEntry(identity: Self.magKey, x: 0, y: 0, width: 1920, height: 1080),
      SavedArrangementEntry(identity: Self.magKey, x: 1920, y: 0, width: 1920, height: 1080),
    ])
    let one = DisplayArrangement(tiles: [tile(id: 3, identity: "mag", left)])
    #expect(ArrangementPersistence.resolve(twins, against: one)
      == .setDiffers(missing: [Self.magKey], extra: []))
  }

  // MARK: - AR11

  /// **AR11.** Two attached displays share an identity — a MAG 341C reports
  /// serial 0, so an identical unit collides with it, and two identical monitors
  /// side by side is the most common multi-monitor setup there is. Nothing in
  /// the layout says which is which, and a coin flip that swaps the user's
  /// screens is worse than not restoring.
  @Test func aLayoutNamingAnIdentitySharedByTwoAttachedDisplaysIsRefused() {
    let saved = SavedArrangement(entries: [
      SavedArrangementEntry(identity: Self.magKey, x: 0, y: 0, width: 1920, height: 1080),
      SavedArrangementEntry(identity: Self.magKey, x: 1920, y: 0, width: 1920, height: 1080),
    ])
    let attachedTwins = DisplayArrangement(tiles: [
      tile(id: 2, identity: "mag", left),
      tile(id: 3, identity: "mag", right),
    ])

    let match = ArrangementPersistence.resolve(saved, against: attachedTwins)
    #expect(match == .ambiguous([Self.magKey]))
    // Specifically NOT a layout: no branch may produce one here.
    if case .exact = match { Issue.record("a twin collision must never resolve to a layout") }
  }

  /// The refusal has to NAME the collision, because the user's only remedy is
  /// outside the app — unplug one, or tell the two apart some other way. "Could
  /// not restore" with nothing else in it is a sentence nobody can act on.
  @Test func aRefusedRestoreReportsWhy() {
    let saved = SavedArrangement(entries: [
      SavedArrangementEntry(identity: Self.magKey, x: 0, y: 0, width: 1920, height: 1080),
      SavedArrangementEntry(identity: Self.dellKey, x: 1920, y: 0, width: 1920, height: 1080),
    ])
    // The DELL is the twinned one here, so the report must name the Dell's key
    // and not merely "something collided".
    let attached = DisplayArrangement(tiles: [
      tile(id: 2, identity: "mag", left),
      tile(id: 3, identity: "dell", right),
      tile(id: 4, identity: "dell", DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementPersistence.resolve(saved, against: attached) == .ambiguous([Self.dellKey]))
  }

  /// Only identities the LAYOUT names. An attached pair of twins the layout says
  /// nothing about is a set difference — a different sentence with a different
  /// remedy, and reporting it as a collision would send the user looking for a
  /// problem they do not have.
  @Test func aTwinTheLayoutDoesNotNameIsASetDifferenceNotACollision() {
    let saved = SavedArrangement(entries: [
      SavedArrangementEntry(identity: Self.magKey, x: 0, y: 0, width: 1920, height: 1080),
    ])
    let attached = DisplayArrangement(tiles: [
      tile(id: 2, identity: "mag", left),
      tile(id: 3, identity: "dell", right),
      tile(id: 4, identity: "dell", DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementPersistence.resolve(saved, against: attached)
      == .setDiffers(missing: [], extra: [Self.dellKey]))
  }

  // MARK: - Storage

  @Test func savedLayoutsRoundTripThroughJSON() throws {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    let signature = TopologySignature(deskLayout)
    #expect(store.savedArrangement(for: signature) == nil)

    store.save(deskLayout)
    let saved = try #require(store.savedArrangement(for: signature))
    #expect(saved.version == SavedArrangement.currentVersion)
    #expect(saved.entries.count == 2)
    #expect(saved == SavedArrangement(deskLayout))

    guard case let .exact(restored) = ArrangementPersistence.resolve(saved, against: deskLayout)
    else {
      Issue.record("a layout must resolve against the very machine it was read from")
      return
    }
    #expect(restored == deskLayout)
  }

  /// The keys are an on-disk format. Synthesized `CodingKeys` track the property
  /// names, so a rename would silently orphan every stored layout.
  @Test func theStoredJSONKeysArePinned() throws {
    let data = try JSONEncoder().encode(SavedArrangement(deskLayout))
    let object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["version"] as? Int == 1)
    let entries = try #require(object["entries"] as? [[String: Any]])
    #expect(Set(entries[0].keys) == ["identity", "x", "y", "width", "height"])
  }

  /// A descriptor a newer build wrote is not a layout this one can half-apply.
  @Test func aLayoutFromANewerSchemaIsNotRestored() {
    let defaults = InMemoryDefaults()
    let store = ArrangementPersistence(defaults: defaults)
    let signature = TopologySignature(deskLayout)
    let future = SavedArrangement(
      version: SavedArrangement.currentVersion + 1, entries: SavedArrangement(deskLayout).entries
    )
    defaults.set(try? JSONEncoder().encode(future), forKey: "savedArrangements.\(signature.key)")
    #expect(store.savedArrangement(for: signature) == nil)
  }

  @Test func corruptDataReadsAsNothingStored() {
    let defaults = InMemoryDefaults()
    let store = ArrangementPersistence(defaults: defaults)
    let signature = TopologySignature(deskLayout)
    defaults.set(Data([0x00, 0x01, 0x02]), forKey: "savedArrangements.\(signature.key)")
    #expect(store.savedArrangement(for: signature) == nil)
  }

  /// One stored value per SET, not per display — the one structural departure
  /// from `ModePersistence`, pinned so nobody folds it back.
  @Test func twoTopologiesDoNotShareALayout() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)
    let laptopOnly = DisplayArrangement(tiles: [tile(id: 1, identity: "builtIn", left)])
    store.save(laptopOnly)

    #expect(store.savedArrangement(for: TopologySignature(deskLayout))?.entries.count == 2)
    #expect(store.savedArrangement(for: TopologySignature(laptopOnly))?.entries.count == 1)
  }

  /// The opt-in is off until someone says otherwise, and it is app-level: it
  /// survives a layout being cleared, for `ModePersistence.clear`'s reason.
  @Test func clearingALayoutLeavesTheOptInAlone() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    #expect(!store.isRestoreEnabled)
    store.setRestoreEnabled(true)
    store.save(deskLayout)

    store.clear(for: TopologySignature(deskLayout))
    #expect(store.savedArrangement(for: TopologySignature(deskLayout)) == nil)
    #expect(store.isRestoreEnabled)
  }

  /// An empty read is not a topology. Storing under it would file every
  /// unreadable moment under one key and hand it back to the next machine.
  @Test func anEmptyArrangementIsNeverStored() {
    let defaults = InMemoryDefaults()
    let store = ArrangementPersistence(defaults: defaults)
    let empty = DisplayArrangement(tiles: [])
    #expect(TopologySignature(empty).isEmpty)

    store.save(empty)
    #expect(defaults.data(forKey: "savedArrangements.") == nil)
    #expect(store.savedArrangement(for: TopologySignature(empty)) == nil)
  }

  /// AR6: a mirror slave has no position of its own, so it is not part of the
  /// set a layout is about. Plugging a display into a mirror set must not
  /// orphan the layout for the displays that can still be arranged.
  @Test func aMirrorSlaveDoesNotChangeTheTopologySignature() {
    // The slave holds no tile — that is what `ArrangementSnapshot` produces —
    // and is recorded on its master instead.
    let mirrored = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", left, mirroredIDs: [9]),
      tile(id: 2, identity: "dell", right),
    ])
    #expect(TopologySignature(mirrored) == TopologySignature(deskLayout))
  }

  // MARK: - Geometry

  /// §7.4: the recorded size is validation, never authority. A display that has
  /// changed resolution since the layout was captured is a different size now,
  /// and re-imposing the recorded one would describe a screen that does not
  /// exist.
  @Test func theStoredSizeIsNotAuthorityOverTheCurrentFootprint() {
    let saved = SavedArrangement(deskLayout)
    let magIsNowUltrawide = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
      tile(id: 2, identity: "dell", DisplayRect(x: 3440, y: 0, width: 1920, height: 1080)),
    ])
    guard case let .exact(restored) = ArrangementPersistence.resolve(
      saved, against: magIsNowUltrawide
    ) else {
      Issue.record("a resolution change is not a set change")
      return
    }
    #expect(restored.tile(3)?.rect == DisplayRect(x: 0, y: 0, width: 3440, height: 1440))
    // The stored origin still applies, gaps and all — the apply path reads back
    // what macOS did with it rather than pretending here.
    #expect(restored.tile(2)?.rect == DisplayRect(x: 1920, y: 0, width: 1920, height: 1080))
  }

  /// AR5: the display at (0, 0) is the one holding the menu bar, so origins are
  /// stored exactly as read. Normalising them would lose which display that is.
  @Test func theMainDisplayIsPreservedThroughAStoredLayout() {
    let mainOnDell = deskLayout.makingMain(2)
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(mainOnDell)

    guard let saved = store.savedArrangement(for: TopologySignature(mainOnDell)),
          case let .exact(restored) = ArrangementPersistence.resolve(saved, against: deskLayout)
    else {
      Issue.record("a saved layout should resolve against its own topology")
      return
    }
    #expect(restored.mainDisplayID == 2)
  }

  /// AR4 on the read side: a resolved layout names every attached tile, so the
  /// plan built from it cannot leave a display's origin unset.
  @Test func aResolvedLayoutNamesEveryAttachedDisplay() {
    let saved = SavedArrangement(deskLayout)
    guard case let .exact(restored) = ArrangementPersistence.resolve(saved, against: deskLayout)
    else {
      Issue.record("expected an exact match")
      return
    }
    #expect(Set(restored.tiles.map(\.id)) == Set(deskLayout.tiles.map(\.id)))
    #expect(ArrangementPlan(applying: restored.moving(2, to: DisplayPoint(x: 1920, y: 200)),
                            to: deskLayout) != nil)
  }

  @Test func anEmptyStoredLayoutIsNothingToRestore() {
    #expect(ArrangementPersistence.resolve(
      SavedArrangement(entries: []), against: deskLayout
    ) == .none)
  }

  // MARK: - Propagation (D27)

  /// Writing the opt-in must not yank anyone's screens, for the identical reason
  /// `rememberDisplayMode` does not (DM7) — and here the stakes are higher,
  /// because the menu bar follows whichever display ends up at the origin.
  @Test func restoreArrangementPropagatesToRefreshUIOnly() {
    #expect(PrefPropagation.effects(forChange: .restoreArrangement) == [.refreshUI])
    #expect(PrefPropagation.effects(forChange: .savedArrangements) == [.refreshUI])
  }
}
