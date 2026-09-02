import Testing
@testable import CandelaKit

@Suite("Brightness slider reason")
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

  /// Pure-DDC demotes to the same full-range software leg force-software
  /// selects, so only the wire's verdict can tell them apart.
  @Test func theFullRangeSoftwareLegNeedsTheWiresVerdictToBeReadable() {
    #expect(reason(.software(.gamma)) == BrightnessSliderPolicy.wireUnresponsiveReason)
    #expect(reason(.software(.gamma), wireUnresponsive: false) == nil)
  }

  /// The caption must not blame the display for a control a person turned
  /// off.
  @Test func aCommandTheUserTurnedOffIsNeverBlamedOnTheDisplay() {
    #expect(reason(.softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.5)) == nil)
    #expect(reason(.unavailable(.ddcTurnedOffWithNoSoftwareLeg)) == nil)
  }

  /// Nothing said about a working display, and nothing under live HDR: macOS
  /// carries brightness there and the locked register is not a fault.
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
