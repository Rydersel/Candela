import Testing
@testable import CandelaKit

@MainActor
@Suite("Chiclet step math")
struct BrightnessStepTests {
  private func makeController(brightness: Double) -> BrightnessController {
    let controller = BrightnessController(writer: FakeDDC())
    controller.setBrightness(brightness)
    return controller
  }

  @Test func coarseUpFromChicletBoundary() {
    let c = makeController(brightness: 0.5)
    #expect(c.step(isUp: true, isFine: false) == 0.5625) // one 1/16 chiclet up
  }

  @Test func coarseDownFromChicletBoundary() {
    let c = makeController(brightness: 0.5)
    #expect(c.step(isUp: false, isFine: false) == 0.4375)
  }

  @Test func coarseDownSnapsToNearBoundary() {
    // 0.52 is just above the 0.5 boundary: stepping down snaps to 0.5,
    // it does not overshoot a full chiclet (fork's 25%-distance behavior).
    let c = makeController(brightness: 0.52)
    #expect(c.step(isUp: false, isFine: false) == 0.5)
  }

  @Test func coarseUpSnapsAcrossToNextBoundary() {
    // 0.51 is inside the snap band going up: lands on 0.5625, not 0.5725.
    let c = makeController(brightness: 0.51)
    #expect(c.step(isUp: true, isFine: false) == 0.5625)
  }

  @Test func fineStepIsQuarterChiclet() {
    let c = makeController(brightness: 0.5)
    #expect(c.step(isUp: true, isFine: true) == 0.515625) // 1/64
  }

  @Test func clampsAtTop() {
    let c = makeController(brightness: 1.0)
    #expect(c.step(isUp: true, isFine: false) == 1.0)
  }

  @Test func clampsAtBottom() {
    let c = makeController(brightness: 0.0)
    #expect(c.step(isUp: false, isFine: false) == 0.0)
  }

  @Test func stepPublishesAndSubmitsWrite() async {
    let writer = FakeDDC()
    let c = BrightnessController(writer: writer)
    c.setBrightness(0.5)
    c.step(isUp: true, isFine: false)
    #expect(c.brightness == 0.5625)
    await c.waitForPendingWrites()
    #expect((await writer.recordedWrites()).last?.value == 56) // 0.5625 * 100 rounded
  }
}
