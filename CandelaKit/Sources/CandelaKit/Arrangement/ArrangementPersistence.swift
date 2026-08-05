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

  /// No display can hold a position, so there is no set for a layout to be
  /// about. Persisting under it would file every empty read under one key.
  public var isEmpty: Bool { key.isEmpty }
}

/// One display's place in a saved layout.
///
/// The size is recorded for VALIDATION, never as authority (§7.4): a layout's
/// geometry is only valid for the modes the displays were in when it was
/// captured, and the display's current footprint is what a restore has to tile.
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

  public init(_ arrangement: DisplayArrangement) {
    self.init(entries: arrangement.tiles.map {
      SavedArrangementEntry(
        identity: $0.identity.key,
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
  public func save(_ arrangement: DisplayArrangement) {
    let signature = TopologySignature(arrangement)
    guard !signature.isEmpty, let data = try? JSONEncoder().encode(SavedArrangement(arrangement))
    else { return }
    defaults.set(data, forKey: key(.savedArrangements, signature))
  }

  /// Clears the stored LAYOUT only. The opt-in is left alone deliberately, for
  /// `ModePersistence.clear`'s reason: "forget this layout" and "stop restoring
  /// layouts" are separate answers, and clearing both here would silently opt
  /// the user back out the first time one layout was dropped.
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
  public static func resolve(
    _ saved: SavedArrangement, against current: DisplayArrangement
  ) -> ArrangementMatch {
    guard !saved.entries.isEmpty else { return .none }

    let tilesByIdentity = Dictionary(grouping: current.tiles, by: \.identity.key)
    let attachedCounts = counts(current.tiles.map(\.identity.key))
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

    let tiles = saved.entries.compactMap { entry in
      tilesByIdentity[entry.identity]?.first.map { tile in
        ArrangementTile(
          id: tile.id,
          identity: tile.identity,
          name: tile.name,
          // The stored origin on the CURRENT footprint (§7.4): a display that
          // has changed resolution since the layout was captured is a different
          // size now, and re-imposing the recorded size would describe a screen
          // that does not exist. What that costs is that the recorded origins
          // may no longer tile, which the apply path reads back and reports.
          rect: DisplayRect(x: entry.x, y: entry.y, width: tile.rect.width, height: tile.rect.height),
          mirroredIDs: tile.mirroredIDs
        )
      }
    }
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
