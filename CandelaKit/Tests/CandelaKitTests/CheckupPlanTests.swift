import Testing
@testable import CandelaKit

@Suite("Checkup plan")
struct CheckupPlanTests {
  private let dellCaps = "(prot(monitor)type(lcd)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14 16 18 1A 52 60 87 AC AE B2 B6 C6 C8 C9 D6 DC DF E0 E1 E2 E4 E5 E6 E7 E8 E9 EA EB ED F0 F1 F2)mccs_ver(2.1))"

  @Test func aParsedCapabilitiesStringReadsDDC() {
    #expect(CheckupPlan.panelClass(capabilities: dellCaps, hasDDCService: true, isBuiltIn: false) == .readsDDC)
  }

  @Test func aDDCServiceWithNoCapabilitiesIsWriteOnly() {
    #expect(CheckupPlan.panelClass(capabilities: nil, hasDDCService: true, isBuiltIn: false) == .writeOnlyDDC)
    #expect(CheckupPlan.panelClass(capabilities: "", hasDDCService: true, isBuiltIn: false) == .writeOnlyDDC)
  }

  @Test func builtInAndServicelessDisplaysHaveNoDDC() {
    #expect(CheckupPlan.panelClass(capabilities: dellCaps, hasDDCService: true, isBuiltIn: true) == .noDDC)
    #expect(CheckupPlan.panelClass(capabilities: nil, hasDDCService: false, isBuiltIn: false) == .noDDC)
  }

  @Test func theWriteOnlyPlanPregradesEveryCapabilityRow() {
    let plan = CheckupPlan.make(panelClass: .writeOnlyDDC, hdrEngaged: false)
    let caps = plan.filter { $0.family == .capabilities }
    #expect(caps.count == 3)
    #expect(caps.allSatisfy { $0.pregraded?.kind == "notObserved" })
    #expect(caps.first?.pregraded?.text.contains("write-only") == true)
    #expect(plan.filter { $0.family == .refresh }.allSatisfy { $0.pregraded == nil })
  }

  @Test func theReadsDDCPlanPregradesNothing() {
    #expect(CheckupPlan.make(panelClass: .readsDDC, hdrEngaged: false).allSatisfy { $0.pregraded == nil })
  }

  @Test func planOrderFollowsTheFamilyOrder() {
    let families = CheckupPlan.make(panelClass: .readsDDC, hdrEngaged: false).map(\.family)
    #expect(families == families.sorted { a, b in
      CheckupFamily.allCases.firstIndex(of: a)! < CheckupFamily.allCases.firstIndex(of: b)!
    })
    #expect(CheckupPlan.make(panelClass: .readsDDC, hdrEngaged: false).map(\.id).first == CheckupCheckID.identity)
  }

  @Test func refreshIdsKeepOneDecimalSoNTSCDoesNotCollideWithSixty() {
    #expect(CheckupCheckID.refresh(hz: 60) == "refresh.60")
    #expect(CheckupCheckID.refresh(hz: 59.9) == "refresh.59.9")
    #expect(CheckupCheckID.refresh(hz: 59.9) != CheckupCheckID.refresh(hz: 60))
    // The float noise CoreGraphics actually reports lands on the same ids.
    #expect(CheckupCheckID.refresh(hz: 59.9998) == "refresh.60")
    #expect(CheckupCheckID.refresh(hz: 59.94) == "refresh.59.9")
    #expect(CheckupCheckID.refresh(hz: 119.88) == "refresh.119.9")
  }

  /// A run started with the panel in HDR cannot read DDC at all, so the three
  /// capability rows say so instead of blaming the panel. The write-only text is
  /// the one that would be false on a Dell whose cached string never arrived.
  @Test func anHDREngagedRunPregradesTheCapabilityRowsWithTheHDRReason() {
    for panelClass in [CheckupPanelClass.readsDDC, .writeOnlyDDC] {
      let caps = CheckupPlan.make(panelClass: panelClass, hdrEngaged: true)
        .filter { $0.family == .capabilities }
      #expect(caps.count == 3)
      #expect(caps.allSatisfy { $0.pregraded == .notObserved(CheckupPlan.hdrEngagedCapabilityText) })
      #expect(caps.allSatisfy { $0.pregraded?.text.contains("HDR mode") == true })
      #expect(caps.allSatisfy { $0.pregraded?.text.contains("write-only") == false })
    }
    // Nothing outside the capability family is pre-graded by HDR.
    #expect(
      CheckupPlan.make(panelClass: .readsDDC, hdrEngaged: true)
        .filter { $0.family != .capabilities }
        .allSatisfy { $0.pregraded == nil })
  }

  /// A display with no DDC path has no DDC path in or out of HDR, and its own
  /// reason is the true one.
  @Test func noDDCKeepsItsOwnReasonWhileHDRIsEngaged() {
    let caps = CheckupPlan.make(panelClass: .noDDC, hdrEngaged: true)
      .filter { $0.family == .capabilities }
    #expect(caps.allSatisfy { $0.pregraded?.text.contains("no DDC path") == true })
  }

  @Test func worstCaseFieldTimeIsThreeShowingsOfEveryField() {
    // 8 pixel and gray fields at 20 s, white at 10 s, witness at 20 s, each up
    // to 3 showings, plus one confirmation re-show per plant field at that
    // field's own cap: 4 pixel fields at 20 s and white at 10 s.
    #expect(CheckupPlan.worstCaseFieldSeconds == (7 * 20 + 10 + 20) * 3 + (4 * 20 + 10))
    #expect(CheckupPlan.worstCaseFieldSeconds == 600)
  }
}
