import CandelaKit
import CoreGraphics
import Testing

/// Answers table reads from a dictionary, so a display can be made to refuse its
/// own baseline. No display in the rig can be told to do that on demand, and
/// SS15's companion leg is defined entirely by what happens when one does.
@MainActor
private final class StubGammaDriver: GammaTableDriving {
  /// Displays that will report a table. Anything absent refuses.
  var tables: [CGDirectDisplayID: GammaSamples] = [:]
  /// Displays with a screen, i.e. ones the activity enforcer can be parked on.
  var screens: Set<CGDirectDisplayID> = []

  private(set) var writes: [(target: CGDirectDisplayID, samples: GammaSamples)] = []
  private(set) var enforcedCount = 0
  private(set) var restoreCount = 0

  func readTable(_ displayID: CGDirectDisplayID, capacity _: UInt32) -> GammaReadOutcome {
    guard let table = tables[displayID] else { return .failed(.failure) }
    return .table(table)
  }

  func writeTable(_ displayID: CGDirectDisplayID, _ samples: GammaSamples) -> CGError {
    writes.append((displayID, samples))
    return .success
  }

  func restoreColorSyncSettings() { restoreCount += 1 }
  func moveEnforcer(to displayID: CGDirectDisplayID) -> Bool { screens.contains(displayID) }
  func enforceActivity() { enforcedCount += 1 }
}

@Suite("Gamma controller baselines (SS15)")
@MainActor
struct GammaControllerTests {
  private static let panelID: CGDirectDisplayID = 2
  private static let virtualID: CGDirectDisplayID = 5
  private static let sampleCount = 256

  /// A profile curve that is visibly not the straight ramp, so a test cannot
  /// pass by accident when the identity fallback fires where it should not.
  private static func profileTable() -> GammaSamples {
    let ramp = (0 ..< sampleCount).map { CGGammaValue(pow(Double($0) / Double(sampleCount - 1), 2.2)) }
    return GammaSamples(red: ramp, green: ramp, blue: ramp)
  }

  /// A virtual display cannot be read back by the process that created it, so
  /// the companion leg has no baseline to scale. SS15 still requires it to
  /// receive the table, so the table is written against the straight ramp.
  @Test func theCompanionLegWritesTheIdentityScaledTableWhenTheBaselineCannotBeCaptured() {
    let driver = StubGammaDriver()
    driver.screens = [Self.virtualID]
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(landed)
    #expect(driver.writes.count == 1)
    #expect(driver.writes.first?.target == Self.virtualID)
    #expect(
      driver.writes.first?.samples == GammaSamples.linear(count: Self.sampleCount).scaled(by: 0.5)
    )
  }

  /// The panel leg must NOT acquire the fallback. A display whose real table
  /// could not be read still has a colour profile, and writing a straight ramp
  /// over it would flatten that profile while reporting success: the honest
  /// refusal (DT17) is the whole reason this leg returns a `Bool`.
  @Test func theOrdinaryLegStillRefusesADisplayWhoseBaselineCannotBeCaptured() {
    let driver = StubGammaDriver()
    driver.screens = [Self.panelID]
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(0.5, on: Self.panelID, enforcerOn: Self.panelID)

    #expect(!landed)
    #expect(driver.writes.isEmpty)
  }

  /// The fallback is a last resort, not a shortcut: a display that DOES report
  /// its table is scaled against that table on both legs, so a real profile
  /// curve survives the companion write as well as the panel write.
  @Test func aCapturedBaselineIsUsedByBothLegs() {
    let driver = StubGammaDriver()
    driver.screens = [Self.panelID]
    driver.tables[Self.panelID] = Self.profileTable()
    let controller = GammaController(driver: driver)

    controller.applyGammaScale(0.5, on: Self.panelID, enforcerOn: Self.panelID)
    controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.panelID, enforcerOn: Self.panelID
    )

    let expected = Self.profileTable().scaled(by: 0.5)
    #expect(driver.writes.count == 2)
    #expect(driver.writes.allSatisfy { $0.samples == expected })
  }

  /// The enforcer rule is unchanged on the new leg: no screen, no write, and the
  /// refusal is reported rather than recorded as applied.
  @Test func theCompanionLegStillRefusesWhenTheEnforcerHasNoScreen() {
    let driver = StubGammaDriver()
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(!landed)
    #expect(driver.writes.isEmpty)
  }

  /// A display written only through the assumed-baseline leg has no captured
  /// reference for a readback to compare against. It must read as intact, or the
  /// engine drives the shade fallback on a display whose gamma nobody touched.
  @Test func aDisplayWithNoCapturedBaselineReadsAsIntact() {
    let driver = StubGammaDriver()
    driver.screens = [Self.virtualID]
    let controller = GammaController(driver: driver)

    controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(controller.verifyTableIntact(on: Self.virtualID))
  }
}
