import CoreGraphics
import Foundation

/// The display SET a layout is about (§7.1).
///
/// The sorted `DisplayConfigIdentity.key`s of the displays that can hold a
/// position, joined. Never `CGDirectDisplayID`: IDs are reassigned across a
/// replug — observed live, the MAG went 3→2 and the Dell 2→3 across one dock
/// cycle — so a layout keyed on them would restore the wrong display's origin
/// onto the right display's screen.
///
/// **Sorted** because `CGGetOnlineDisplayList`'s order is not documented as
/// stable, and a key that depended on it would orphan the layout it filed. The
/// count survives the join, so a pair of identical panels signs as `a+a` rather
/// than collapsing into a single `a`.
///
/// Built from `DisplayArrangement.tiles`, which is what makes the mirror-slave
/// exclusion structural rather than a filter this type has to remember: a slave
/// gets no tile (AR6) and has no position of its own, so plugging a display into
/// a mirror set does not change the signature and does not orphan the layout.
///
/// What it does NOT claim: the tiles are the displays the snapshot could place,
/// and `ArrangementSnapshot` skips a display whose bounds are unreadable — so a
/// signature taken across that transient names fewer displays than are attached.
/// The reapply path defers on exactly that discrepancy rather than trusting the
/// key (`ArrangementReapplyPolicy.decide`).
public struct TopologySignature: Sendable, Hashable {
  public let key: String

  public init(_ arrangement: DisplayArrangement) {
    key = arrangement.tiles.map(\.identity.key).sorted().joined(separator: "+")
  }

  /// The layout spelling of `init(online:substituting:)`, and it must agree
  /// with it: the arrival gate signs the online list and the store keys on the
  /// layout, so a disagreement would file a layout under a set the gate never
  /// recognises. Pinned by a test, as the unsubstituted pair is.
  ///
  /// A tile the map does not name contributes its own identity, so an empty map
  /// is `init(_:)` exactly.
  public init(_ arrangement: DisplayArrangement, substituting: [CGDirectDisplayID: String]) {
    key = arrangement.tiles
      .map { substituting[$0.id] ?? $0.identity.key }
      .sorted()
      .joined(separator: "+")
  }

  /// The same set, read one step earlier: straight off the ONLINE display list,
  /// before `ArrangementSnapshot` turns it into tiles. The two spellings agree
  /// whenever the snapshot placed every display it should have — pinned by a
  /// test, because that agreement is what lets the arrival gate and the storage
  /// key be talking about the same topology.
  ///
  /// It exists because the arrival gate must NOT see an unreadable display as a
  /// topology change: that drops it from the layout while it is still attached,
  /// and a signature that moved with it would make the whole set read as newly
  /// arrived once it came back.
  public init(online displays: [ConfiguredDisplay]) {
    key = displays
      .filter { !$0.isMirrorSlave } // AR6: no tile, no position, not part of the set
      .map(\.identity.key)
      .sorted()
      .joined(separator: "+")
  }

  /// The same read, with each synthesis virtual display signing as the PHYSICAL
  /// panel it is standing in for (SS12).
  ///
  /// `substituting` maps a synthesis VD's display ID to the identity key of the
  /// panel it was engaged for, as the mode-synthesis engine's pairing table
  /// names them. IDs are reassigned across a replug, so the map is handed in
  /// fresh with the sample it describes and nothing stores it.
  ///
  /// The pair contributes EXACTLY ONCE, under the panel's identity: the VD
  /// contributes the mapped key, and the panel is filtered as the mirror slave
  /// it is. That is what makes engaging a synthesized size invisible to this
  /// key, which is the whole of SS12: a layout saved before the size was
  /// engaged is still found while it is engaged, and the arrangement never
  /// re-files itself under a virtual display that exists only while the size
  /// does.
  ///
  /// The mapping is read BEFORE the slave filter, and that order is NOT
  /// load-bearing: swapping the two changes no answer, because the only display
  /// the map names is the VD MASTER, and a master is not a mirror slave under
  /// either reading. It is written this way because it reads as the rule it
  /// implements (SS1: the pairing is asked first, the flags second), not
  /// because the other order would be wrong. A display the map does not name is
  /// treated exactly as `init(online:)` treats it.
  ///
  /// A map entry for a display that is not in `displays` contributes nothing:
  /// the signature names the displays that are attached, and a pairing can
  /// outlive a sample.
  public init(online displays: [ConfiguredDisplay], substituting: [CGDirectDisplayID: String]) {
    key = displays
      .compactMap { display -> String? in
        if let physical = substituting[display.id] { return physical }
        guard !display.isMirrorSlave else { return nil } // AR6, as above
        return display.identity.key
      }
      .sorted()
      .joined(separator: "+")
  }

  /// No display can hold a position, so there is no set for a layout to be
  /// about. Persisting under it would file every empty read under one key.
  public var isEmpty: Bool { key.isEmpty }
}

/// One display's place in a saved layout.
///
/// The size is the geometry the origins were MEASURED against, and it is read
/// back for exactly that (`ArrangementPersistence.resolve`). Never as authority
/// (§7.4): a layout's geometry is only valid for the modes the displays were in
/// when it was captured, so a restore never re-imposes a recorded footprint on
/// a display that has since changed size. It declines instead.
public struct SavedArrangementEntry: Sendable, Equatable, Codable {
  /// `DisplayConfigIdentity.key`. A String rather than the struct because this
  /// is an on-disk format and the identity's key format is frozen; storing the
  /// token is storing exactly what was frozen.
  public let identity: String
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  public init(identity: String, x: Int, y: Int, width: Int, height: Int) {
    self.identity = identity
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// Spelled out rather than synthesized, for `DisplayModeDescriptor`'s reason:
  /// these strings are an on-disk format, and synthesized keys track the
  /// property names, so a later rename would silently orphan every stored
  /// layout rather than forcing a deliberate decision about the old data.
  private enum CodingKeys: String, CodingKey {
    case identity
    case x
    case y
    case width
    case height
  }
}

/// A layout, as stored.
///
/// Origins are kept exactly as they were read, which makes them main-relative
/// for free: the global display space is *defined* with its origin at the main
/// display's top-left (AR5), so the display at (0, 0) is the one holding the
/// menu bar. Normalising them away would lose which display that is, and the
/// menu bar moving is the most consequential thing an arrangement change does.
public struct SavedArrangement: Sendable, Equatable, Codable {
  /// Versioned from v1 (§7.3). `PrefsSchema` versions the whole prefs surface,
  /// but this descriptor's shape is the part most likely to move — a
  /// disambiguator alongside the identity is a live open question — and a
  /// version the reader can refuse is what stops a newer build's layout from
  /// being half-understood by an older one.
  public let version: Int
  public let entries: [SavedArrangementEntry]

  public static let currentVersion = 1

  public init(version: Int = SavedArrangement.currentVersion, entries: [SavedArrangementEntry]) {
    self.version = version
    self.entries = entries
  }

  /// `substituting` is SS12's map, and it applies to the stored identities for
  /// the same reason it applies to the key: what is written down has to be what
  /// the panel is called, or a layout saved while a synthesized size stood would
  /// name a virtual display that no longer exists the moment it is read back.
  public init(_ arrangement: DisplayArrangement, substituting: [CGDirectDisplayID: String] = [:]) {
    self.init(entries: arrangement.tiles.map {
      SavedArrangementEntry(
        identity: substituting[$0.id] ?? $0.identity.key,
        x: $0.rect.x, y: $0.rect.y,
        width: $0.rect.width, height: $0.rect.height
      )
    })
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case entries
  }
}

/// How well a saved layout could be matched against the displays actually
/// attached. Anything other than `.exact` is reported rather than applied —
/// restore runs unattended, so a silent substitution is a layout the user never
/// chose appearing while nobody is watching.
public enum ArrangementMatch: Sendable, Equatable {
  /// Every entry resolved to exactly one attached display. Carries the layout to
  /// apply: the STORED origins on the displays' CURRENT footprints.
  case exact(DisplayArrangement)
  /// **AR11.** The named identity keys that each describe more than one attached
  /// display. Nothing is applied — see `ArrangementPersistence.resolve`.
  case ambiguous([String])
  /// The stored set is not the attached set. `missing` is stored and not
  /// attached, `extra` is attached and not stored.
  case setDiffers(missing: [String], extra: [String])
  /// The right displays are attached, and at least one of them is not the SIZE
  /// the layout was measured against. The named identity keys are the ones that
  /// moved, sorted.
  ///
  /// Its own outcome rather than a flavour of `.exact`, because the origins are
  /// not restorable and are not an overlap either: they tiled the footprints
  /// they were recorded on, and they say nothing whatever about the footprints
  /// attached now.
  case geometryDiffers([String])
  /// Nothing to restore.
  case none
}

/// Saved layouts, keyed by topology.
///
/// **The one structural departure from `ModePersistence`**, stated so nobody
/// "fixes" it back: a stored mode is per DISPLAY identity, and a layout is per
/// display SET. One stored value covers the whole topology, because a layout is
/// a statement about how displays sit relative to each other and half of one is
/// not a smaller layout — it is a different one.
///
/// UserDefaults is documented thread-safe and it is the only stored property,
/// hence the unchecked conformance — the same shape as `ModePersistence`,
/// `DisplayPrefs` and `UserDefaultsBrightnessStore`.
public final class ArrangementPersistence: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The opt-in, app-level rather than per display: restoring a layout is one
  /// decision about the whole machine, and there is no per-display half of it to
  /// answer.
  public var isRestoreEnabled: Bool {
    defaults.bool(forKey: PrefName.restoreArrangement.rawValue)
  }

  public func setRestoreEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: PrefName.restoreArrangement.rawValue)
  }

  /// `nil` for an empty signature, for anything that does not decode, and for a
  /// descriptor a newer build wrote — a version this code does not know is not a
  /// layout it can half-apply. Corrupt data reads as "nothing stored" rather
  /// than crashing, exactly as `ModePersistence.storedMode` does.
  public func savedArrangement(for signature: TopologySignature) -> SavedArrangement? {
    guard !signature.isEmpty, let data = defaults.data(forKey: key(.savedArrangements, signature))
    else { return nil }
    guard let saved = try? JSONDecoder().decode(SavedArrangement.self, from: data),
          saved.version <= SavedArrangement.currentVersion
    else { return nil }
    return saved
  }

  /// Files the layout under the signature of the displays it describes.
  ///
  /// The signature is DERIVED here rather than taken as an argument, so "a
  /// layout is stored under the set it is about" is a property of the type
  /// instead of a rule every caller has to follow. An empty arrangement stores
  /// nothing: there is no set for it to be about.
  ///
  /// **SS12.** `substituting` maps a synthesis virtual display's ID to the
  /// identity key of the panel it is standing in for, and it reaches BOTH the
  /// key and the stored identities: one of the two alone would file a layout
  /// under the panel while the entries named a display that only exists while
  /// the size does, which reads back as a different display set. The map is
  /// runtime IDs, handed in with the sample it describes; nothing here stores
  /// one.
  public func save(
    _ arrangement: DisplayArrangement, substituting: [CGDirectDisplayID: String] = [:]
  ) {
    let signature = TopologySignature(arrangement, substituting: substituting)
    guard !signature.isEmpty,
          let data = try? JSONEncoder().encode(
            SavedArrangement(arrangement, substituting: substituting)
          )
    else { return }
    defaults.set(data, forKey: key(.savedArrangements, signature))
  }

  /// Clears the stored LAYOUT only. The opt-in is left alone deliberately, for
  /// `ModePersistence.clear`'s reason: "forget this layout" and "stop restoring
  /// layouts" are separate answers, and clearing both here would silently opt
  /// the user back out the first time one layout was dropped.
  ///
  /// No production caller yet — this is the engine seam issue #49 (forget a
  /// remembered layout) wires up.
  public func clear(for signature: TopologySignature) {
    defaults.removeObject(forKey: key(.savedArrangements, signature))
  }

  /// Matches a stored layout against the displays that can hold a position now.
  ///
  /// **AR11, and it is the shipped behaviour rather than a fallback.** A layout
  /// restores only when every display it names resolves to exactly ONE attached
  /// display. Two identical panels — a MAG 341C reports serial 0, so an
  /// identical unit collides with it — produce one identity key for two screens,
  /// and nothing in the stored layout says which of them goes on the left. A
  /// coin flip that swaps the user's screens is worse than not restoring, so
  /// this refuses and names the collision instead.
  ///
  /// **A disambiguator was investigated and is unavailable** [MEASURED
  /// 2026-08-05, macOS 26.6]: the experiment could not even be constructed,
  /// because macOS refuses to create two virtual displays sharing an advertised
  /// vendor+product, and the physical setup has no identical pair.
  /// `CGDisplayUnitNumber` and `CGDisplayCreateUUIDFromDisplayID` remain
  /// untested against real twins. Do not add a speculative one.
  ///
  /// Compared as MULTISETS, not as sets: a layout naming one `a` cannot be
  /// restored onto two, and — the case a set comparison would silently accept —
  /// a layout naming two `a`s cannot be restored onto one.
  ///
  /// Then the SIZES, which is the check #180 was filed for: the right displays
  /// being attached is not enough, they also have to be the shape the origins
  /// were measured on. The three refusals are ordered by how far each gets
  /// before it stops, so the sentence the user reads names the first thing that
  /// is actually wrong.
  ///
  /// **SS12**: `substituting` names each synthesis virtual display by the panel
  /// it is standing in for, so a layout saved for the panel matches the pair
  /// that is showing its picture. It is the same map `save` was given, and it
  /// changes only what a tile is CALLED here: the resolved tiles keep their own
  /// display IDs, because the virtual display is the member of the pair that
  /// owns the desktop and the only one a plan may move (AR6).
  public static func resolve(
    _ saved: SavedArrangement, against current: DisplayArrangement,
    substituting: [CGDirectDisplayID: String] = [:]
  ) -> ArrangementMatch {
    guard !saved.entries.isEmpty else { return .none }

    func identity(of tile: ArrangementTile) -> String {
      substituting[tile.id] ?? tile.identity.key
    }
    let tilesByIdentity = Dictionary(grouping: current.tiles, by: identity)
    let attachedCounts = counts(current.tiles.map(identity))
    let storedCounts = counts(saved.entries.map(\.identity))

    // AR11 first, and only about identities the LAYOUT names: an attached twin
    // the layout says nothing about is a set difference, which is a different
    // sentence and a different remedy.
    let ambiguous = storedCounts.keys.filter { (attachedCounts[$0] ?? 0) > 1 }.sorted()
    guard ambiguous.isEmpty else { return .ambiguous(ambiguous) }

    guard storedCounts == attachedCounts else {
      let missing = storedCounts
        .filter { $0.value > (attachedCounts[$0.key] ?? 0) }.keys.sorted()
      let extra = attachedCounts
        .filter { $0.value > (storedCounts[$0.key] ?? 0) }.keys.sorted()
      return .setDiffers(missing: missing, extra: extra)
    }

    // **The origins are only meaningful on the footprints they were measured
    // against (#180).** Combining them with different ones describes a machine
    // that has never existed, and the app then read that reconstruction back as
    // an overlap and reported it: at every launch, about displays sitting
    // peacefully side by side, in the sentence written for a user who had just
    // dragged one onto another.
    //
    // Checked here rather than at the apply, and as a whole rather than per
    // display: a layout is a statement about how displays sit RELATIVE to each
    // other, so one display changing size invalidates every origin in it,
    // including the ones whose own display never moved.
    let movedEntries = saved.entries.filter { entry in
      guard let tile = tilesByIdentity[entry.identity]?.first else { return false }
      return tile.rect.width != entry.width || tile.rect.height != entry.height
    }
    // A synthesis SUBSTITUTE wears the panel's identity at its own size, so a
    // size difference there is definitional rather than stale. Refusing it
    // hands the virtual display to the OS's default placement, which was
    // measured putting it on the opposite side of the arrangement from the
    // panel's saved tile. The origins-were-measured-elsewhere hazard stays
    // real, so the substitute is re-anchored below and the rebuilt layout must
    // still validate; an ORDINARY member's change still invalidates every
    // origin in the layout.
    let ordinaryMoved = movedEntries
      .filter { entry in
        guard let tile = tilesByIdentity[entry.identity]?.first else { return true }
        return substituting[tile.id] == nil
      }
      .map(\.identity).sorted()
    guard ordinaryMoved.isEmpty else { return .geometryDiffers(ordinaryMoved) }
    let resized = Set(movedEntries.map(\.identity))

    func tiles(anchors: [String: (right: Bool, bottom: Bool)]) -> [ArrangementTile] {
      saved.entries.compactMap { entry in
        tilesByIdentity[entry.identity]?.first.map { tile in
          let anchor = anchors[entry.identity] ?? (right: false, bottom: false)
          return ArrangementTile(
            id: tile.id,
            identity: tile.identity,
            name: tile.name,
            // The stored origin on the CURRENT footprint (§7.4) for every
            // unchanged member: the size is never authority. A resized
            // substitute keeps the saved edge its anchor names, so the edge
            // that abutted a neighbour goes on abutting it.
            rect: DisplayRect(
              x: anchor.right ? entry.x + entry.width - tile.rect.width : entry.x,
              y: anchor.bottom ? entry.y + entry.height - tile.rect.height : entry.y,
              width: tile.rect.width, height: tile.rect.height
            ),
            mirroredIDs: tile.mirroredIDs
          )
        }
      }
    }

    // Which edge of the saved tile the smaller substitute should keep is not
    // recorded anywhere, so the candidates are tried and the arrangement
    // rules judge: the first anchoring that yields a valid layout wins. Two
    // synthesis slots bound the search. When nothing validates, the
    // origin-anchored layout goes forward and the caller's AR7 check speaks.
    var chosen: [String: (right: Bool, bottom: Bool)] = [:]
    if !resized.isEmpty {
      let identities = resized.sorted()
      let options: [(right: Bool, bottom: Bool)] = [
        (false, false), (true, false), (false, true), (true, true),
      ]
      func search(
        _ index: Int, _ assignment: [String: (right: Bool, bottom: Bool)]
      ) -> [String: (right: Bool, bottom: Bool)]? {
        guard index < identities.count else {
          let layout = DisplayArrangement(tiles: tiles(anchors: assignment))
          return ArrangementRules.problems(in: layout).isEmpty ? assignment : nil
        }
        for option in options {
          var next = assignment
          next[identities[index]] = option
          if let found = search(index + 1, next) { return found }
        }
        return nil
      }
      chosen = search(0, [:]) ?? [:]
    }

    let tiles = tiles(anchors: chosen)
    // AR4 on the read side. UNREACHABLE as the checks above stand — no identity
    // names two tiles and the two multisets are equal, so every entry has
    // exactly one tile — and kept anyway, because what it guards is a partial
    // layout: a plan built from fewer tiles than the layout names leaves the
    // remainder's origins unset, and CoreGraphics repositions any display a
    // reconfiguration does not mention. Stated as unreachable rather than
    // pinned by a test, because no input reaches it; a mutation pass finds it
    // exactly this way, and that is the honest description.
    guard tiles.count == saved.entries.count else { return .none }
    return .exact(DisplayArrangement(tiles: tiles))
  }

  private static func counts(_ keys: [String]) -> [String: Int] {
    keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }

  private func key(_ name: PrefName, _ signature: TopologySignature) -> String {
    "\(name.rawValue).\(signature.key)"
  }
}
