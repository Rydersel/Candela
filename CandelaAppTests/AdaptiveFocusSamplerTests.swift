import CoreGraphics
import Testing

@Suite("Adaptive focus freshness")
@MainActor
struct AdaptiveFocusSamplerTests {
  @Test func aMissHoldsIdleFocusButWithholdsAdaptiveFocus() {
    var next: CGDirectDisplayID? = 5
    let sampler = FocusSampler(resolver: { next })
    #expect(sampler.focusedDisplayID() == 5)
    #expect(sampler.currentResolvedDisplayID == 5)
    next = nil
    #expect(sampler.focusedDisplayID() == 5)
    #expect(sampler.currentResolvedDisplayID == nil)
    next = 9
    #expect(sampler.focusedDisplayID() == 9)
    #expect(sampler.currentResolvedDisplayID == 9)
  }

  @Test func aReconfigurationForgetsBothFocusReadings() {
    var next: CGDirectDisplayID? = 5
    let sampler = FocusSampler(resolver: { next })
    _ = sampler.focusedDisplayID()
    sampler.invalidate()
    #expect(sampler.currentResolvedDisplayID == nil)
    next = nil
    #expect(sampler.focusedDisplayID() == nil)
  }
}
