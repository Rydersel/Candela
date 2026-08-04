import Foundation
import Testing
@testable import CandelaKit

@Suite("Display card policy")
struct DisplayCardPolicyTests {
  /// The card has three words and the engine has six paths. `native` and
  /// `unavailable` map to nil ON PURPOSE — the card has no vocabulary for them,
  /// and the diagnostics section states both in full. Rendering nil as
  /// "Hardware (DDC) control" is the defect this nil exists to prevent: it is
  /// what the shipped `controlMethod(forceSoftware:avoidGamma:)` did on the
  /// built-in panel, which has no DDC wire at all.
  @Test func theCardHasNoWordForNativeOrForNothingAtAll() {
    #expect(DisplayCardPolicy.controlMethod(for: .native) == nil)
    #expect(DisplayCardPolicy.controlMethod(
      for: .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
    ) == nil)
  }

  @Test func pureDDCAndCombinedBothReadAsHardwareControl() {
    #expect(DisplayCardPolicy.controlMethod(for: .hardware) == .hardwareDDC)
    // Combined is the DEFAULT path and DDC carries the top of its range, so
    // the card's three-way summary calls it hardware. The SPLIT is stated in
    // the diagnostics section, which has room for a sentence.
    #expect(DisplayCardPolicy.controlMethod(
      for: .combined(switchingValue: 0.47, backend: .gamma)
    ) == .hardwareDDC)
    #expect(DisplayCardPolicy.controlMethod(
      for: .combined(switchingValue: 0.47, backend: .overlay)
    ) == .hardwareDDC)
  }

  @Test func theSoftwareLegNamesItsBackend() {
    #expect(DisplayCardPolicy.controlMethod(for: .software(.gamma)) == .softwareGamma)
    #expect(DisplayCardPolicy.controlMethod(for: .software(.overlay)) == .softwareOverlay)
  }

  /// Ruling R-A, enforced one layer above the type that makes it
  /// unrepresentable. `.softwareOnly` is combined mode with its hardware half
  /// not running; answering `.hardwareDDC` here would put "Hardware (DDC)
  /// control" back on a display whose DDC wire is switched off — the exact
  /// untruth the case was carved out of `.combined` to end. The type cannot
  /// catch it, because `.hardwareDDC` is a perfectly well-formed answer.
  @Test func aDeadDDCLegIsNeverCaptionedAsHardwareControl() {
    for backend: SoftwareDimmingBackend in [.gamma, .overlay] {
      let expected: DisplayControlMethod = backend == .overlay ? .softwareOverlay : .softwareGamma
      #expect(DisplayCardPolicy.controlMethod(
        for: .softwareOnly(backend: backend, reason: .ddcTurnedOff, dimsBelow: 0.5)
      ) == expected)
    }
  }

  /// The card word is a function of the PATH alone. Nothing about a display's
  /// prefs may reach this projection except through `BrightnessPathPolicy`: a
  /// prefs-shaped overload is how the shipped row drifted from the engine in the
  /// first place, so the property worth pinning is that every path the policy
  /// can produce already has an answer here.
  @Test func everyPathTheEngineCanProduceHasAnAnswer() {
    var reached = Set<String>()
    for path in Self.everyReachablePath() {
      reached.insert(Self.caseTag(path))
      // The invariant that outranks all the others: a path whose DDC leg is not
      // running never reads as hardware control.
      switch path {
      case .softwareOnly:
        #expect(DisplayCardPolicy.controlMethod(for: path) != .hardwareDDC, "\(path)")
      case .unavailable, .native:
        #expect(DisplayCardPolicy.controlMethod(for: path) == nil, "\(path)")
      case .hardware, .combined:
        #expect(DisplayCardPolicy.controlMethod(for: path) == .hardwareDDC, "\(path)")
      case .software:
        #expect(DisplayCardPolicy.controlMethod(for: path) != .hardwareDDC, "\(path)")
      }
    }
    // Guards the sweep itself: if a future edit narrows the input product so it
    // stops reaching a case, the assertions above quietly stop asserting it.
    #expect(reached.count == 6, "reached \(reached.sorted())")
  }

  /// Every path the policy can produce, swept over the whole input product
  /// rather than over a hand-picked list — a hand-picked list is what a new
  /// seventh case would silently fall out of.
  private static func everyReachablePath() -> [BrightnessPath] {
    var paths: [BrightnessPath] = []
    let flags = [true, false]
    for role in [DisplayRole.builtIn, .external] {
      for hdrMode in [HDRMode.off, .alwaysOn] {
        for (isHDRActive, forceSoftware) in flags.flatMap({ a in flags.map { (a, $0) } }) {
          for (avoidGamma, disableCombined) in flags.flatMap({ a in flags.map { (a, $0) } }) {
            for (unavailableDDC, switching) in flags.flatMap({ a in [0.0, 0.5].map { (a, $0) } }) {
              paths.append(BrightnessPathPolicy.path(.init(
                role: role,
                hdrMode: hdrMode,
                isHDRActive: isHDRActive,
                forceSoftware: forceSoftware,
                avoidGamma: avoidGamma,
                disableCombinedBrightness: disableCombined,
                unavailableDDC: unavailableDDC,
                switchingValue: switching
              )))
            }
          }
        }
      }
    }
    return paths
  }

  private static func caseTag(_ path: BrightnessPath) -> String {
    switch path {
    case .native: "native"
    case .software: "software"
    case .hardware: "hardware"
    case .combined: "combined"
    case .softwareOnly: "softwareOnly"
    case .unavailable: "unavailable"
    }
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
