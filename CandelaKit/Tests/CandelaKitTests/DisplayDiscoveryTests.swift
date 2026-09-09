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
