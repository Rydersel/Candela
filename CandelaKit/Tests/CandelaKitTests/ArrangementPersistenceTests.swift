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

  /// The ONLINE-list spelling of the same displays: `TopologySignature(online:)`
  /// reads `ConfiguredDisplay`s straight off the enumeration, before anything
  /// turns them into tiles.
  private func online(
    id: CGDirectDisplayID, identity: String, mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: identity == "builtIn"
        ? DisplayConfigIdentity(vendor: 0, model: 0, serial: 0, isBuiltIn: true)
        : Self.identity(named: identity),
      name: "Display \(id)",
      isBuiltIn: identity == "builtIn",
      mirrorsDisplay: mirrors,
      isInMirrorSet: inSet
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

  // MARK: - Synthesis substitution (SS12)

  /// SS12: engaging a synthesized size must not orphan the saved layout. The
  /// synthesis VD signs as the panel it is standing in for, so the machine
  /// signs identically with the set engaged and without it.
  @Test func anEngagedSynthesisSetSignsAsThePhysicalPanel() {
    let unmirrored = [online(id: 1, identity: "builtIn"), online(id: 2, identity: "mag")]
    let engaged = [
      online(id: 1, identity: "builtIn"),
      online(id: 2, identity: "mag", mirrors: 5),
      online(id: 5, identity: "vd", inSet: true),
    ]
    let signature = TopologySignature(online: engaged, substituting: [5: Self.magKey])
    #expect(signature.key == TopologySignature(online: unmirrored).key)
    #expect(!signature.isEmpty)
    // One contribution for the pair, not two: the panel is named once.
    #expect(signature.key.components(separatedBy: "+").count == 2)
  }

  /// The control. Without the substitution the same sample signs under the
  /// virtual display, which is the orphaned layout SS12 exists to prevent, so
  /// the assertion above is about the mapping rather than about the fixture.
  @Test func withoutTheSubstitutionAnEngagedSetSignsUnderTheVirtualDisplay() {
    let engaged = [
      online(id: 2, identity: "mag", mirrors: 5),
      online(id: 5, identity: "vd", inSet: true),
    ]
    let plain = TopologySignature(online: engaged)
    #expect(plain.key != TopologySignature(online: [online(id: 2, identity: "mag")]).key)
    #expect(plain.key == Self.identity(named: "vd").key)
  }

  /// SS1 on the signature: the substitution is keyed on the pairing the engine
  /// publishes, so it does not depend on the VD master reporting the CG mirror
  /// flags. A slave the pairing says nothing about is still filtered (AR6).
  @Test func theSubstitutedSignatureDoesNotDependOnTheMirrorFlags() {
    let flagless = [
      online(id: 2, identity: "mag", mirrors: 5),
      online(id: 5, identity: "vd"),
    ]
    let reported = [
      online(id: 2, identity: "mag", mirrors: 5),
      online(id: 5, identity: "vd", inSet: true),
    ]
    #expect(
      TopologySignature(online: flagless, substituting: [5: Self.magKey])
        == TopologySignature(online: reported, substituting: [5: Self.magKey])
    )

    let userMirror = [
      online(id: 2, identity: "mag"),
      online(id: 3, identity: "dell", mirrors: 2),
    ]
    #expect(
      TopologySignature(online: userMirror, substituting: [5: Self.magKey]).key
        == Self.magKey
    )
  }

  /// The property SS12 is actually about, through the store: a layout saved
  /// before synthesis is engaged is still FOUND while it is engaged.
  @Test func aLayoutSavedBeforeSynthesisIsFoundWhileItIsEngaged() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)

    let engaged = [
      online(id: 3, identity: "mag", mirrors: 7),
      online(id: 7, identity: "vd", inSet: true),
      online(id: 2, identity: "dell"),
    ]
    let signature = TopologySignature(online: engaged, substituting: [7: Self.magKey])
    #expect(store.savedArrangement(for: signature)?.entries.count == 2)
  }

  /// Display IDs are reassigned across a replug, so a pairing can name an ID
  /// that is not attached now. It contributes nothing, and an empty map is the
  /// plain signature exactly.
  @Test func aSubstitutionNamingADisplayThatIsNotAttachedChangesNothing() {
    let attached = [online(id: 1, identity: "builtIn"), online(id: 2, identity: "mag")]
    #expect(
      TopologySignature(online: attached, substituting: [9: Self.dellKey])
        == TopologySignature(online: attached)
    )
    #expect(
      TopologySignature(online: attached, substituting: [:]) == TopologySignature(online: attached)
    )
  }

  /// The layout as the machine reads while a size stands: the virtual display
  /// holds the desktop and the panel is its slave, so the panel has no tile.
  private var engagedLayout: DisplayArrangement {
    DisplayArrangement(tiles: [
      tile(id: 7, identity: "vd", left, mirroredIDs: [3]),
      tile(id: 2, identity: "dell", right),
    ])
  }

  /// SS12 through the REAL save path, which is where the property has to hold:
  /// the layout is filed under the PANEL, so one store answers whether or not a
  /// size is engaged, and nothing on disk names a display that exists only
  /// while the size does.
  @Test func aLayoutSavedWhileASizeIsEngagedIsFiledUnderThePhysicalPanel() throws {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(engagedLayout, substituting: [7: Self.magKey])

    let saved = try #require(store.savedArrangement(for: TopologySignature(deskLayout)))
    #expect(saved.entries.map(\.identity).sorted() == [Self.dellKey, Self.magKey].sorted())
    #expect(!saved.entries.contains { $0.identity == Self.identity(named: "vd").key })
  }

  /// And end to end the other way, which is the case a user reaches without
  /// doing anything unusual: the layout was saved with no synthesized size, and
  /// it is found and resolved while one stands. The origin lands on the VIRTUAL
  /// display, which is the one that owns the desktop and the only member of the
  /// pair a plan can move.
  @Test func aLayoutSavedUnmirroredIsFoundAndResolvedWhileASizeIsEngaged() throws {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)

    // The pair has since been engaged, and the desktop sits on the right.
    let engaged = DisplayArrangement(tiles: [
      tile(id: 7, identity: "vd", right, mirroredIDs: [3]),
      tile(id: 2, identity: "dell", left),
    ])
    let substituting = [CGDirectDisplayID(7): Self.magKey]
    let saved = try #require(
      store.savedArrangement(for: TopologySignature(engaged, substituting: substituting))
    )
    guard case let .exact(restored) = ArrangementPersistence.resolve(
      saved, against: engaged, substituting: substituting
    ) else {
      Issue.record("a layout saved for the panel should resolve onto the pair standing in for it")
      return
    }
    #expect(restored.tile(7)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(restored.tile(2)?.rect.origin == DisplayPoint(x: 1920, y: 0))
  }

  /// The control for both of the above. Without the map the same read signs and
  /// matches under the virtual display, so the assertions are about the
  /// substitution rather than about the fixtures.
  @Test func withoutTheMapAnEngagedPairOrphansTheLayout() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.save(deskLayout)
    #expect(store.savedArrangement(for: TopologySignature(engagedLayout)) == nil)
    #expect(
      ArrangementPersistence.resolve(SavedArrangement(deskLayout), against: engagedLayout)
        == .setDiffers(missing: [Self.magKey], extra: [Self.identity(named: "vd").key])
    )
  }

  /// Both spellings of the substituted signature agree, for the reason the
  /// unsubstituted pair does: the arrival gate reads the online list and the
  /// store keys on the layout, and a disagreement between them would file a
  /// layout under a set the gate never recognises.
  @Test func bothSpellingsOfTheSubstitutedSignatureAgree() {
    let engaged = [
      online(id: 3, identity: "mag", mirrors: 7),
      online(id: 7, identity: "vd", inSet: true),
      online(id: 2, identity: "dell"),
    ]
    #expect(
      TopologySignature(online: engaged, substituting: [7: Self.magKey])
        == TopologySignature(engagedLayout, substituting: [7: Self.magKey])
    )
  }

  // MARK: - Geometry

  /// §7.4: the recorded size is validation, never authority. Never authority is
  /// the half that always held, and it still does: a resolved tile takes its
  /// size from the display that is attached NOW, so nothing can re-impose a
  /// footprint the screen no longer has.
  @Test func aResolvedTileTakesItsSizeFromTheAttachedDisplay() {
    // Recorded with the sizes the attached machine has, so the only thing the
    // sizes below can be coming from is the tiles.
    let saved = SavedArrangement(deskLayout.makingMain(2))
    guard case let .exact(restored) = ArrangementPersistence.resolve(saved, against: deskLayout)
    else {
      Issue.record("a layout recorded at the attached sizes must resolve")
      return
    }
    #expect(restored.tile(3)?.rect.width == left.width)
    #expect(restored.tile(3)?.rect.height == left.height)
    #expect(restored.tile(2)?.rect.width == right.width)
    #expect(restored.tile(2)?.rect.height == right.height)
  }

  /// **Validation is the half that was written down and never built (#180).**
  ///
  /// A saved layout is a set of ORIGINS that tile one particular set of
  /// footprints. Combining those origins with footprints they were never
  /// measured against describes a machine that has never existed: the origins
  /// stop meeting, and the app then read its own reconstruction back as though
  /// the user's displays were sitting on top of each other.
  ///
  /// So a footprint that has changed is its own answer. Not `.exact`, because
  /// this cannot be applied; not an overlap, because nothing overlaps.
  @Test func aLayoutIsNotResolvedOntoFootprintsItWasNotRecordedAgainst() {
    let saved = SavedArrangement(deskLayout)
    let magIsNowUltrawide = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
      tile(id: 2, identity: "dell", DisplayRect(x: 3440, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementPersistence.resolve(saved, against: magIsNowUltrawide)
      == .geometryDiffers([Self.magKey]))
  }

  /// Rotation changes a display's footprint without changing its resolution, so
  /// it reaches the same answer by a different road. The Dell in this setup is
  /// mounted at 270 degrees; turning it back upright swaps its width and height,
  /// and the origins recorded for the tall shape cannot tile the wide one.
  @Test func rotatingADisplayIsAFootprintChangeLikeAnyOther() {
    let portrait = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      tile(id: 2, identity: "dell", DisplayRect(x: 1920, y: 0, width: 1440, height: 2560)),
    ])
    let landscape = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      tile(id: 2, identity: "dell", DisplayRect(x: 1920, y: 0, width: 2560, height: 1440)),
    ])
    #expect(ArrangementPersistence.resolve(SavedArrangement(portrait), against: landscape)
      == .geometryDiffers([Self.dellKey]))
  }

  /// Every display whose footprint moved, not just the first one found: the
  /// sentence the user reads names them, and naming one of three sends them
  /// looking at the wrong screen.
  @Test func everyDisplayWhoseFootprintChangedIsNamed() {
    let saved = SavedArrangement(deskLayout)
    let bothResized = DisplayArrangement(tiles: [
      tile(id: 3, identity: "mag", DisplayRect(x: 0, y: 0, width: 2560, height: 1440)),
      tile(id: 2, identity: "dell", DisplayRect(x: 2560, y: 0, width: 2560, height: 1440)),
    ])
    #expect(ArrangementPersistence.resolve(saved, against: bothResized)
      == .geometryDiffers([Self.dellKey, Self.magKey].sorted()))
  }

  /// **The bug as it was reported, in the numbers it was measured in**
  /// (2026-08-17, #180). The Dell had been recorded at 1296 x 2304 and was
  /// 1440 x 2560 by the time the app next launched; macOS had already slid the
  /// MAG 144 points right to make room, so the machine was in a perfectly
  /// ordinary layout. Rebuilding the saved origins on the new footprints put the
  /// Dell's right edge at 3240 and the MAG's left edge at 3096: a 144-point
  /// overlap that existed nowhere but in the reconstruction, reported to the
  /// user at every launch as though they had made it.
  @Test func theLaunchTimeOverlapReportIsNotProducedAtAll() {
    let saved = SavedArrangement(entries: [
      SavedArrangementEntry(identity: "builtIn", x: 0, y: 0, width: 1800, height: 1169),
      SavedArrangementEntry(identity: Self.dellKey, x: 1800, y: -1135, width: 1296, height: 2304),
      SavedArrangementEntry(identity: Self.magKey, x: 3096, y: -450, width: 3440, height: 1440),
    ])
    let live = DisplayArrangement(tiles: [
      tile(id: 1, identity: "builtIn", DisplayRect(x: 0, y: 0, width: 1800, height: 1169)),
      tile(id: 3, identity: "dell", DisplayRect(x: 1800, y: -1135, width: 1440, height: 2560)),
      tile(id: 2, identity: "mag", DisplayRect(x: 3240, y: -450, width: 3440, height: 1440)),
    ])
    // The live machine is fine, which is the whole point: the overlap was ours.
    #expect(ArrangementRules.problems(in: live).isEmpty)

    let match = ArrangementPersistence.resolve(saved, against: live)
    #expect(match == .geometryDiffers([Self.dellKey]))
    if case let .exact(rebuilt) = match {
      Issue.record("resolved a layout onto footprints it was never measured against: \(rebuilt)")
    }
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
