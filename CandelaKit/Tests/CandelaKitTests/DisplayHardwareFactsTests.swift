import Foundation
import Testing
@testable import CandelaKit

@Suite("Display hardware facts (B8)")
struct DisplayHardwareFactsTests {
  private func service(
    manufacturerID: String = "MSI",
    serialNumber: Int64 = 0,
    alphanumericSerialNumber: String = "",
    transportUpstream: String = "",
    transportDownstream: String = "",
    ioDisplayLocation: String = ""
  ) -> Arm64DDC.IOregService {
    var s = Arm64DDC.IOregService()
    s.manufacturerID = manufacturerID
    s.serialNumber = serialNumber
    s.alphanumericSerialNumber = alphanumericSerialNumber
    s.transportUpstream = transportUpstream
    s.transportDownstream = transportDownstream
    s.ioDisplayLocation = ioDisplayLocation
    return s
  }

  /// "This monitor is on DisplayPort" is the marquee diagnostic in the whole
  /// feature and every byte of it is already read from the kernel on every
  /// discovery pass. Pinned so a future tidy-up of `IOregService` cannot drop
  /// it again silently.
  @Test func transportAndManufacturerSurviveDiscovery() {
    let facts = DisplayHardwareFacts.from(
      service: service(transportUpstream: "DP", transportDownstream: "DP"),
      matchScore: 13, physicalSizeCm: (80, 34)
    )
    #expect(facts.transportUpstream == "DP")
    #expect(facts.transportDownstream == "DP")
    #expect(facts.manufacturerID == "MSI")
    #expect(facts.ioregMatchScore == 13)
    #expect(facts.physicalWidthCm == 80)
    #expect(facts.physicalHeightCm == 34)
  }

  /// `IOregService`'s string fields default to `""` and its serial to `0`
  /// rather than to nil, so "the panel declared nothing" and "the panel
  /// declared an empty string" arrive identical. Translating that here is what
  /// stops a row rendering a blank value where a reason was promised
  /// (DT30 rule e).
  @Test func aPanelThatDeclaredNothingReportsNilNotAnEmptyString() {
    let facts = DisplayHardwareFacts.from(
      service: service(manufacturerID: ""), matchScore: 0, physicalSizeCm: nil
    )
    #expect(facts.manufacturerID == nil)
    #expect(facts.transportUpstream == nil)
    #expect(facts.transportDownstream == nil)
    #expect(facts.alphanumericSerialNumber == nil)
    #expect(facts.ioDisplayLocation == nil)
    #expect(facts.physicalWidthCm == nil)
    #expect(facts.physicalHeightCm == nil)
  }

  /// The MAG 341C reports numeric serial 0 and that is exactly what makes two
  /// identical units collide on `persistenceKey`. 0 is "no serial", not
  /// "serial number zero", and the caveat row keys off this nil.
  @Test func aNumericSerialOfZeroIsNoSerialAtAll() {
    #expect(DisplayHardwareFacts.from(
      service: service(serialNumber: 0), matchScore: 0, physicalSizeCm: nil
    ).numericSerialNumber == nil)
    #expect(DisplayHardwareFacts.from(
      service: service(serialNumber: 918_273), matchScore: 0, physicalSizeCm: nil
    ).numericSerialNumber == 918_273)
  }

  /// The OTHER serial is often populated when the numeric one is 0 — which is
  /// the whole reason both are carried rather than one.
  @Test func theAlphanumericSerialIsCarriedSeparatelyFromTheNumericOne() {
    let facts = DisplayHardwareFacts.from(
      service: service(serialNumber: 0, alphanumericSerialNumber: "CN0J9K"),
      matchScore: 0, physicalSizeCm: nil
    )
    #expect(facts.numericSerialNumber == nil)
    #expect(facts.alphanumericSerialNumber == "CN0J9K")
  }

  /// Two `Int?` fields rather than a tuple: a tuple member blocks synthesized
  /// `Equatable`, and this type is compared in a `[String: DisplayHardwareFacts]`.
  @Test func factsAreEquatableSoTheyCanLiveInAnObservableDictionary() {
    let a = DisplayHardwareFacts.from(service: service(), matchScore: 5, physicalSizeCm: (80, 34))
    let b = DisplayHardwareFacts.from(service: service(), matchScore: 5, physicalSizeCm: (80, 34))
    let c = DisplayHardwareFacts.from(service: service(), matchScore: 4, physicalSizeCm: (80, 34))
    #expect(a == b)
    #expect(a != c)
  }
}
