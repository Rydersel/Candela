import CandelaKit
import CoreGraphics

/// SS7's carve-out, in one place.
///
/// Three surfaces ask the same questions about a mirror set: is it one the app
/// engaged to render a size, which displays may this surface speak about, and
/// what does the status line say. Each had its own copy, and a carve-out held in
/// agreement by discipline is the shape this branch has already been bitten by.
/// Pure and nameable so what the surfaces decide can be pinned without a window
/// (AT10); the views keep their own properties as thin readers of these.
enum MirroringPredicates {
  /// True when this display is showing a synthesized size. The ONE predicate
  /// behind every carve-out: a mirror set the app engaged to render a size is
  /// not mirroring the user asked for, has nothing for these surfaces to decide,
  /// and is presented by the size picker instead.
  static func isSynthesized(_ topology: MirrorTopology, displayID: CGDirectDisplayID) -> Bool {
    topology.isSynthesisSet(containing: displayID)
  }

  /// The displays a mirroring surface may count and speak about: everything
  /// except the virtual displays synthesis renders onto.
  ///
  /// A VD is a real online display, so without this filter a lone panel looks
  /// like a two-display rig: the panel section offers a mirror control, and the
  /// settings section explains that macOS keeps the other display locked, about
  /// a display Candela created a moment ago.
  ///
  /// The physical panel of a synthesis set STAYS, and that is not an oversight:
  /// it is a display the user has, can name and can mirror. Only the set it is
  /// in is hidden.
  static func userVisibleDisplays(_ topology: MirrorTopology) -> [ConfiguredDisplay] {
    topology.displays.filter { !topology.synthesisMasters.contains($0.id) }
  }

  /// What the Mirroring status row reads.
  ///
  /// A synthesized panel reads "Not mirrored", which is the true answer to what
  /// the row asks: the user is mirroring nothing. The set behind the size in
  /// force belongs to the size picker to describe, and "Showing <virtual
  /// display>" would name a display nobody has, beside a control offering to
  /// start mirroring.
  static func statusLine(
    _ topology: MirrorTopology, displayID: CGDirectDisplayID,
    name: (CGDirectDisplayID) -> String
  ) -> String {
    isSynthesized(topology, displayID: displayID)
      ? MirroringCopy.notMirroredText
      : MirroringCopy.state(topology: topology, displayID: displayID, name: name)
  }

  /// Whether the display hero's tile wears the mirroring badge.
  ///
  /// Off for a synthesis set, for the tile's own contract: what it draws must
  /// also be stated in words on the page, and the Mirroring row reads "Not
  /// mirrored" for a synthesized panel. A badge over that row would be the only
  /// claim of its kind on the page with nothing saying what it meant.
  static func showsMirroringBadge(
    _ topology: MirrorTopology, displayID: CGDirectDisplayID
  ) -> Bool {
    !isSynthesized(topology, displayID: displayID)
      && !topology.setMembers(containing: displayID).isEmpty
  }
}
