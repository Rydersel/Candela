import CoreGraphics
import Foundation

/// The display SET a layout is about (§7.1).
///
/// The sorted `DisplayConfigIdentity.key`s of the displays that can hold a position,
/// joined. Never `CGDirectDisplayID`: IDs are reassigned across a replug (observed
/// live, two panels swapping 2 and 3 across one dock cycle), so a layout keyed on
/// them would restore the wrong display's origin onto the right display's screen.
///
/// **Sorted** because `CGGetOnlineDisplayList`'s order is not documented as stable.
/// The count survives the join, so a pair of identical panels signs `a+a`.
///
/// Built from `DisplayArrangement.tiles`, which makes the mirror-slave exclusion
/// structural: a slave gets no tile, so plugging a display into a mirror set
/// does not change the signature and does not orphan the layout.
///
/// What it does NOT claim: `ArrangementSnapshot` skips a display whose bounds are
/// unreadable, so a signature taken across that transient names fewer displays than
/// are attached. `ArrangementReapplyPolicy.decide` defers on that discrepancy.
public struct TopologySignature: Sendable, Hashable {
  public let key: String

  public init(_ arrangement: DisplayArrangement) {
    key = arrangement.tiles.map(\.identity.key).sorted().joined(separator: "+")
  }

  /// The layout spelling of `init(online:substituting:)`, and it must agree with it:
  /// the arrival gate signs the online list and the store keys on the layout, so a
  /// disagreement files a layout under a set the gate never recognises.
  public init(_ arrangement: DisplayArrangement, substituting: [CGDirectDisplayID: String]) {
    key = arrangement.tiles
      .map { substituting[$0.id] ?? $0.identity.key }
      .sorted()
      .joined(separator: "+")
  }

  /// The same set read one step earlier, straight off the ONLINE list, before
  /// `ArrangementSnapshot` turns it into tiles. The two spellings agree whenever the
  /// snapshot placed every display it should have.
  ///
  /// It exists so the arrival gate does NOT see an unreadable display as a topology
  /// change: that drops it from the layout while it is still attached, and a signature
  /// that moved with it would make the whole set read as newly arrived on its return.
  public init(online displays: [ConfiguredDisplay]) {
    key = displays
      .filter { !$0.isMirrorSlave } // mirror slaves: no tile, no position, not part of the set
      .map(\.identity.key)
      .sorted()
      .joined(separator: "+")
  }

  /// The same read, with each synthesis virtual display signing as the PHYSICAL panel
  /// it stands in for.
  ///
  /// `substituting` maps a synthesis VD's display ID to the identity key of the panel
  /// it was engaged for. IDs are reassigned across a replug, so the map is handed in
  /// fresh with the sample it describes and nothing stores it.
  ///
  /// The pair contributes EXACTLY ONCE, under the panel's identity: the VD gives the
  /// mapped key and the panel is filtered as the mirror slave it is. That is what
  /// makes engaging a synthesized size invisible to this key, so a layout saved before
  /// the size was engaged is still found while it is engaged.
  ///
  /// A map entry for a display that is not in `displays` contributes nothing: a
  /// pairing can outlive a sample.
  public init(online displays: [ConfiguredDisplay], substituting: [CGDirectDisplayID: String]) {
    key = displays
      .compactMap { display -> String? in
        if let physical = substituting[display.id] { return physical }
        guard !display.isMirrorSlave else { return nil } // the mirror-slave rule, as above
        return display.identity.key
      }
      .sorted()
      .joined(separator: "+")
  }

  /// No display can hold a position, so there is no set for a layout to be about.
  /// Persisting under it would file every empty read under one key.
  public var isEmpty: Bool { key.isEmpty }
}

/// One display's place in a saved layout.
///
/// The size is the geometry the origins were MEASURED against, never authority
/// (§7.4): a layout's geometry holds only for the modes the displays were in when it
/// was captured, so a restore declines rather than re-imposing a recorded footprint.
public struct SavedArrangementEntry: Sendable, Equatable, Codable {
  /// `DisplayConfigIdentity.key`. A String rather than the struct because this is an
  /// on-disk format and the key format is frozen.
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

  /// Spelled out rather than synthesized: these strings are an on-disk format, and
  /// synthesized keys track property names, so a rename would silently orphan every
  /// stored layout.
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
/// Origins are kept exactly as read, which makes them main-relative for free: the
/// global display space is *defined* with its origin at the main display's top-left
/// (the origin-is-main rule), so the display at (0, 0) holds the menu bar.
/// Normalising would lose which display that is.
public struct SavedArrangement: Sendable, Equatable, Codable {
  /// Versioned from v1 (§7.3) on top of `PrefsSchema`, because this descriptor's
  /// shape is the part most likely to move. A version the reader can refuse is what
  /// stops a newer build's layout from being half-understood by an older one.
  public let version: Int
  public let entries: [SavedArrangementEntry]

  public static let currentVersion = 1

  public init(version: Int = SavedArrangement.currentVersion, entries: [SavedArrangementEntry]) {
    self.version = version
    self.entries = entries
  }

  /// `substituting` is the synthesis-substitution map. It applies to the stored
  /// identities for the same reason it applies to the key: a layout saved while a
  /// synthesized size stood would otherwise name a virtual display that is gone the
  /// moment it is read back.
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

/// How well a saved layout matched the displays actually attached. Anything other
/// than `.exact` is reported rather than applied: restore runs unattended, so a
/// silent substitution is a layout the user never chose appearing unwatched.
public enum ArrangementMatch: Sendable, Equatable {
  /// Carries the layout to apply: the STORED origins on the CURRENT footprints.
  case exact(DisplayArrangement)
  /// **The identity-ambiguity rule.** Identity keys that each describe more than one
  /// attached display. Nothing is applied; see `ArrangementPersistence.resolve`.
  case ambiguous([String])
  /// The stored set is not the attached set. `missing` is stored and not
  /// attached, `extra` is attached and not stored.
  case setDiffers(missing: [String], extra: [String])
  /// The right displays are attached, and at least one is not the SIZE the layout was
  /// measured against. Its own outcome rather than a flavour of `.exact`: the origins
  /// tiled the footprints they were recorded on and say nothing about these.
  case geometryDiffers([String])
  /// Nothing to restore.
  case none
}

/// Saved layouts, keyed by topology.
///
/// **The one structural departure from `ModePersistence`**, stated so nobody "fixes"
/// it back: a stored mode is per DISPLAY identity, a layout is per display SET. Half
/// a layout is not a smaller layout, it is a different one.
///
/// UserDefaults is documented thread-safe and is the only stored property, hence the
/// unchecked conformance. Same shape as `ModePersistence` and `DisplayPrefs`.
public final class ArrangementPersistence: @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// App-level rather than per display: restoring a layout is one decision about the
  /// whole machine, with no per-display half to answer.
  public var isRestoreEnabled: Bool {
    defaults.bool(forKey: PrefName.restoreArrangement.rawValue)
  }

  public func setRestoreEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: PrefName.restoreArrangement.rawValue)
  }

  /// `nil` for an empty signature, for anything that does not decode, and for a
  /// descriptor a newer build wrote: a version this code does not know is not a layout
  /// it can half-apply. Corrupt data reads as "nothing stored" rather than crashing.
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
  /// The signature is DERIVED here rather than passed in, so "a layout is stored under
  /// the set it is about" is a property of the type instead of a rule every caller has
  /// to follow. An empty arrangement stores nothing.
  ///
  /// **The synthesis-substitution map.** `substituting` reaches BOTH the key and the
  /// stored identities. Either alone would file a layout under the panel while the
  /// entries named a display that
  /// exists only while the size does, which reads back as a different set. The map is
  /// runtime IDs, handed in with the sample; nothing here stores one.
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

  /// Clears the stored LAYOUT only. "Forget this layout" and "stop restoring layouts"
  /// are separate answers, and clearing both would silently opt the user back out the
  /// first time one layout was dropped.
  ///
  /// No production caller yet: this is the seam a "forget this layout" control uses.
  public func clear(for signature: TopologySignature) {
    defaults.removeObject(forKey: key(.savedArrangements, signature))
  }

  /// Matches a stored layout against the displays that can hold a position now.
  ///
  /// **The identity-ambiguity rule, shipped behaviour rather than a fallback.** A
  /// layout restores only when every display it names resolves to exactly ONE
  /// attached display. Two identical
  /// panels produce one identity key for two screens (the MAG 341C reports serial 0,
  /// so a second unit collides with it) and nothing stored says which goes on the
  /// left. A coin flip that swaps the user's screens is worse than not restoring.
  ///
  /// **A disambiguator was investigated and is unavailable** [MEASURED 2026-08-05,
  /// macOS 26.6]: the experiment could not be constructed, because macOS refuses to
  /// create two virtual displays sharing an advertised vendor+product and the physical
  /// setup has no identical pair. `CGDisplayUnitNumber` and
  /// `CGDisplayCreateUUIDFromDisplayID` remain untested against real twins. Do not add
  /// a speculative one.
  ///
  /// Compared as MULTISETS: a layout naming one `a` cannot restore onto two, and (the
  /// case a set comparison silently accepts) two `a`s cannot restore onto one.
  ///
  /// Then the SIZES: the right displays being attached is not enough, they also have
  /// to be the shape the origins were measured on. The three refusals are ordered by
  /// how far each gets, so the sentence the user reads names the first real problem.
  ///
  /// **The synthesis-substitution map**: `substituting` changes only what a tile is
  /// CALLED. The resolved tiles keep their own display IDs, because the virtual
  /// display owns the desktop and is
  /// the only member of the pair a plan may move.
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

    // The identity-ambiguity rule first, and only about identities the LAYOUT names:
    // an attached twin the layout says nothing about is a set difference, a
    // different sentence and remedy.
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
    // against.** Combining them with different ones describes a machine that never
    // existed, and the app read that reconstruction back as an overlap and reported it
    // at every launch, about displays sitting peacefully side by side.
    //
    // Checked as a whole rather than per display: a layout says how displays sit
    // RELATIVE to each other, so one changing size invalidates every origin in it.
    let movedEntries = saved.entries.filter { entry in
      guard let tile = tilesByIdentity[entry.identity]?.first else { return false }
      return tile.rect.width != entry.width || tile.rect.height != entry.height
    }
    // A synthesis SUBSTITUTE wears the panel's identity at its own size, so a size
    // difference there is definitional rather than stale. Refusing it hands the
    // virtual display to the OS's default placement, measured landing it on the
    // opposite side of the arrangement from the panel's saved tile. The substitute is
    // re-anchored below and the rebuilt layout must still validate; an ORDINARY
    // member's change still invalidates every origin.
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
            // The stored origin on the CURRENT footprint (§7.4): the size is never
            // authority. A resized substitute keeps the saved edge its anchor names,
            // so an edge that abutted a neighbour goes on abutting it.
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

    // Which edge the smaller substitute should keep is not recorded anywhere, so the
    // candidates are tried and the arrangement rules judge: first valid layout wins.
    // Two synthesis slots bound the search. When nothing validates, the origin-anchored
    // layout goes forward and the caller's spring-back check speaks.
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
    // The whole-arrangement rule, on the read side. UNREACHABLE as the checks above
    // stand (no identity names
    // two tiles and the multisets are equal), kept because what it guards is a partial
    // layout: a plan built from fewer tiles leaves the remainder's origins unset, and
    // CoreGraphics repositions any display a reconfiguration does not mention.
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
