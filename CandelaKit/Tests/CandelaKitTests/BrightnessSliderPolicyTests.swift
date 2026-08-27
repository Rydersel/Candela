import Testing
@testable import CandelaKit

@Suite("Brightness slider reason (WD5)")
struct BrightnessSliderPolicyTests {
  private func reason(_ path: BrightnessPath, wireUnresponsive: Bool = true) -> String? {
    BrightnessSliderPolicy.compactDegradedReason(
      path: path, isWireUnresponsive: wireUnresponsive
    )
  }

  @Test func theWiresOwnPathsCarryTheSentence() {
    #expect(reason(.softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.5))
      == BrightnessSliderPolicy.wireUnresponsiveReason)
    #expect(reason(.softwareOnly(backend: .overlay, reason: .ddcUnresponsive, dimsBelow: 0.5))
      == BrightnessSliderPolicy.wireUnresponsiveReason)
    #expect(reason(.unavailable(.ddcUnresponsiveWithNoSoftwareLeg))
      == BrightnessSliderPolicy.wireUnresponsiveReason)
  }

  /// Pure-DDC configuration demotes to the same full-range software leg
  /// force-software selects, so the path cannot tell them apart and the wire's
  /// verdict has to.
  @Test func theFullRangeSoftwareLegNeedsTheWiresVerdictToBeReadable() {
    #expect(reason(.software(.gamma)) == BrightnessSliderPolicy.wireUnresponsiveReason)
    #expect(reason(.software(.gamma), wireUnresponsive: false) == nil)
  }

  /// The user's own switch outranks the wire (WD2), so the caption must not
  /// blame the display for a control a person turned off.
  @Test func aCommandTheUserTurnedOffIsNeverBlamedOnTheDisplay() {
    #expect(reason(.softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.5)) == nil)
    #expect(reason(.unavailable(.ddcTurnedOffWithNoSoftwareLeg)) == nil)
  }

  /// Nothing is said about a display that is working, and nothing is said under
  /// live HDR either: macOS carries brightness there and the locked register is
  /// normal life, not a fault.
  @Test func aWorkingDisplaySaysNothing() {
    #expect(reason(.hardware, wireUnresponsive: false) == nil)
    #expect(reason(.combined(switchingValue: 0.5, backend: .gamma), wireUnresponsive: false) == nil)
    #expect(reason(.native) == nil)
    #expect(reason(.hardware) == nil)
  }

  @Test func theSentenceCarriesNoEmDash() {
    #expect(!BrightnessSliderPolicy.wireUnresponsiveReason.contains("—"))
  }
}
