import Foundation
import Testing
@testable import CandelaKit

@Suite("Display card policy")
struct DisplayCardPolicyTests {
  /// `native` and `unavailable` map to nil on purpose: the card has no vocabulary
  /// for them and diagnostics states both in full. Rendering that nil as "Hardware
  /// (DDC) control" is the defect, and it captioned the built-in panel that way.
  @Test func theCardHasNoWordForNativeOrForNothingAtAll() {
    #expect(DisplayCardPolicy.controlMethod(for: .native) == nil)
    #expect(DisplayCardPolicy.controlMethod(
      for: .unavailable(.ddcTurnedOffWithNoSoftwareLeg)
    ) == nil)
  }

  @Test func pureDDCAndCombinedBothReadAsHardwareControl() {
    #expect(DisplayCardPolicy.controlMethod(for: .hardware) == .hardwareDDC)
    // Combined is the default path and DDC carries the top of its range, so the
    // card calls it hardware. Diagnostics has room to state the split.
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

  /// Ruling R-A. `.softwareOnly` is combined mode with its hardware half stopped,
  /// so answering `.hardwareDDC` captions a display whose DDC wire is switched off
  /// as hardware-controlled. The type cannot catch it: that answer is well-formed.
  @Test func aDeadDDCLegIsNeverCaptionedAsHardwareControl() {
    for backend: SoftwareDimmingBackend in [.gamma, .overlay] {
      let expected: DisplayControlMethod = backend == .overlay ? .softwareOverlay : .softwareGamma
      #expect(DisplayCardPolicy.controlMethod(
        for: .softwareOnly(backend: backend, reason: .ddcTurnedOff, dimsBelow: 0.5)
      ) == expected)
    }
  }

  /// The card word is a function of the path alone. A prefs-shaped overload is how
  /// the shipped row drifted from the engine, so nothing about a display's prefs
  /// reaches this projection except through `BrightnessPathPolicy`.
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

  /// Swept over the whole input product rather than a hand-picked list, which a new
  /// `BrightnessPath` case would silently fall out of.
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

  /// Both paths are reached from the brightness command's own `unavailableDDC`,
  /// which says nothing about volume or contrast: they still write over the same
  /// wire. Greying the grid here removes working controls to report another's setting.
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

  /// Same sweep and same reason as `everyPathTheEngineCanProduceHasAnAnswer`: over
  /// every path the engine can produce, not a hand-picked list.
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

  /// WD2's ambiguity, and the one place it bites: greying the DDC grid here
  /// would caption a display nobody touched with "hardware control is off".
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

  /// Live HDR outranks the wire here too: macOS is driving the display, which is
  /// the only true sentence there.
  @Test func liveHDRStillNamesMacOSEvenWithAnUnresponsiveWire() {
    #expect(DisplayCardPolicy.ddcTrafficBlock(
      for: .native, isWireUnresponsive: true
    ) == .macOSDrivesBrightness)
  }
}
