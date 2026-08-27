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
      for (isHDRActive, forceSoftware) in flags.flatMap({ a in flags.map { (a, $0) } }) {
        for (avoidGamma, disableCombined) in flags.flatMap({ a in flags.map { (a, $0) } }) {
          for (unavailableDDC, switching) in flags.flatMap({ a in [0.0, 0.5].map { (a, $0) } }) {
            paths.append(BrightnessPathPolicy.path(.init(
              role: role,
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

  // MARK: - DDC traffic

  /// The defect the projection exists to remove. `CommandTuningGrid` gated on
  /// `prefs.forceSoftware` alone, so a display in live HDR — where DDC is dead
  /// outright — presented an editable grid whose every write went nowhere.
  @Test func liveHDRSilencesTheWireAndTheGridHasToSaySo() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(for: .native) == .macOSDrivesBrightness)
  }

  @Test func hardwareControlOffIsNamedSeparatelyFromMacOSDrivingBrightness() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(for: .software(.gamma)) == .hardwareControlOff)
    #expect(DisplayCardPolicy.ddcTrafficBlock(for: .software(.overlay)) == .hardwareControlOff)
  }

  /// The direction that would COST the user controls. Both of these paths are
  /// reached from the BRIGHTNESS command's own `unavailableDDC`, and that says
  /// nothing whatever about volume or contrast — they still write over the same
  /// wire. Greying the grid here would remove two working controls to report a
  /// third one's setting.
  @Test func aBrightnessOnlyBlockNeverGreysVolumeAndContrast() {
    for backend: SoftwareDimmingBackend in [.gamma, .overlay] {
      #expect(DisplayCardPolicy.ddcTrafficBlock(
        for: .softwareOnly(backend: backend, reason: .ddcTurnedOff, dimsBelow: 0.4)
      ) == nil)
    }
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
    ) == nil)
  }

  @Test func aLiveWireReportsNoBlock() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(for: .hardware) == nil)
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .combined(switchingValue: 0.47, backend: .gamma)
    ) == nil)
  }

  /// Same sweep, same reason as `everyPathTheEngineCanProduceHasAnAnswer`: the
  /// property is over every path the engine can actually produce, not over a
  /// hand-picked list a seventh case would fall out of.
  @Test func everyPathTheEngineCanProduceHasATrafficVerdict() {
    var reached = Set<String>()
    for path in Self.everyReachablePath() {
      reached.insert(Self.caseTag(path))
      let block = DisplayCardPolicy.ddcTrafficBlock(for: path)
      switch path {
      case .native:
        #expect(block == .macOSDrivesBrightness, "\(path)")
      case .software:
        #expect(block == .hardwareControlOff, "\(path)")
      case .hardware, .combined, .softwareOnly, .unavailable:
        #expect(block == nil, "\(path)")
      }
    }
    #expect(reached.count == 6, "reached \(reached.sorted())")
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

  /// WD2's ambiguity, and the one place it bites. In pure-DDC configuration a
  /// wire that stopped answering routes the same `.software` path force-software
  /// does, and greying the DDC grid there would caption a display nobody touched
  /// with "hardware control is off". It answers nil for `.softwareOnly`'s reason:
  /// the brightness command is not landing, and volume and contrast still write
  /// over the same wire.
  @Test func aWireThatStoppedAnsweringDoesNotClaimHardwareControlWasTurnedOff() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .software(.gamma), isWireUnresponsive: true
    ) == nil)
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .software(.overlay), isWireUnresponsive: true
    ) == nil)
    // The switch still blocks, which is the fact the nil above must not erase.
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .software(.gamma), isWireUnresponsive: false
    ) == .hardwareControlOff)
  }

  /// Live HDR outranks the wire in this projection too: macOS is driving the
  /// display, which is a different sentence and the only one that is true there.
  @Test func liveHDRStillNamesMacOSEvenWithAnUnresponsiveWire() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .native, isWireUnresponsive: true
    ) == .macOSDrivesBrightness)
  }
}
