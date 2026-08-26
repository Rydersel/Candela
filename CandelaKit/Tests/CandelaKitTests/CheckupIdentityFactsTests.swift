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

  /// No attached panel reports the EOTF flags, so their level was not measured.
  /// Whichever level a panel uses, the answer must be its own, never a defaulted "no".
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

/// The selection half of `Arm64DDC.displayAttributes`; the walk itself needs
/// live `io_service_t` handles and cannot be tested here.
@Suite("Checkup identity entry selection")
struct CheckupIdentityEntrySelectionTests {
  private func record(_ name: String) -> [String: Any] {
    ["ProductAttributes": ["ProductName": name] as [String: Any]]
  }

  @Test func theHighestScoringEntryWinsWhateverTheWalkOrder() {
    let chosen = Arm64DDC.bestMatchingRecord(among: [
      (4, { self.record("same vendor twin") }),
      (14, { self.record("the right panel") }),
    ])
    #expect((chosen?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String == "the right panel")
  }

  /// A twin scoring on EDID fields must not supply the record when the location
  /// winner has none; a twin's record parses perfectly, so the wrong answer looks right.
  @Test func aWinnerWithNoReadableRecordYieldsNothingRatherThanALoserMatch() {
    let chosen = Arm64DDC.bestMatchingRecord(among: [
      (4, { self.record("same vendor twin") }),
      (14, { nil }),
    ])
    #expect(chosen == nil)
  }

  @Test func tiesResolveToTheFirstEntryInWalkOrder() {
    let chosen = Arm64DDC.bestMatchingRecord(among: [
      (10, { self.record("first") }),
      (10, { self.record("second") }),
    ])
    #expect((chosen?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String == "first")
  }

  @Test func nothingScoringAboveZeroIsAnAbsentRecord() {
    #expect(Arm64DDC.bestMatchingRecord(among: [(0, { self.record("a") }), (0, { self.record("b") })]) == nil)
    #expect(Arm64DDC.bestMatchingRecord(among: []) == nil)
  }

  @Test func onlyTheWinnersRecordIsEverRead() {
    final class Counter: @unchecked Sendable {
      // Confined to this test's single thread; the closures run synchronously
      // inside bestMatchingRecord before the test reads the counts back.
      var reads: [String] = []
    }
    let counter = Counter()
    _ = Arm64DDC.bestMatchingRecord(among: [
      (4, { counter.reads.append("loser"); return self.record("loser") }),
      (14, { counter.reads.append("winner"); return self.record("winner") }),
    ])
    #expect(counter.reads == ["winner"])
  }
}
