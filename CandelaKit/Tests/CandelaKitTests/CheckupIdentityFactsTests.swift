import Testing
@testable import CandelaKit

@Suite("Checkup identity facts")
struct CheckupIdentityFactsTests {
  @Test func aFullRecordParsesEveryField() {
    let attrs: [String: Any] = [
      "ProductAttributes": [
        "ManufacturerID": "DEL", "ProductName": "DELL U2725QE",
        "SerialNumber": Int64(1_144_206_156), "AlphanumericSerialNumber": "1CHB884",
        "WeekOfManufacture": 51, "YearOfManufacture": 2025,
      ] as [String: Any],
      "SupportsPQEOTF": false, "SupportsHDRGammaEOTF": false,
    ]
    let id = CheckupIdentityFacts.parse(
      displayAttributes: attrs, identityKey: "10ac-a0b2-4436", vendorID: 0x10AC, modelID: 0xA0B2,
      nativePixels: (3840, 2160), maxRefreshHz: 120)
    #expect(id.serial == "1CHB884")
    #expect(id.manufactureWeek == 51)
    #expect(id.manufactureYear == 2025)
    #expect(id.productName == "DELL U2725QE")
    #expect(id.supportsPQEOTF == false)
    #expect(id.nativePixelWidth == 3840)
  }

  @Test func aMAGStyleRecordReportsNoSerialAndItsEOTFFlags() {
    let attrs: [String: Any] = [
      "ProductAttributes": ["ManufacturerID": "MSI", "ProductName": "MAG 341C", "SerialNumber": Int64(0)] as [String: Any],
      "SupportsPQEOTF": true, "SupportsHDRGammaEOTF": true,
    ]
    let id = CheckupIdentityFacts.parse(
      displayAttributes: attrs, identityKey: "k", vendorID: 1, modelID: 2,
      nativePixels: (3440, 1440), maxRefreshHz: 175)
    #expect(id.serial == CheckupDisplayIdentity.noSerial)
    #expect(id.manufactureWeek == nil)
    #expect(id.supportsPQEOTF && id.supportsHDRGammaEOTF)
  }

  @Test func aNumericSerialIsUsedWhenNoAlphanumericOneExists() {
    let attrs: [String: Any] = ["ProductAttributes": ["SerialNumber": Int64(42)] as [String: Any]]
    let id = CheckupIdentityFacts.parse(
      displayAttributes: attrs, identityKey: "k", vendorID: 1, modelID: 2,
      nativePixels: (1, 1), maxRefreshHz: nil)
    #expect(id.serial == "42")
    #expect(id.productName == "")
  }

  /// The record's nesting was measurable for the manufacture date and serials
  /// (inside `ProductAttributes`) but not for the EOTF flags, which no panel
  /// attached during this task reports. Whichever level a panel puts them at,
  /// the answer must be the panel's own, never a defaulted "no".
  @Test func eotfFlagsAreFoundAtEitherLevelOfTheRecord() {
    let nested: [String: Any] = [
      "ProductAttributes": [
        "ProductName": "MAG 341C", "SupportsPQEOTF": true, "SupportsHDRGammaEOTF": true,
        "WeekOfManufacture": 29, "YearOfManufacture": 2023,
      ] as [String: Any],
    ]
    let id = CheckupIdentityFacts.parse(
      displayAttributes: nested, identityKey: "k", vendorID: 1, modelID: 2,
      nativePixels: (3440, 1440), maxRefreshHz: 175)
    #expect(id.supportsPQEOTF && id.supportsHDRGammaEOTF)
    #expect(id.manufactureWeek == 29)
    #expect(id.manufactureYear == 2023)
  }

  @Test func anEmptyRecordReportsAbsenceRatherThanInventingValues() {
    let id = CheckupIdentityFacts.parse(
      displayAttributes: [:], identityKey: "k", vendorID: 1, modelID: 2,
      nativePixels: (1512, 982), maxRefreshHz: nil)
    #expect(id.serial == CheckupDisplayIdentity.noSerial)
    #expect(id.manufactureWeek == nil)
    #expect(id.manufactureYear == nil)
    #expect(id.productName == "")
    #expect(!id.supportsPQEOTF && !id.supportsHDRGammaEOTF)
  }
}
