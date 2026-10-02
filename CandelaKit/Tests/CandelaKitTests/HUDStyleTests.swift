import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Indicator styles")
struct HUDStyleTests {
  /// Raw values are on-disk schema: an install that stored 8 must read the
  /// Island forever, and the three shipped raws cannot move.
  @Test func rawValuesArePinned() {
    let pinned: [(Int, HUDStyle)] = [
      (0, .system), (1, .segments), (2, .compact), (3, .classic), (4, .classicCentered),
      (5, .sequoia), (6, .vertical), (7, .ring), (8, .islandDrop), (9, .islandEdge),
      (10, .islandEdgeCapsules),
    ]
    for (raw, style) in pinned {
      #expect(HUDStyle(rawValue: raw) == style, "\(raw)")
    }
    #expect(HUDStyle(rawValue: 11) == nil)
    #expect(HUDStyle.allCases.count == 11)
  }

  @Test func thePickerOrderCoversEveryCaseOnce() {
    #expect(HUDStyle.pickerOrder.count == HUDStyle.allCases.count)
    #expect(Set(HUDStyle.pickerOrder) == Set(HUDStyle.allCases))
    #expect(HUDStyle.pickerOrder.first == .system)
    #expect(Array(HUDStyle.pickerOrder.suffix(3)) == [.islandDrop, .islandEdge, .islandEdgeCapsules])
  }

  /// Five styles follow the position pickers; six have one home.
  @Test func placementIsChosenOrFixedPerStyle() {
    for style in [HUDStyle.system, .segments, .compact, .vertical, .ring] {
      #expect(style.fixedAnchor == nil, "\(style)")
    }
    #expect(HUDStyle.classic.fixedAnchor == .bottomCenter(inset: 140))
    #expect(HUDStyle.sequoia.fixedAnchor == .bottomCenter(inset: 140))
    #expect(HUDStyle.classicCentered.fixedAnchor == .center)
    for style in [HUDStyle.islandDrop, .islandEdge, .islandEdgeCapsules] {
      #expect(style.fixedAnchor == .topEdge, "\(style)")
      #expect(style.isIsland, "\(style)")
    }
    #expect(!HUDStyle.classic.isIsland)
  }
}
