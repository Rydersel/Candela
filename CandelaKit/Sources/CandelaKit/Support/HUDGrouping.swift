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
  /// A SYNTHESIS SET is the exception to the naming rule, and the reason this
  /// takes the whole topology rather than a resolution closure: the pairing it
  /// carries (SS1) is what tells a set the app engaged to serve a size from one
  /// the user asked for, and the two want opposite answers here. See the branch
  /// below.
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
      guard topology.isSynthesisSet(containing: placement) else {
        return Pill(
          placement: placement,
          named: group.contains(placement) ? placement : first,
          othersInSet: group.count - 1
        )
      }
      // SS1: a synthesized size is a mirror set the APP engaged, and its master
      // is a virtual display created to hold the framebuffer. The pill still
      // has to be DRAWN there (it is the only member with a screen), but the
      // person who pressed the key is looking at one panel: naming the virtual
      // display would put a name they have never seen on the pill, and counting
      // it as "+ 1 more" would announce a display that does not exist for them.
      // So the master is dropped from the naming and the count, and only from
      // those: a second real panel showing the same framebuffer is one the
      // user CAN see, and is counted like any other member.
      //
      // The fallback keeps the master's name rather than dropping the
      // announcement: a set whose panel took no step is not a reason to swallow
      // a pill the caller has already decided to show.
      let panels = group.filter { $0 != placement }
      return Pill(
        placement: placement,
        named: panels.first ?? first,
        othersInSet: max(panels.count - 1, 0)
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
