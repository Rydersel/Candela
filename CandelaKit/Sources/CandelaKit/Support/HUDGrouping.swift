import CoreGraphics

/// How many pills a stepped set of displays actually produces, and what each
/// one is entitled to say.
///
/// The HUD keys its windows by the display they are DRAWN ON, and a mirror set
/// draws on its master only, so N stepped members share one window. Announcing
/// each member separately therefore wrote the same window N times and the last
/// write won: a three-display set showed a pill carrying whichever member
/// happened to sort last, with that member's value (#123, found on hardware
/// 2026-08-10). Nothing chose that member; it was iteration order.
///
/// Grouping the announcement is the fix, and it belongs here rather than in the
/// AppKit island for the same reason placement does (DT16): the island holds no
/// judgement, and there is no app test target (D21), so logic that lives in the
/// app cannot be pinned by a test.
public enum HUDGrouping {
  /// One pill: where it is drawn, which display it reports, and how many other
  /// displays moved with it.
  public struct Pill: Equatable, Sendable {
    public let placement: CGDirectDisplayID
    public let named: CGDirectDisplayID
    /// Zero for an ordinary display. Positive only for a mirror set, where it
    /// counts the members the pill cannot name.
    public let othersInSet: Int

    public init(placement: CGDirectDisplayID, named: CGDirectDisplayID, othersInSet: Int) {
      self.placement = placement
      self.named = named
      self.othersInSet = othersInSet
    }
  }

  /// Collapses stepped displays onto the pills that will actually appear, in
  /// first-stepped order.
  ///
  /// A pill names the display it is drawn on whenever that display was one of
  /// the stepped ones, so the bar underneath the name belongs to the same
  /// display as the name. In a mirror set that is the master, which
  /// `MirrorTopology.expand` puts first. It falls back to the first stepped
  /// member only when the placement display did not move at all: a set whose
  /// master has media keys disabled while its slaves do not, where naming the
  /// master would claim a step that never happened.
  ///
  /// One bar cannot show three levels, and the count in `othersInSet` is what
  /// keeps the pill honest about that: the name and the value describe one
  /// member, and the suffix says the others moved too.
  ///
  /// A repeated ID is counted once. Callers assemble this list from several
  /// step paths (every external, plus the built-in) and a duplicate would
  /// inflate the count for a display that moved a single time.
  public static func pills(
    forStepped steppedIDs: [CGDirectDisplayID], topology: MirrorTopology
  ) -> [Pill] {
    var order: [CGDirectDisplayID] = []
    var members: [CGDirectDisplayID: [CGDirectDisplayID]] = [:]
    var seen: Set<CGDirectDisplayID> = []
    for id in steppedIDs where seen.insert(id).inserted {
      let placement = topology.drawableDisplayID(for: id)
      if members[placement] == nil { order.append(placement) }
      members[placement, default: []].append(id)
    }
    return order.compactMap { placement in
      guard let group = members[placement], let first = group.first else { return nil }
      return Pill(
        placement: placement,
        named: group.contains(placement) ? placement : first,
        othersInSet: group.count - 1
      )
    }
  }

  /// What follows the display's name on the pill.
  ///
  /// Both parts are about the ONE display the pill names: the HDR marker
  /// reports that display's live state (D6: the liveness predicate, not the
  /// mode pref), and the count reports how many others took the same step
  /// without being named.
  public static func nameSuffix(isHDREngaged: Bool, othersInSet: Int) -> String? {
    var suffix = ""
    if isHDREngaged { suffix += " · HDR" }
    if othersInSet > 0 { suffix += " + \(othersInSet) more" }
    return suffix.isEmpty ? nil : suffix
  }
}
