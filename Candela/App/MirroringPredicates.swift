import CandelaKit
import CoreGraphics

/// The synthesis carve-out, in one place. Several surfaces ask the same questions about
/// a mirror set, and a carve-out held in agreement by discipline has bitten this
/// branch before. Pure and nameable so the answers can be pinned without a
/// window; the views read these rather than re-deriving.
enum MirroringPredicates {
  /// True when this display is showing a synthesized size. The ONE predicate
  /// behind every carve-out: a set the app engaged to render a size is not
  /// mirroring the user asked for, and the size picker presents it instead.
  static func isSynthesized(_ topology: MirrorTopology, displayID: CGDirectDisplayID) -> Bool {
    topology.isSynthesisSet(containing: displayID)
  }

  /// The displays a mirroring surface may count and speak about: everything
  /// except the virtual displays synthesis renders onto.
  ///
  /// A VD is a real online display, so without this filter a lone panel looks
  /// like a two-display rig and the UI starts explaining that macOS keeps the
  /// other display locked, about a display Candela created a moment ago.
  ///
  /// The physical panel of a synthesis set STAYS: the user has it, can name it
  /// and can mirror it. Only the set it is in is hidden.
  static func userVisibleDisplays(_ topology: MirrorTopology) -> [ConfiguredDisplay] {
    topology.displays.filter { !topology.synthesisMasters.contains($0.id) }
  }

  /// What the Mirroring status row reads.
  ///
  /// A synthesized panel reads "Not mirrored", the true answer to what the row
  /// asks: the user is mirroring nothing. "Showing <virtual display>" would name
  /// a display nobody has, beside a control offering to start mirroring.
  ///
  /// This deliberately disagrees with `DiagnosticsCopy.mirroring`, which says
  /// "Showing a synthesized size" about the same display. Ruled: both ship. The
  /// row answers what the USER mirrored, the report describes the machine.
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
  /// Off for a synthesis set, by the tile's contract: what it draws must also be
  /// stated in words on the page, and the Mirroring row reads "Not mirrored"
  /// there. A badge over that row would be a claim with nothing explaining it.
  static func showsMirroringBadge(
    _ topology: MirrorTopology, displayID: CGDirectDisplayID
  ) -> Bool {
    !isSynthesized(topology, displayID: displayID)
      && !topology.setMembers(containing: displayID).isEmpty
  }
}
