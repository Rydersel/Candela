import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// What one catalog refresh and one arrival cost in enumerations, and that the
/// values they produce are unchanged by the counting.
///
/// Enumeration is the expensive call on real hardware: `CGDisplayCopyAllDisplayModes`
/// plus the CGS revelation pass, per display. Measured 2026-09-09, one Dell mode
/// apply and its revert produced 16 catalog refreshes and 64 full enumerations.
@MainActor
@Suite("Display mode enumeration cost")
struct DisplayModeEnumerationTests {
  private static let panelID: CGDirectDisplayID = 12
  private static let native = DisplayMode(
    ioModeID: 1, logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true
  )
  private static let smaller = DisplayMode(
    ioModeID: 2, logicalWidth: 2560, logicalHeight: 1080,
    pixelWidth: 2560, pixelHeight: 1080, refreshHz: 175, isNative: false
  )

  /// A coordinator with no `SynthesisCoordinator` and its own defaults suite, so
  /// the stored-mode half of a reapply can be counted alone. Not the shape the
  /// app runs: `AppModel` attaches synthesis to every coordinator, and that
  /// shape is counted over `SynthesisFixture` below.
  private struct Rig {
    let world: FakeDisplayWorld
    let configurator: FakeSynthesisDisplayConfigurator
    let modes: DisplayModeCoordinator
    let persistence: ModePersistence
    let identity: DisplayConfigIdentity
    let gate: DisplayReconfigurationGate
  }

  private static func rig() -> Rig {
    let world = FakeDisplayWorld()
    let identity = DisplayConfigIdentity(vendor: 0x3669, model: 9, serial: 9, isBuiltIn: false)
    world.attach(
      ConfiguredDisplay(id: panelID, identity: identity, name: "MAG341C", isBuiltIn: false),
      modes: [native, smaller], current: native,
      nativePixels: (width: 3440, height: 1440)
    )
    let configurator = FakeSynthesisDisplayConfigurator(world)
    let persistence = ModePersistence(defaults: InMemoryDefaults())
    let gate = DisplayReconfigurationGate()
    let modes = DisplayModeCoordinator(
      gate: gate,
      configurator: configurator,
      persistence: persistence
    )
    return Rig(
      world: world, configurator: configurator, modes: modes,
      persistence: persistence, identity: identity, gate: gate
    )
  }

  @Test("One catalog refresh enumerates the display once")
  func refreshEnumeratesOnce() throws {
    let rig = Self.rig()

    rig.world.forgetEnumerations()
    rig.modes.refreshCatalog(for: Self.panelID)

    #expect(rig.world.enumerations == [.snapshot])

    // The saving is only worth anything if the catalog is the same catalog.
    let catalog = try #require(rig.modes.catalogs[Self.panelID])
    #expect(catalog.current == Self.native)
    #expect(catalog.nativePixels?.width == 3440)
    #expect(catalog.nativePixels?.height == 1440)
    #expect(catalog.all == DisplayModeCatalog.full([Self.native, Self.smaller]))
    #expect(catalog.withheldForWireTiming == 0)
  }

  /// The stored-mode half alone, with no synthesis attached: nothing stored
  /// means nothing to ask the display about, so it is asked nothing.
  @Test("The stored-mode reapply enumerates not at all when nothing is stored")
  func storedModeReapplyWithNothingStoredDoesNotEnumerate() async {
    let rig = Self.rig()

    rig.world.forgetEnumerations()
    await rig.modes.reapplyStoredModes()

    #expect(rig.world.enumerations.isEmpty)
    #expect(rig.world.applies.isEmpty)
  }

  /// The stored descriptor is the mode the display already runs, so no apply and
  /// no refresh follow: what is left is the one enumeration the decision needs.
  @Test("The stored-mode reapply enumerates once when a mode is stored")
  func storedModeReapplyEnumeratesOnce() async {
    let rig = Self.rig()
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.native.descriptor, for: rig.identity)

    rig.world.forgetEnumerations()
    await rig.modes.reapplyStoredModes()

    #expect(rig.world.enumerations == [.snapshot])
    #expect(rig.world.applies.isEmpty)
  }

  @Test func storedModeScanoutMismatchRestoresTheCapturedMode() async throws {
    let rig = Self.rig()
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)
    rig.configurator.nextModeApplyFailure = DisplayConfigError(unhonouredCommit: .init(
      requested: Self.smaller, achieved: Self.smaller,
      scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175)))
    await rig.modes.reapplyStoredModes()
    #expect(rig.world.applies.map { $0.mode.ioModeID } == [2, 1])
    let report = try #require(rig.modes.report(for: Self.panelID))
    guard case let .failed(error) = report.notice else {
      Issue.record("An unsafe scan-out must remain a reported failure after recovery")
      return
    }
    #expect(error.unhonouredCommit?.fallbackRestored == true)
  }

  @Test func aMismatchReadingOnTheCapturedModeStillRestoresItAndReleasesTheGate() async throws {
    let rig = Self.rig()
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)
    rig.configurator.withholdsScanoutMismatches = true
    rig.configurator.updatesCurrentModeOnApply = true
    let timing = ScanoutTiming(width: 1280, height: 1024, refreshHz: 175)
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller, scanoutTiming: timing)),
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.native, achieved: Self.native, scanoutTiming: timing))
    ]

    await rig.modes.reapplyStoredModes()

    #expect(rig.modes.preview == nil)
    #expect(await rig.gate.holder == nil)
    #expect(rig.world.currentMode(for: Self.panelID) == Self.native)
    #expect(rig.configurator.restores.map(\.mode) == [Self.native])
    #expect(rig.configurator.withheld(on: Self.panelID) == [Self.smaller.descriptor])
  }

  @Test func aMismatchReadingOnThePreviewFallbackCannotStrandTheGate() async throws {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let modes = fixture.world.modes(for: id)
    let native = try #require(modes.first { $0.ioModeID == 1 })
    let smaller = try #require(modes.first { $0.ioModeID == 2 })
    let timing = ScanoutTiming(width: 1280, height: 1024, refreshHz: 175)
    fixture.configurator.withholdsScanoutMismatches = true
    fixture.configurator.updatesCurrentModeOnApply = true
    fixture.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: smaller, achieved: smaller, scanoutTiming: timing)),
      DisplayConfigError(unhonouredCommit: .init(
        requested: native, achieved: native, scanoutTiming: timing))
    ]

    fixture.modes.select(smaller, on: id, from: .settings, surface: .settingsBanner)
    await fixture.settle()

    #expect(fixture.modes.preview == nil)
    #expect(await fixture.gate.holder == nil)
    #expect(fixture.world.currentMode(for: id) == native)
    #expect(fixture.configurator.restores.map(\.mode) == [native])
    #expect(fixture.configurator.withheld(on: id) == [smaller.descriptor])
  }

  @Test func failedStoredModeRollbackRetainsAnActionableRecoveryPreview() async throws {
    let rig = Self.rig()
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)
    rig.configurator.updatesCurrentModeOnApply = true
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    ]

    await rig.modes.reapplyStoredModes()

    let recovery = try #require(rig.modes.preview)
    #expect(recovery.isCountingDown)
    #expect(recovery.unhonouredCommit?.scanoutTiming != nil)
    #expect(await rig.modes.confirm(recovery) != .committed)
    #expect(await rig.modes.revert(recovery) == .reverted)
    #expect(rig.world.currentMode(for: Self.panelID) == Self.native)
    #expect(rig.modes.preview == nil)
  }

  @Test func failedRollbackDefersOtherArrivalsUntilRecoveryEnds() async throws {
    let rig = Self.rig()
    let secondID: CGDirectDisplayID = 13
    let secondIdentity = DisplayConfigIdentity(vendor: 0x3669, model: 9, serial: 10, isBuiltIn: false)
    rig.world.attach(
      ConfiguredDisplay(id: secondID, identity: secondIdentity, name: "Second panel", isBuiltIn: false),
      modes: [Self.native, Self.smaller], current: Self.native,
      nativePixels: (width: 3440, height: 1440))
    for identity in [rig.identity, secondIdentity] {
      rig.persistence.setEnabled(true, for: identity)
      rig.persistence.store(Self.smaller.descriptor, for: identity)
    }
    rig.configurator.updatesCurrentModeOnApply = true
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    ]

    await rig.modes.reapplyStoredModes()
    let recovery = try #require(rig.modes.preview)
    #expect(rig.world.applies.allSatisfy { $0.displayID == Self.panelID })
    await rig.modes.reapplyStoredModes()
    #expect(rig.modes.preview?.displayID == Self.panelID)
    #expect(rig.world.currentMode(for: secondID) == Self.native)

    #expect(await rig.modes.revert(recovery) == .reverted)
    await rig.modes.reapplyStoredModes()
    #expect(rig.world.currentMode(for: secondID) == Self.smaller)
    #expect(rig.world.applies.last?.displayID == secondID)
  }

  @Test(arguments: [false, true])
  func replacementDuringReapplyStopsReportingAndSynthesis(duringRollback: Bool) async throws {
    let persistence = ModePersistence(defaults: InMemoryDefaults())
    let fixture = SynthesisFixture(modePersistence: persistence)
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let original = try fixture.configured(id)
    let modes = fixture.world.modes(for: id)
    let smaller = try #require(modes.first { $0.ioModeID == 2 })
    let stop = try #require(fixture.modes.catalogs[id]?.syntheticStops.first)
    persistence.setEnabled(true, for: original.identity)
    persistence.store(smaller.descriptor, for: original.identity)
    fixture.prefs.setStoredSyntheticSize(.init(logicalWidth: stop.logicalWidth, logicalHeight: stop.logicalHeight))
    if duringRollback {
      fixture.configurator.nextModeApplyFailure = DisplayConfigError(unhonouredCommit: .init(
        requested: smaller, achieved: smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175)))
    }
    let world = fixture.world
    let replacement = ConfiguredDisplay(id: id,
      identity: DisplayConfigIdentity(vendor: 0x3669, model: 1, serial: 99, isBuiltIn: false),
      name: "Replacement", isBuiltIn: false)
    fixture.configurator.onModeApply = {
      if world.applies.count == (duringRollback ? 1 : 0) {
        world.attach(replacement, modes: modes, current: smaller,
          nativePixels: (width: 3440, height: 1440))
      }
    }
    var notices: [ModeReapplyNotice] = []
    fixture.modes.didReportReapply = { _, notice in notices.append(notice) }

    await fixture.modes.reapplyStoredModes()

    #expect(notices.isEmpty)
    #expect(fixture.synthesis.pairings.isEmpty)
    #expect(fixture.host.live().isEmpty)
  }

  /// The shape the app runs: synthesis attached, so an arrival pays the
  /// synthesis half's enumeration even with nothing stored. Still one pass.
  @Test("An arrival with synthesis attached and nothing stored enumerates once")
  func arrivalWithSynthesisAttachedEnumeratesOnce() async {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }

    fixture.world.forgetEnumerations()
    await fixture.modes.reapplyStoredModes()

    #expect(fixture.world.enumerations == [.snapshot])
    #expect(fixture.world.applies.isEmpty)
  }
}
