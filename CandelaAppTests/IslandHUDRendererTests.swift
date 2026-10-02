import AppKit
import CandelaKit
import Testing

@Suite("Island renderer")
struct IslandHUDRendererTests {
  @MainActor @Test func theThreeStylesBuild() {
    for style in [HUDStyle.islandDrop, .islandEdge, .islandEdgeCapsules] {
      let renderer = IslandHUDRenderer(style: style)
      #expect(renderer.style == style)
      #expect(renderer.contentView.layer != nil, "\(style)")
    }
  }

  /// Reduce Motion: the open state appears at once and nothing is animated. The
  /// layers' animation keys are the observable.
  @MainActor @Test func reduceMotionAddsNoAnimations() {
    let renderer = IslandHUDRenderer(style: .islandDrop)
    renderer.layOut(notch: IslandNotch(rect: CGRect(x: 790, y: 1131, width: 220, height: 38), isReal: true),
                    screen: CGRect(x: 0, y: 0, width: 1800, height: 1169))
    renderer.show(HUDContent(kind: .brightness, value: 0.5, title: "LG UltraFine"), reduceMotion: true)
    #expect(renderer.animationKeysForTesting.isEmpty)
    #expect(renderer.traceStrokeEndForTesting == 0.5)
    if case .selfAnimated(let duration) = renderer.hide(reduceMotion: true) {
      #expect(duration == 0)
    } else { Issue.record("the island animates its own exit") }
  }

  @MainActor @Test func aShowAnimatesAndAMuteEmptiesTheTrace() {
    let renderer = IslandHUDRenderer(style: .islandEdge)
    renderer.layOut(notch: IslandNotch(rect: CGRect(x: 790, y: 1131, width: 220, height: 38), isReal: true),
                    screen: CGRect(x: 0, y: 0, width: 1800, height: 1169))
    renderer.show(HUDContent(kind: .brightness, value: 0.75, title: "LG UltraFine"), reduceMotion: false)
    #expect(!renderer.animationKeysForTesting.isEmpty)
    renderer.show(HUDContent(kind: .volumeMuted, value: 0, title: "LG UltraFine"), reduceMotion: false)
    #expect(renderer.traceStrokeEndForTesting == 0)
    #expect(renderer.readoutForTesting == "Muted")
  }
}
