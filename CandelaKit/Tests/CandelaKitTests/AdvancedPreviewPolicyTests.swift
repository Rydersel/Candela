import Testing
@testable import CandelaKit

@Suite("Advanced chevron preview")
struct AdvancedPreviewPolicyTests {
  @Test func defaultWhenNothingIsSet() {
    #expect(AdvancedPreviewPolicy.label(for: .init(ddcOff: false, overlayOn: false, osdHidden: false, overrideCount: 0)) == "Default")
  }

  @Test func hardwareOffDominatesEverything() {
    #expect(AdvancedPreviewPolicy.label(for: .init(ddcOff: true, overlayOn: true, osdHidden: true, overrideCount: 4)) == "Hardware control off")
  }

  @Test func overlayOutranksCounts() {
    #expect(AdvancedPreviewPolicy.label(for: .init(ddcOff: false, overlayOn: true, osdHidden: false, overrideCount: 2)) == "Screen overlay")
  }

  @Test func countsPluraliseAndIncludeOsd() {
    #expect(AdvancedPreviewPolicy.label(for: .init(ddcOff: false, overlayOn: false, osdHidden: true, overrideCount: 0)) == "1 override")
    #expect(AdvancedPreviewPolicy.label(for: .init(ddcOff: false, overlayOn: false, osdHidden: false, overrideCount: 3)) == "3 overrides")
  }
}
