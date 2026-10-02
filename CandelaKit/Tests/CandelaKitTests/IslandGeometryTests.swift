import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Island geometry")
struct IslandGeometryTests {
  let builtIn = CGRect(x: 0, y: 0, width: 1800, height: 1169)
  /// The built-in's two auxiliary areas as macOS reports them: 790 wide each
  /// side of a 220 pt notch, 38 tall.
  let auxLeft = CGRect(x: 0, y: 1131, width: 790, height: 38)
  let auxRight = CGRect(x: 1010, y: 1131, width: 790, height: 38)

  @Test func aRealNotchIsTheGapBetweenTheAuxiliaryAreas() {
    let notch = IslandGeometry.notch(screen: builtIn, auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight)
    #expect(notch.isReal)
    #expect(notch.rect == CGRect(x: 790, y: 1131, width: 220, height: 38))
  }

  /// No notch: a drawn one of the measured size, centred on THIS screen's frame,
  /// as tall as the notch would be.
  @Test func aDrawnNotchCentresOnTheScreenAtTheFallbackSize() {
    let external = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
    let notch = IslandGeometry.notch(screen: external, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    #expect(!notch.isReal)
    #expect(notch.rect == CGRect(x: -2560 + 1170, y: -300 + 1440 - 38, width: 220, height: 38))
  }

  @Test func thePanelSpansTheNotchOrTheScreen() {
    let notch = IslandGeometry.notch(screen: builtIn, auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight)
    let narrow = IslandGeometry.panelFrame(screen: builtIn, notch: notch, fullWidth: false)
    #expect(narrow == CGRect(x: 900 - 330, y: 1169 - 98, width: 660, height: 98))
    let wide = IslandGeometry.panelFrame(screen: builtIn, notch: notch, fullWidth: true)
    #expect(wide == CGRect(x: 0, y: 1169 - 98, width: 1800, height: 98))
  }

  /// Closed sits one point inside a real notch so nothing of ours shows below the
  /// glass's corners.
  @Test func closedAndOpenTabsInPanelCoordinates() {
    let notch = IslandGeometry.notch(screen: builtIn, auxiliaryTopLeft: auxLeft, auxiliaryTopRight: auxRight)
    let panel = IslandGeometry.panelFrame(screen: builtIn, notch: notch, fullWidth: false)
    let closed = IslandGeometry.closedTab(notch: notch, panel: panel)
    #expect(closed == CGRect(x: 221, y: 61, width: 218, height: 38))
    let open = IslandGeometry.openTab(notch: notch, panel: panel)
    #expect(open == CGRect(x: 220 - 16, y: 60 - 34, width: 220 + 32, height: 38 + 34))
    #expect(IslandGeometry.flank(notch: notch, panel: panel) == IslandGeometry.glass(notch: notch, panel: panel))
  }

  let external = CGRect(x: -2560, y: -300, width: 2560, height: 1440)

  /// No notch, no pretend notch: the drop's tab starts as a flat line on the top
  /// edge and opens only to the row's height plus headroom. The glass here is
  /// (220, 60, 220, 38) in the panel.
  @Test func aDrawnNotchGivesAFlatClosedTabAndAShallowOpenOne() {
    let notch = IslandGeometry.notch(screen: external, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    let panel = IslandGeometry.panelFrame(screen: external, notch: notch, fullWidth: false)
    #expect(IslandGeometry.glass(notch: notch, panel: panel) == CGRect(x: 220, y: 60, width: 220, height: 38))
    #expect(IslandGeometry.closedTab(notch: notch, panel: panel) == CGRect(x: 204, y: 98, width: 252, height: 0))
    #expect(IslandGeometry.openTab(notch: notch, panel: panel) == CGRect(x: 204, y: 98 - 44, width: 252, height: 44))
  }

  /// The edge styles' side information closes in on a narrow gap at the
  /// screen's centre rather than flanking a notch that is not there.
  @Test func aDrawnNotchFlanksANarrowCentredGap() {
    let notch = IslandGeometry.notch(screen: external, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
    let panel = IslandGeometry.panelFrame(screen: external, notch: notch, fullWidth: true)
    #expect(IslandGeometry.flank(notch: notch, panel: panel) == CGRect(x: 1268, y: 60, width: 24, height: 38))
  }

  @Test func theGlassOutlineHugsTheNotchFromOutside() {
    let glass = CGRect(x: 220, y: 60, width: 220, height: 38)
    let rect = IslandGeometry.glassOutlineRect(closedGlass: glass, lineWidth: 3)
    #expect(rect == CGRect(x: 218.5, y: 58.5, width: 223, height: 39.5))
  }

  /// A tab path: six segments, square top, two bottom arcs.
  @Test func tabPathShape() {
    let segments = IslandGeometry.tabPath(CGRect(x: 0, y: 0, width: 100, height: 40))
    #expect(segments.count == 6)
    #expect(segments.first == .move(CGPoint(x: 0, y: 40)))
    if case .arc(let center, let radius, _, _, _) = segments[3] {
      #expect(center == CGPoint(x: 90, y: 10)); #expect(radius == 10)
    } else { Issue.record("fourth segment is not the bottom-right arc") }
  }

  /// The edge outline runs corner to corner: starts at x 0 and ends at the panel width.
  @Test func edgeOutlineRunsCornerToCorner() {
    let glass = CGRect(x: 790, y: 60, width: 220, height: 38)
    let segments = IslandGeometry.edgeOutline(panelWidth: 1800, top: 96, around: glass)
    #expect(segments.first == .move(CGPoint(x: 0, y: 96)))
    #expect(segments.last == .line(CGPoint(x: 1800, y: 96)))
    let plain = IslandGeometry.outline(around: glass)
    #expect(plain.first == .move(CGPoint(x: 790, y: 98)))
    #expect(plain.last == .line(CGPoint(x: 1010, y: 98)))
  }

  @Test func theStraightEdgeIsOneLineCornerToCorner() {
    #expect(IslandGeometry.straightEdge(panelWidth: 2560, top: 96)
      == [.move(CGPoint(x: 0, y: 96)), .line(CGPoint(x: 2560, y: 96))])
  }
}
