import Testing
@testable import CandelaKit

/// `supportsHDR` false reads the same for "asked, no HDR modes" and for "not asked
/// yet", so anything that captions the greyed HDR button needs a second fact: whether
/// the capability refresh has answered at all. Without it the panel calls an HDR
/// display incapable for as long as the first refresh takes.
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

  /// A different panel on the same port: the old verdict is not a fact about the new
  /// display, so the caption goes quiet until the reconfiguration's refresh answers.
  @Test func aPanelSwapRetractsTheAnswer() async {
    let h = Harness(hdrSupported: true)
    await h.prime()
    #expect(h.controller.hdrCapabilityProbed)

    h.controller.rebind(writer: h.ddc, panelIdentity: "a-different-panel")
    #expect(h.controller.hdrCapabilityProbed == false)
  }

  /// Rebinding the SAME panel is the every-pass case (`AppModel.performRefresh` runs
  /// it on wake, reconfiguration and menu open), and dropping the answer there would
  /// blank the caption several times a session.
  @Test func aPlainRebindKeepsTheAnswer() async {
    let h = Harness(hdrSupported: false)
    await h.prime()

    h.controller.rebind(writer: h.ddc, panelIdentity: nil)
    #expect(h.controller.hdrCapabilityProbed)
  }
}
