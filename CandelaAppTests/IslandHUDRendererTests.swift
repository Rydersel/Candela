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

  /// Mute empties the trace on its own, whatever value the caller passes.
  @MainActor @Test func muteIgnoresThePassedValue() {
    let renderer = IslandHUDRenderer(style: .islandDrop)
    renderer.layOut(notch: IslandNotch(rect: CGRect(x: 790, y: 1131, width: 220, height: 38), isReal: true),
                    screen: CGRect(x: 0, y: 0, width: 1800, height: 1169))
    renderer.show(HUDContent(kind: .volumeMuted, value: 0.6, title: "LG UltraFine"), reduceMotion: true)
    #expect(renderer.traceStrokeEndForTesting == 0)
    #expect(renderer.readoutForTesting == "Muted")
  }

  /// A display without a notch, at a negative origin like an external left of the built-in.
  static let drawn = IslandNotch(rect: CGRect(x: -1390, y: 1102, width: 220, height: 38), isReal: false)
  static let external = CGRect(x: -2560, y: -300, width: 2560, height: 1440)

  /// Filled shape layers anywhere under the content view; the trace layers are
  /// stroke-only, so only a notch-shaped tab counts.
  @MainActor static func filledShapes(in layer: CALayer) -> Int {
    let own = (layer as? CAShapeLayer)?.fillColor != nil ? 1 : 0
    return own + (layer.sublayers ?? []).reduce(0) { $0 + filledShapes(in: $1) }
  }

  @MainActor @Test func theEdgeStylesDrawNoNotchWhereThereIsNone() {
    for style in [HUDStyle.islandEdge, .islandEdgeCapsules] {
      let renderer = IslandHUDRenderer(style: style)
      renderer.layOut(notch: Self.drawn, screen: Self.external)
      renderer.show(HUDContent(kind: .brightness, value: 0.5, title: "LG UltraFine"), reduceMotion: true)
      #expect(Self.filledShapes(in: renderer.contentView.layer!) == 0, "\(style)")
    }
    // The control: the drop's own tab is the one filled shape the count can see.
    let drop = IslandHUDRenderer(style: .islandDrop)
    drop.layOut(notch: Self.drawn, screen: Self.external)
    #expect(Self.filledShapes(in: drop.contentView.layer!) == 1)
  }

  @MainActor @Test func theDropTraceFollowsTheValueWithoutANotch() {
    let renderer = IslandHUDRenderer(style: .islandDrop)
    renderer.layOut(notch: Self.drawn, screen: Self.external)
    renderer.show(HUDContent(kind: .brightness, value: 0.4, title: "LG UltraFine"), reduceMotion: false)
    #expect(renderer.traceStrokeEndForTesting == 0.4)
    renderer.show(HUDContent(kind: .brightness, value: 0.8, title: "LG UltraFine"), reduceMotion: false)
    #expect(renderer.traceStrokeEndForTesting == 0.8)
  }
}
