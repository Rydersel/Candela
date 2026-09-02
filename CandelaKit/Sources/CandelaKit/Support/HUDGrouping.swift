import CoreGraphics

/// How many pills a stepped set of displays actually produces, and what each one
/// is entitled to say.
///
/// The HUD keys windows by the display they are DRAWN ON, and a mirror set draws on
/// its master only, so N stepped members share one window. Announcing each member
/// wrote that window N times and the last write won, so the pill carried whichever
/// member happened to sort last [MEASURED on hardware].
///
/// It lives here rather than in the AppKit island for the reason placement does:
/// with no app test target, app-side logic cannot be pinned.
public enum HUDGrouping {
  /// One pill: where it draws, which display it names, and how many others moved.
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
  /// A pill names the display it is drawn on whenever that display was stepped, so
  /// the bar and the name belong to the same display. It falls back to the first
  /// stepped member only when the placement display did not move, as in a set whose
  /// master has media keys disabled: naming it would claim a step that never
  /// happened.
  ///
  /// It takes the whole topology rather than a resolution closure because a
  /// synthesis set wants the opposite naming answer. See the branch below.
  ///
  /// A repeated ID is counted once: callers assemble this list from several step
  /// paths, and a duplicate would inflate the count for one display's single step.
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
      // A synthesized size is a mirror set the APP engaged, and its master is
      // a virtual display created to hold the framebuffer. The pill still has to be
      // drawn there, but naming or counting the master would announce a display the
      // user has never seen. A second real panel on the same framebuffer is one they
      // CAN see, so it is counted like any other member.
      //
      // The fallback keeps the master's name rather than dropping the pill: a set
      // whose panel took no step is no reason to swallow an announcement.
      let panels = group.filter { $0 != placement }
      return Pill(
        placement: placement,
        named: panels.first ?? first,
        othersInSet: max(panels.count - 1, 0)
      )
    }
  }

  /// What follows the display's name on the pill. Both parts describe the ONE
  /// display the pill names: the HDR marker is that display's live state (the
  /// liveness predicate, not the mode pref), and the count is how many others
  /// stepped without being named.
  public static func nameSuffix(isHDREngaged: Bool, othersInSet: Int) -> String? {
    var suffix = ""
    if isHDREngaged { suffix += " · HDR" }
    if othersInSet > 0 { suffix += " + \(othersInSet) more" }
    return suffix.isEmpty ? nil : suffix
  }
}
