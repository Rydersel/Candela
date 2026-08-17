import SwiftUI
import Testing

// Proof of life for the host-free bundle (AT1, AT2): an app-module symbol is
// callable and ImageRenderer produces pixels with no window and no booted app.
// The fixture test proves the AT3 fixture path constructs real Kit
// controllers over a fake wire without touching hardware.
@Suite("Scaffold")
struct ScaffoldTests {
  @Test func anAppModuleSymbolIsCallable() {
    #expect(RotationCopy.countdown(5).contains("5"))
  }

  @Test @MainActor func imageRendererProducesPixelsWithoutAWindow() {
    let renderer = ImageRenderer(
      content: Text("scaffold").padding().background(Color.orange))
    let image = renderer.cgImage
    #expect(image != nil)
    #expect((image?.width ?? 0) > 0)
  }

  @Test @MainActor func aFixtureDisplayStateConstructsOverTheFakeWire() {
    let state = TestFixtures.displayState(name: "Fixture", persistenceKey: "fix-1")
    #expect(state.display.name == "Fixture")
    #expect(state.display.persistenceKey == "fix-1")
  }

  @Test @MainActor func aHardwareFreeAppModelConstructs() {
    let model = TestFixtures.appModel()
    #expect(model.displays.isEmpty)
  }
}
