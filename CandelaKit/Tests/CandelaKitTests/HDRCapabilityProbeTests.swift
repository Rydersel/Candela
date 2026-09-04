import Testing
@testable import CandelaKit

/// `supportsHDR` false reads the same for "no HDR modes" and "not asked yet", so
/// a caption on the greyed button needs to know whether the refresh answered.
@MainActor
@Suite("HDR capability probe")
struct HDRCapabilityProbeTests {
  /// The init refresh is queued on the main actor and this test never suspends, so
  /// the reading is the pre-refresh one by construction, not by luck.
  @Test func theProbeHasNotLandedBeforeTheFirstRefresh() {
    let h = Harness(hdrSupported: true)
    #expect(h.controller.hdrCapabilityProbed == false)
    #expect(h.controller.supportsHDR == false)
  }

  @Test func aRefreshThatFindsNoHDRCountsAsAnAnswer() async {
    let h = Harness(hdrSupported: false)
    await h.prime()
    #expect(h.controller.hdrCapabilityProbed)
    #expect(h.controller.supportsHDR == false)
  }

  @Test func aRefreshThatFindsHDRCountsToo() async {
    let h = Harness(hdrSupported: true)
    await h.prime()
    #expect(h.controller.hdrCapabilityProbed)
    #expect(h.controller.supportsHDR)
  }

  /// A different panel on the same port: the old verdict is not a fact about it.
  @Test func aPanelSwapRetractsTheAnswer() async {
    let h = Harness(hdrSupported: true)
    await h.prime()
    #expect(h.controller.hdrCapabilityProbed)

    h.controller.rebind(writer: h.ddc, panelIdentity: "a-different-panel")
    #expect(h.controller.hdrCapabilityProbed == false)
  }

  /// A same-panel rebind happens on every refresh pass; dropping the answer
  /// there would blank the caption several times a session.
  @Test func aPlainRebindKeepsTheAnswer() async {
    let h = Harness(hdrSupported: false)
    await h.prime()

    h.controller.rebind(writer: h.ddc, panelIdentity: nil)
    #expect(h.controller.hdrCapabilityProbed)
  }
}
