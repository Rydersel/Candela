import Foundation
import Testing
@testable import CandelaKit

@Suite("Display card policy")
struct DisplayCardPolicyTests {
  /// The card's subtitle is the app's only statement of HOW a display is being
  /// driven. Inverting the avoidGamma arm is a one-character edit that makes
  /// the diagnostic permanently wrong with no other symptom (lens-4 H6).
  @Test func theControlMethodDescribesTheActivePath() {
    #expect(DisplayCardPolicy.controlMethod(forceSoftware: false, avoidGamma: false) == .hardwareDDC)
    // avoidGamma is inert while DDC drives the display: `applyPaths` only
    // reaches `applySoftware` on the forceSoftware/combined legs.
    #expect(DisplayCardPolicy.controlMethod(forceSoftware: false, avoidGamma: true) == .hardwareDDC)
    #expect(DisplayCardPolicy.controlMethod(forceSoftware: true, avoidGamma: false) == .softwareGamma)
    #expect(DisplayCardPolicy.controlMethod(forceSoftware: true, avoidGamma: true) == .softwareOverlay)
  }

  /// "" means "use the name the display reports". The rule has to be the same
  /// one the panel's title fallback uses, or a pasted name with a trailing
  /// newline persists as non-empty and still renders as the hardware name.
  @Test func aNameIsUnsetWhenItIsBlankUnderAnyWhitespaceRule() {
    for blank in ["", " ", "\n", " \t\n ", "\r\n"] {
      #expect(DisplayCardPolicy.normalizedFriendlyName(blank) == "", "\(blank.debugDescription)")
    }
    #expect(DisplayCardPolicy.normalizedFriendlyName("  Desk \n") == "Desk")
    #expect(DisplayCardPolicy.normalizedFriendlyName("Desk") == "Desk")
  }
}
