import Foundation
import Testing
@testable import CandelaKit

@Suite("Checkup verdicts")
struct CheckupVerdictTests {
  @Test func everyVerdictCarriesItsEvidence() {
    let v = CheckupVerdict.observed("achieved 3840 by 2160 at 120 Hz, as macOS reports it")
    #expect(v.kind == "observed")
    #expect(v.text == "achieved 3840 by 2160 at 120 Hz, as macOS reports it")
    #expect(CheckupVerdict.refused("unknown mode id 7").kind == "refused")
    #expect(CheckupVerdict.notObserved("write-only DDC").kind == "notObserved")
    #expect(CheckupVerdict.selfReported("no marks on black").kind == "selfReported")
    #expect(CheckupVerdict.inconclusive("control missed at 4 and 8 px").kind == "inconclusive")
  }

  @Test func verdictsRoundTripThroughJSONWithStableKeys() throws {
    let claim = CheckupClaim(
      family: .refresh, id: "refresh.120", verdict: .observed("120.0 Hz achieved"), detectedAt: nil)
    let data = try JSONEncoder().encode(claim)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"kind\":\"observed\""))
    #expect(text.contains("\"family\":\"refresh\""))
    let back = try JSONDecoder().decode(CheckupClaim.self, from: data)
    #expect(back == claim)
  }

  @Test func anUnknownVerdictKindFailsToDecode() {
    let data = Data("{\"kind\":\"certified\",\"text\":\"x\"}".utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CheckupVerdict.self, from: data) }
  }

  @Test func familiesAreInTheFixedOrder() {
    #expect(CheckupFamily.allCases == [.identity, .capabilities, .nativeMode, .refresh, .visualField, .hdr])
  }

  @Test func scenarioAndPanelClassRawValuesAreSchema() {
    #expect(CheckupScenario.newMonitor.rawValue == "newMonitor")
    #expect(CheckupScenario.usedPurchase.rawValue == "usedPurchase")
    #expect(CheckupScenario.recheck.rawValue == "recheck")
    #expect(CheckupPanelClass.readsDDC.rawValue == "readsDDC")
    #expect(CheckupPanelClass.writeOnlyDDC.rawValue == "writeOnlyDDC")
    #expect(CheckupPanelClass.noDDC.rawValue == "noDDC")
  }
}
