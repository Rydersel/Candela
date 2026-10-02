import CandelaKit
import Testing

@Suite("Indicator style copy")
struct IndicatorStyleCopyTests {
  @Test func everyStyleHasADistinctLabel() {
    let labels = HUDStyle.allCases.map(IndicatorStyleCopy.label(for:))
    #expect(Set(labels).count == labels.count)
    #expect(IndicatorStyleCopy.label(for: .system) == "Match macOS")
    #expect(IndicatorStyleCopy.label(for: .classic) == "Classic")
    #expect(IndicatorStyleCopy.label(for: .classicCentered) == "Classic (centered)")
    #expect(IndicatorStyleCopy.label(for: .islandEdgeCapsules) == "Island (edge capsules)")
    for label in labels { #expect(!label.contains("\u{2014}"), "\(label)") }
  }

  /// The position rows keep their own captions for the styles that honour them
  /// and say why they are off for the ones that do not.
  @Test func positionCaptionsFollowThePlacementRule() {
    #expect(IndicatorStyleCopy.positionCaption(for: .ring, kind: .brightness) == "Contrast uses this position too.")
    #expect(IndicatorStyleCopy.positionCaption(for: .ring, kind: .volume)
      == "Mute uses this position too. The indicator appears on the display the keys act on.")
    #expect(IndicatorStyleCopy.positionCaption(for: .classic, kind: .brightness) == "Classic sits where macOS put it.")
    #expect(IndicatorStyleCopy.positionCaption(for: .sequoia, kind: .volume) == "Sequoia sits where macOS put it.")
    #expect(IndicatorStyleCopy.positionCaption(for: .classicCentered, kind: .volume) == "This style sits at the center of the screen.")
    #expect(IndicatorStyleCopy.positionCaption(for: .islandDrop, kind: .brightness) == "The Island lives on the notch.")
    #expect(IndicatorStyleCopy.positionRowsApply(to: .vertical))
    #expect(!IndicatorStyleCopy.positionRowsApply(to: .islandEdge))
  }
}
