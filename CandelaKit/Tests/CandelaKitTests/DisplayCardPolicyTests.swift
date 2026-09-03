import Foundation
import Testing
@testable import CandelaKit

@Suite("Display card policy")
struct DisplayCardPolicyTests {
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

  /// The DDC wire-degradation ambiguity, and the one place it bites: greying the DDC grid here
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

  /// The whole input product, not a hand-picked list that a new `BrightnessPath`
  /// case would silently fall out of.
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
}
