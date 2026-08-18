import CandelaKit
import CoreGraphics
import Testing

/// SS7's carve-out as the three mirroring surfaces apply it, and SS12's naming
/// fallback. Both were view-private before this suite and unreachable by any
/// test; the derivation moved to a nameable function in the same file and this
/// calls it (AT10).
///
/// The fixture is the shape that produced the defects: a single physical panel
/// with a synthesized size engaged, so the virtual display is a second online
/// display and every unfiltered count reads two.
@Suite("Mirroring surfaces under a synthesis set") @MainActor
struct MirroringPredicateTests {
  private static let panelID: CGDirectDisplayID = 2
  private static let virtualID: CGDirectDisplayID = 91

  private func display(
    _ id: CGDirectDisplayID, name: String, mirrors: CGDirectDisplayID? = nil
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(
        vendor: 0x3669, model: UInt32(id), serial: UInt32(id), isBuiltIn: false
      ),
      name: name, isBuiltIn: false, mirrorsDisplay: mirrors ?? kCGNullDirectDisplay
    )
  }

  /// The panel mirrors onto the virtual display, and the engine's pairing names
  /// the master. Without that stamp this is indistinguishable from a mirror set
  /// the user built, which is the whole reason `synthesisMasters` is injected.
  private var engaged: MirrorTopology {
    MirrorTopology(
      [
        display(Self.panelID, name: "MAG341C", mirrors: Self.virtualID),
        display(Self.virtualID, name: "Candela Scaled Size"),
      ],
      synthesisMasters: [Self.virtualID]
    )
  }

  /// The same machine state with the stamp missing: the control for every test
  /// below, and the state the surfaces were in before SS7 was wired.
  private var unstamped: MirrorTopology {
    MirrorTopology([
      display(Self.panelID, name: "MAG341C", mirrors: Self.virtualID),
      display(Self.virtualID, name: "Candela Scaled Size"),
    ])
  }

  @Test func aSynthesisSetIsNotMirroringTheUserDid() {
    #expect(MirroringPredicates.isSynthesized(engaged, displayID: Self.panelID))
    #expect(!MirroringPredicates.isSynthesized(unstamped, displayID: Self.panelID))
  }

  /// The count that decides whether a lone panel is offered a mirror control at
  /// all. The virtual display goes; the physical panel stays, because it is a
  /// display the user has and can mirror.
  @Test func theVirtualDisplayIsNotADisplayTheUserHas() {
    let visible = MirroringPredicates.userVisibleDisplays(engaged)
    #expect(visible.map(\.id) == [Self.panelID])
    #expect(MirroringPredicates.userVisibleDisplays(unstamped).count == 2)
  }

  /// "Showing Candela Scaled Size" names a display nobody has, one row above a
  /// control offering to start mirroring.
  @Test func theStatusLineSaysNotMirroredRatherThanNamingTheVirtualDisplay() {
    let name: (CGDirectDisplayID) -> String = { id in
      id == Self.virtualID ? "Candela Scaled Size" : "MAG341C"
    }
    #expect(
      MirroringPredicates.statusLine(engaged, displayID: Self.panelID, name: name)
        == MirroringCopy.notMirroredText
    )
    #expect(
      MirroringPredicates.statusLine(unstamped, displayID: Self.panelID, name: name)
        == "Showing Candela Scaled Size"
    )
  }

  /// A genuine mirror set still reads as one: the carve-out is the pairing, not
  /// "anything with a master".
  @Test func aMirrorSetTheUserBuiltStillReadsAsMirroring() {
    let userSet = MirrorTopology([
      display(1, name: "Built-in"),
      display(Self.panelID, name: "MAG341C", mirrors: 1),
    ])
    #expect(!MirroringPredicates.isSynthesized(userSet, displayID: Self.panelID))
    #expect(MirroringPredicates.showsMirroringBadge(userSet, displayID: Self.panelID))
    #expect(MirroringPredicates.userVisibleDisplays(userSet).count == 2)
  }

  /// The hero's badge. Off for a synthesis set, because the Mirroring row under
  /// it reads "Not mirrored" and a badge there would be the only claim of its
  /// kind on the page with nothing saying what it meant.
  @Test func theHeroBadgeStaysOffForASynthesizedPanel() {
    #expect(!MirroringPredicates.showsMirroringBadge(engaged, displayID: Self.panelID))
    #expect(MirroringPredicates.showsMirroringBadge(unstamped, displayID: Self.panelID))
  }
}

/// SS12: the arrangement map presents the physical panel for a synthesis pair,
/// and the one string it must never show is the virtual display's name.
@Suite("The arrangement map's name for a synthesis pair") @MainActor
struct ArrangementPaneNamingTests {
  private static let panelID: CGDirectDisplayID = 2
  private static let virtualID: CGDirectDisplayID = 91
  private static let panels: [CGDirectDisplayID: CGDirectDisplayID] = [virtualID: panelID]

  @Test func aPairIsNamedForThePanelStandingBehindIt() {
    #expect(
      ArrangementPane.name(
        of: Self.virtualID, standingBehind: Self.panels,
        friendly: { $0 == Self.panelID ? "MAG341C" : "Candela Scaled Size" },
        fromTopology: { _ in nil }
      ) == "MAG341C"
    )
  }

  @Test func anUnpairedDisplayKeepsItsOwnName() {
    #expect(
      ArrangementPane.name(
        of: 7, standingBehind: Self.panels, friendly: { _ in "Dell U2725QE" },
        fromTopology: { _ in nil }
      ) == "Dell U2725QE"
    )
  }

  /// With no friendly name, the panel's own name from the topology.
  @Test func aPairWithNoFriendlyNameFallsBackToTheTopologysName() {
    #expect(
      ArrangementPane.name(
        of: Self.virtualID, standingBehind: Self.panels, friendly: { _ in "" },
        fromTopology: { _ in "MAG341C" }
      ) == "MAG341C"
    )
  }

  /// The last resort, and the reason it is spelled out: an empty answer sends
  /// the canvas back to the TILE's name, which for a pair is the virtual
  /// display's, the one string that must not appear on this map.
  @Test func aPairNothingCanNameIsStillNeverEmpty() {
    let name = ArrangementPane.name(
      of: Self.virtualID, standingBehind: Self.panels, friendly: { _ in "" },
      fromTopology: { _ in nil }
    )
    #expect(name == "Display")
    #expect(!name.isEmpty)
  }
}
