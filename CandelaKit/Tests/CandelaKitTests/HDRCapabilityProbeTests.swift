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

  // MARK: - The latch

  @Test func nothingHasBeenReportedBeforeTheFirstRefresh() {
    let h = Harness(hdrSupported: true)
    #expect(h.controller.hasReportedHDR == false)
  }

  @Test func aDisplayWithNoHDRNeverReportsIt() async {
    let h = Harness(hdrSupported: false)
    await h.prime()
    #expect(h.controller.hasReportedHDR == false)
  }

  /// A mode without HDR modes on a panel that has them: `supportsHDR` follows the
  /// mode, the latch keeps what the panel showed.
  @Test func aModeWithoutHDRDoesNotRetractTheReport() async {
    let h = Harness(hdrSupported: true)
    await h.prime()
    #expect(h.controller.hasReportedHDR)

    await h.hdr!.stubSupports(false)
    await h.controller.noteHDRStateMayHaveChanged()
    #expect(h.controller.supportsHDR == false)
    #expect(h.controller.hasReportedHDR)
  }

  /// First seen on a mode without HDR, then switched to one that has it.
  @Test func aLaterRefreshCanStillReportHDR() async {
    let h = Harness(hdrSupported: false)
    await h.prime()
    #expect(h.controller.hasReportedHDR == false)

    await h.hdr!.stubSupports(true)
    await h.controller.noteHDRStateMayHaveChanged()
    #expect(h.controller.hasReportedHDR)
  }

  @Test func aPanelSwapClearsTheReport() async {
    let h = Harness(hdrSupported: true)
    await h.prime()

    h.controller.rebind(writer: h.ddc, panelIdentity: "a-different-panel")
    #expect(h.controller.hasReportedHDR == false)
  }

  @Test func aPlainRebindKeepsTheReport() async {
    let h = Harness(hdrSupported: true)
    await h.prime()

    h.controller.rebind(writer: h.ddc, panelIdentity: nil)
    #expect(h.controller.hasReportedHDR)
  }

  // MARK: - The stored report

  /// A launch can find the display mirrored behind a synthesized size, listing no
  /// HDR modes; the stored report is what keeps its button.
  @Test func aStoredReportSeedsTheLatchBeforeAnyRefresh() async {
    let h = Harness(hdrSupported: false, configure: { prefs, _ in prefs.hasReportedHDR = true })
    #expect(h.controller.hasReportedHDR)
    #expect(h.controller.hdrCapabilityProbed == false)

    await h.prime()
    #expect(h.controller.supportsHDR == false)
    #expect(h.controller.hasReportedHDR)
  }

  @Test func theFirstRefreshThatSeesHDRStoresTheReport() async {
    let h = Harness(hdrSupported: true)
    #expect(h.prefs.hasReportedHDR == false)
    await h.prime()
    #expect(h.prefs.hasReportedHDR)
  }

  @Test func aDisplayWithNoHDRStoresNoReport() async {
    let h = Harness(hdrSupported: false)
    await h.prime()
    #expect(h.prefs.hasReportedHDR == false)
  }
}
