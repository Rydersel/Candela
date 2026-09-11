import CoreGraphics
import Foundation
import IOKit
import Testing
@testable import CandelaKit

@Test func displayNamePrefersIORegProductName() {
  var service = Arm64DDC.IOregService()
  service.productName = "MAG 341C OLED"
  #expect(DisplayDiscovery.displayName(from: service, displayID: 5) == "MAG 341C OLED")
}

@Test func displayNameFallsBackToDisplayID() {
  let service = Arm64DDC.IOregService()  // productName == ""
  #expect(DisplayDiscovery.displayName(from: service, displayID: 5) == "Display 5")
}

/// The discovery walk itself needs IOKit, so the reason-assignment rule is a pure
/// function and these pin that instead.
private func serviceMatch(
  _ displayID: CGDirectDisplayID, isDummy: Bool = false, hasService: Bool = true,
  manufacturerID: String = "", productName: String = ""
) -> DisplayDiscovery.ServiceMatch {
  .init(displayID: displayID, isDummy: isDummy, hasService: hasService,
        manufacturerID: manufacturerID, productName: productName)
}

private func exclusionReasons(
  candidates: [CGDirectDisplayID], matches: [DisplayDiscovery.ServiceMatch]
) -> [CGDirectDisplayID: DisplayExclusionReason] {
  let excluded = DisplayDiscovery.excluded(
    policyDrops: [], candidates: candidates, matches: matches, identity: { _ in (0, 0) })
  return Dictionary(uniqueKeysWithValues: excluded.map { ($0.displayID, $0.reason) })
}

/// `getServiceMatches` returns only MATCHED services, so a candidate that scored
/// nothing is absent from its answer rather than present with a nil service.
/// Anything inspecting only what came back cannot see this display at all.
@Test func aCandidateThatMatchedNoServiceIsRecordedAsHavingNone() {
  let reasons = exclusionReasons(candidates: [2, 3], matches: [serviceMatch(2)])
  #expect(reasons[3] == .noDDCService)
  #expect(reasons[2] == nil)
}

/// One filter drops on two unrelated facts. A dummy plug HAS a service, so
/// collapsing the halves would tell the reader to go looking for a cable fault.
@Test func aDummyIsNotReportedAsAMissingService() {
  #expect(exclusionReasons(candidates: [2], matches: [serviceMatch(2, isDummy: true)])[2] == .dummy)
}

@Test func aMatchWithNoServiceIsReportedAsAMissingService() {
  #expect(exclusionReasons(candidates: [2], matches: [serviceMatch(2, hasService: false)])[2] == .noDDCService)
}

/// The report is pasted into public issues. Asserted over the whole value, so a
/// field ADDED later that carries an identifier fails this too.
@Test func theExcludedListCarriesNoSerialOrIdentityKey() {
  var details = Arm64DDC.IOregService()
  details.manufacturerID = "DEL"
  details.productName = "U2725QE"
  details.edidUUID = "PRIVATE-EDID-4C2D"
  details.alphanumericSerialNumber = "PRIVATE-SERIAL-987"
  details.serialNumber = 7_391_955
  let match = Arm64DDC.Arm64Service(
    displayID: 3, service: nil, serviceLocation: 0, dummy: false, serviceDetails: details,
    matchScore: 1)
  let excluded = DisplayDiscovery.excluded(
    policyDrops: [], candidates: [3], matches: [.init(match)], identity: { _ in (0x10AC, 0x4C2D) })
  let described = String(describing: excluded)
  #expect(excluded.map(\.manufacturerID) == ["DEL"])
  #expect(excluded.map(\.productName) == ["U2725QE"])
  #expect(!described.contains("PRIVATE-SERIAL-987"))
  #expect(!described.contains("PRIVATE-EDID-4C2D"))
  #expect(!described.contains("7391955"))
}

/// A drop before service matching has no IOReg strings, and an empty string is not
/// a name: the report needs nil to fall back to the vendor and model numbers.
@Test func aDropBeforeServiceMatchingCarriesNoNames() {
  let excluded = DisplayDiscovery.excluded(
    policyDrops: [(1, .builtIn)], candidates: [2], matches: [serviceMatch(2, hasService: false)],
    identity: { _ in (0, 0) })
  #expect(excluded.map(\.reason) == [.builtIn, .noDDCService])
  #expect(excluded.allSatisfy { $0.manufacturerID == nil && $0.productName == nil })
}

/// The count call and the fill call fail independently, and only the fill call
/// decides the control pool. Taking DDC away from every display over a missing
/// number is the failure this pins.
@Test func aRefusedOnlineCountLeavesTheSurvivorsAndClaimsNoSlotCap() {
  let drop = DisplayDiscoveryReport.Excluded(
    displayID: 3, vendorNumber: 0x10AC, modelNumber: 0x4C2D, manufacturerID: "DEL",
    productName: "U2725QE", reason: .noDDCService)
  let report = DisplayDiscoveryReport.counted(
    excluded: [drop], onlineTotal: nil, slotCapacity: 32)
  #expect(report.onlineListRefusal == .count)
  #expect(report.onlineCount == nil)
  // Derived from the count, so a missing count withdraws the claim.
  #expect(!report.slotCapReached)
  #expect(report.excluded == [drop])
}

/// The answered case, including the boundary: a desk that exactly fills the
/// buffer was not truncated, so the cap line must not appear.
@Test(arguments: [(UInt32(31), false), (UInt32(32), false), (UInt32(40), true)])
func anAnsweredCountCarriesItsSlotCapVerdict(onlineTotal: UInt32, capReached: Bool) {
  let report = DisplayDiscoveryReport.counted(
    excluded: [], onlineTotal: onlineTotal, slotCapacity: 32)
  #expect(report.onlineListRefusal == nil)
  #expect(report.onlineCount == Int(onlineTotal))
  #expect(report.slotCapReached == capReached)
}

/// Stands in for `CoreDisplay_DisplayCreateInfoDictionary` so the scoring
/// arithmetic can be pinned.
private enum MatchScoreFixture {
  /// EDID UUID whose four scored windows (offsets 0, 4, 19 and 30) carry the
  /// vendor, product, manufacture-date and image-size keys the fixture declares.
  static let edidUUID = "1234" + "7856" + "0000-0000-0" + "141F" + "-000000" + "4628"
  static let location = "IOService:/AppleARMPE/dcp@1/AppleCLCD2"
  static let productName = "MAG 341C OLED"
  static let serialNumber: Int64 = 1_234_567

  /// A function, not a stored constant: `NSDictionary` is not `Sendable`.
  static func dictionary() -> NSDictionary {
    [
      kDisplayVendorID: NSNumber(value: Int64(0x1234)),
      kDisplayProductID: NSNumber(value: Int64(0x5678)),
      kDisplayWeekOfManufacture: NSNumber(value: Int64(20)),
      kDisplayYearOfManufacture: NSNumber(value: Int64(2021)),
      kDisplayHorizontalImageSize: NSNumber(value: Int64(700)),
      kDisplayVerticalImageSize: NSNumber(value: Int64(400)),
      kIODisplayLocationKey: location,
      "DisplayProductName": ["en_US": productName],
      kDisplaySerialNumber: NSNumber(value: serialNumber),
    ] as NSDictionary
  }
}

@Test func matchScoreSumsEveryAgreement() {
  let score = Arm64DDC.ioregMatchScore(
    displayInfo: MatchScoreFixture.dictionary(),
    ioregEdidUUID: MatchScoreFixture.edidUUID,
    ioDisplayLocation: MatchScoreFixture.location,
    ioregProductName: MatchScoreFixture.productName.lowercased(),
    ioregSerialNumber: MatchScoreFixture.serialNumber
  )
  // Four EDID windows, the location worth ten on its own, name and serial.
  #expect(score == 16)
}

@Test func matchScoreCountsOnlyTheEdidWindowsWhenTheServiceDiffers() {
  let score = Arm64DDC.ioregMatchScore(
    displayInfo: MatchScoreFixture.dictionary(),
    ioregEdidUUID: MatchScoreFixture.edidUUID,
    ioDisplayLocation: "IOService:/AppleARMPE/dcp@0/AppleCLCD2",
    ioregProductName: "U2725QE",
    ioregSerialNumber: 7
  )
  #expect(score == 4)
}

@Test func matchScoreDropsTheEdidWindowsThatDisagree() {
  let score = Arm64DDC.ioregMatchScore(
    displayInfo: MatchScoreFixture.dictionary(),
    ioregEdidUUID: "0000" + "7856" + "0000-0000-0" + "141F" + "-000000" + "0000",
    ioDisplayLocation: "",
    ioregProductName: "",
    ioregSerialNumber: 0
  )
  #expect(score == 2)
}

@Test func matchScoreIsZeroWithoutADisplayInfoDictionary() {
  let score = Arm64DDC.ioregMatchScore(
    displayInfo: nil,
    ioregEdidUUID: MatchScoreFixture.edidUUID,
    ioDisplayLocation: MatchScoreFixture.location,
    ioregProductName: MatchScoreFixture.productName,
    ioregSerialNumber: MatchScoreFixture.serialNumber
  )
  #expect(score == 0)
}
