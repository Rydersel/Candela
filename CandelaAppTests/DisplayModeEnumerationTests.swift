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
  private static let middle = DisplayMode(
    ioModeID: 3, logicalWidth: 1920, logicalHeight: 800,
    pixelWidth: 1920, pixelHeight: 800, refreshHz: 175, isNative: false
  )
  private static let secondID: CGDirectDisplayID = 13
  private static let secondIdentity = DisplayConfigIdentity(
    vendor: 0x10AC, model: 9, serial: 13, isBuiltIn: false)

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

  /// A revealed HiDPI mode the controller drives on a foreign timing, judged by
  /// the kit's own guard rather than a scripted failure: the stored mode is
  /// withheld and the display goes back to the mode it was on.
  @Test(arguments: [false, true])
  func theRealGuardDecidesAStoredRevealedMode(timingGivesWay: Bool) async throws {
    let revealed = DisplayMode(
      ioModeID: 3, logicalWidth: 1280, logicalHeight: 540,
      pixelWidth: 2560, pixelHeight: 1080, refreshHz: 175, isNative: false,
      provenance: .coreGraphicsServices)
    let rig = Self.rig()
    rig.world.attach(
      ConfiguredDisplay(id: Self.panelID, identity: rig.identity, name: "MAG341C", isBuiltIn: false),
      modes: [Self.native, Self.smaller, revealed], current: Self.native,
      nativePixels: (width: 3440, height: 1440))
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(revealed.descriptor, for: rig.identity)
    rig.configurator.usesRealScanoutGuard = true
    rig.configurator.updatesCurrentModeOnApply = true
    let world = rig.world
    let configurator = rig.configurator
    let own = ScanoutTiming(width: 3440, height: 1440, refreshHz: 175)
    let crop = ScanoutTiming(width: 1280, height: 1024, refreshHz: 175)
    // Foreign through the guard's half-second window; when the timing gives
    // way, the extra read after the further settle finds the panel's own.
    configurator.scanoutRead = { id in
      guard world.currentMode(for: id) == revealed else { return own }
      return timingGivesWay && configurator.scanoutClock > 0.6 ? own : crop
    }

    await rig.modes.reapplyStoredModes()

    #expect(rig.modes.preview == nil)
    #expect(await rig.gate.holder == nil)
    if timingGivesWay {
      #expect(rig.world.currentMode(for: Self.panelID) == revealed)
      #expect(rig.configurator.restores.isEmpty)
      #expect(rig.configurator.withheld(on: Self.panelID).isEmpty)
    } else {
      #expect(rig.world.currentMode(for: Self.panelID) == Self.native)
      #expect(rig.configurator.restores.map(\.mode) == [Self.native])
      #expect(rig.configurator.withheld(on: Self.panelID) == [revealed.descriptor])
    }
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

  /// A recovery whose restore keeps failing must not hold the display-modes
  /// claim against Reset All Settings for as long as the display stays plugged
  /// in. The retries are the countdown's expiry path: each attempts the restore.
  @Test func aFailingRecoveryDoesNotBlockTheSettingsReset() async throws {
    let rig = Self.rig()
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)
    rig.configurator.updatesCurrentModeOnApply = true
    let refused = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      refused, refused, refused,
    ]

    await rig.modes.reapplyStoredModes()
    let recovery = try #require(rig.modes.preview)
    #expect(await rig.modes.revert(recovery) != .reverted)
    #expect(await rig.modes.revert(recovery) != .reverted)
    #expect(rig.modes.preview != nil, "the restore still fails, so the recovery stands")
    // Control: without the discard the reset is refused.
    #expect(await rig.gate.claim(.settingsReset) == .refused(by: .displayModes))

    await rig.modes.discardRecoveryForReset()

    #expect(rig.modes.preview == nil)
    #expect(await rig.gate.claim(.settingsReset) == .granted)
    await rig.gate.release(.settingsReset)
  }

  /// A recovery the person started, whose countdown would have reverted it, is
  /// reverted by the reset rather than dropped: dropping it left the display on
  /// the unhonoured mode with no countdown.
  @Test func theResetRevertsARecoveryWhoseRevertStillWorks() async throws {
    let rig = Self.rig()
    rig.configurator.updatesCurrentModeOnApply = true
    rig.configurator.nextModeApplyFailure = DisplayConfigError(unhonouredCommit: .init(
      requested: Self.smaller, achieved: Self.smaller))
    rig.modes.select(Self.smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    for _ in 0 ..< 2000 where rig.modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let recovery = try #require(rig.modes.preview)
    #expect(recovery.unhonouredCommit != nil)
    #expect(recovery.unhonouredCommit?.scanoutTiming == nil)
    #expect(rig.world.currentMode(for: Self.panelID) == Self.smaller)

    await rig.modes.discardRecoveryForReset()

    #expect(rig.modes.preview == nil)
    #expect(rig.world.currentMode(for: Self.panelID) == Self.native)
    #expect(await rig.gate.claim(.settingsReset) == .granted)
    await rig.gate.release(.settingsReset)
  }

  /// A display whose rollback failed beside a live preview on another display
  /// gets its recovery once that preview resolves, rather than none at all.
  @Test func aRecoveryRefusedBesideALivePreviewIsRetainedWhenThePreviewEnds() async throws {
    let rig = Self.rig()
    let secondID: CGDirectDisplayID = 13
    let secondIdentity = DisplayConfigIdentity(vendor: 0x10AC, model: 9, serial: 13, isBuiltIn: false)
    rig.world.attach(
      ConfiguredDisplay(id: secondID, identity: secondIdentity, name: "Second panel", isBuiltIn: false),
      modes: [Self.native, Self.smaller], current: Self.native,
      nativePixels: (width: 3440, height: 1440))
    rig.persistence.setEnabled(true, for: secondIdentity)
    rig.persistence.store(Self.smaller.descriptor, for: secondIdentity)
    rig.configurator.updatesCurrentModeOnApply = true
    rig.modes.select(Self.smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    for _ in 0 ..< 2000 where rig.modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let live = try #require(rig.modes.preview)
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      DisplayConfigError(cgErrorCode: CGError.failure.rawValue),
    ]

    await rig.modes.reapplyStoredModes()
    #expect(rig.modes.preview?.displayID == Self.panelID, "the live preview keeps the countdown")
    #expect(rig.world.currentMode(for: secondID) == Self.smaller)

    #expect(await rig.modes.revert(live) == .reverted)

    let recovery = try #require(rig.modes.preview)
    #expect(recovery.displayID == secondID)
    #expect(recovery.unhonouredCommit?.scanoutTiming != nil)
    #expect(await rig.modes.revert(recovery) == .reverted)
    #expect(rig.world.currentMode(for: secondID) == Self.native)
    #expect(rig.modes.preview == nil)
  }

  /// A live preview on the first display and, beside it, a second display
  /// whose stored-mode apply and rollback both failed, so its recovery is
  /// queued behind that preview.
  private static func queuedBesideALivePreview(
    rollbackFailure: DisplayConfigError = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
  ) async throws -> (rig: Rig, live: DisplayModeCoordinator.Preview) {
    let rig = Self.rig()
    rig.world.attach(
      ConfiguredDisplay(id: panelID, identity: rig.identity, name: "MAG341C", isBuiltIn: false),
      modes: [native, smaller, middle], current: native,
      nativePixels: (width: 3440, height: 1440))
    rig.world.attach(
      ConfiguredDisplay(id: secondID, identity: secondIdentity, name: "Second panel", isBuiltIn: false),
      modes: [native, smaller, middle], current: native,
      nativePixels: (width: 3440, height: 1440))
    rig.persistence.setEnabled(true, for: secondIdentity)
    rig.persistence.store(smaller.descriptor, for: secondIdentity)
    rig.configurator.updatesCurrentModeOnApply = true
    rig.modes.select(smaller, on: panelID, from: .settings, surface: .settingsBanner)
    for _ in 0 ..< 2000 where rig.modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let live = try #require(rig.modes.preview)
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: smaller, achieved: smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      rollbackFailure,
    ]
    await rig.modes.reapplyStoredModes()
    #expect(rig.modes.preview?.displayID == panelID, "the live preview keeps the countdown")
    return (rig, live)
  }

  /// An ordinary pick on the previewed display ends that preview without
  /// standing anything down for a mirror or a reset, so the queued recovery on
  /// the other display survives it and arms once the new preview resolves.
  @Test func aQueuedRecoverySurvivesAnOrdinaryPickOnAnotherDisplay() async throws {
    let (rig, _) = try await Self.queuedBesideALivePreview()

    rig.modes.select(Self.middle, on: Self.panelID, from: .settings, surface: .settingsBanner)
    for _ in 0 ..< 2000 where rig.modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let picked = try #require(rig.modes.preview)
    #expect(picked.displayID == Self.panelID)
    #expect(picked.mode == Self.middle)
    #expect(await rig.modes.revert(picked) == .reverted)

    let recovery = try #require(rig.modes.preview)
    #expect(recovery.displayID == Self.secondID)
    #expect(await rig.modes.revert(recovery) == .reverted)
    #expect(rig.world.currentMode(for: Self.secondID) == Self.native)
  }

  /// A rollback that itself goes unhonoured moves the display to a third mode,
  /// and that is the mode a queued recovery must expect to find.
  @Test func aRollbackThatLandsOnAThirdModeStillQueuesItsRecovery() async throws {
    let (rig, live) = try await Self.queuedBesideALivePreview(
      rollbackFailure: DisplayConfigError(unhonouredCommit: .init(
        requested: Self.native, achieved: Self.middle)))
    #expect(rig.world.currentMode(for: Self.secondID) == Self.middle)

    #expect(await rig.modes.revert(live) == .reverted)

    let recovery = try #require(rig.modes.preview)
    #expect(recovery.displayID == Self.secondID)
    #expect(await rig.modes.revert(recovery) == .reverted)
    #expect(rig.world.currentMode(for: Self.secondID) == Self.native)
  }

  /// A display that became a mirror slave while its recovery waited shows its
  /// master's picture, so a countdown there would revert a mode nobody sees.
  @Test func aQueuedRecoveryDoesNotArmOnAMirrorSlave() async throws {
    let (rig, live) = try await Self.queuedBesideALivePreview()
    rig.world.attach(
      ConfiguredDisplay(id: Self.secondID, identity: Self.secondIdentity, name: "Second panel",
        isBuiltIn: false, mirrorsDisplay: Self.panelID),
      modes: [Self.native, Self.smaller], current: Self.smaller,
      nativePixels: (width: 3440, height: 1440))

    #expect(await rig.modes.revert(live) == .reverted)

    #expect(rig.modes.preview == nil)
    #expect(await rig.gate.holder == nil)
  }

  /// A per-display reset claims only a recovery on its own display; the
  /// whole-app reset claims any.
  @Test func aPerDisplayResetLeavesARecoveryOnAnotherDisplay() async throws {
    let rig = Self.rig()
    rig.world.attach(
      ConfiguredDisplay(id: Self.secondID, identity: Self.secondIdentity, name: "Second panel", isBuiltIn: false),
      modes: [Self.native, Self.smaller], current: Self.native,
      nativePixels: (width: 3440, height: 1440))
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)
    rig.configurator.updatesCurrentModeOnApply = true
    let refused = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
    rig.configurator.modeApplyFailures = [
      DisplayConfigError(unhonouredCommit: .init(
        requested: Self.smaller, achieved: Self.smaller,
        scanoutTiming: ScanoutTiming(width: 1280, height: 1024, refreshHz: 175))),
      refused, refused, refused,
    ]
    await rig.modes.reapplyStoredModes()
    let recovery = try #require(rig.modes.preview)
    #expect(recovery.displayID == Self.panelID)
    let appliesBefore = rig.world.applies.count

    await rig.modes.discardRecoveryForReset(on: Self.secondID)

    #expect(rig.modes.preview == recovery)
    #expect(rig.world.applies.count == appliesBefore, "no revert was attempted for another display's reset")
    #expect(await rig.gate.claim(.settingsReset) == .refused(by: .displayModes))

    await rig.modes.discardRecoveryForReset(on: Self.panelID)

    #expect(rig.modes.preview == nil)
    #expect(await rig.gate.claim(.settingsReset) == .granted)
    await rig.gate.release(.settingsReset)
  }

  /// An ordinary preview is not a recovery, so the reset discard leaves it.
  @Test func theResetDiscardLeavesAnOrdinaryPreviewStanding() async throws {
    let rig = Self.rig()
    rig.modes.select(Self.smaller, on: Self.panelID, from: .settings, surface: .settingsBanner)
    for _ in 0 ..< 2000 where rig.modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let preview = try #require(rig.modes.preview)

    await rig.modes.discardRecoveryForReset()

    #expect(rig.modes.preview == preview)
    #expect(await rig.modes.revert(preview) == .reverted)
  }

  /// A display plugged in while a synthesized size is under preview on another
  /// panel gets its remembered mode in the same pass. Keeping that preview
  /// changes no hardware and raises no reconfiguration, so nothing would call
  /// the reapply again for it.
  @Test func anArrivalBesideASynthesisPreviewGetsItsStoredMode() async throws {
    let persistence = ModePersistence(defaults: InMemoryDefaults())
    let fixture = SynthesisFixture(modePersistence: persistence)
    defer { fixture.forgetPrefs() }
    let id = SynthesisFixture.panelID
    let stop = try #require(fixture.modes.catalogs[id]?.syntheticStops.first)
    fixture.modes.select(SyntheticSizeCatalog.row(for: stop), on: id,
      from: .settings, surface: .settingsBanner)
    await fixture.settle()
    #expect(await fixture.synthesis.session.previewedSynthesis?.physicalDisplayID == id)

    let arrivingID: CGDirectDisplayID = 13
    let arriving = DisplayConfigIdentity(vendor: 0x3669, model: 9, serial: 10, isBuiltIn: false)
    fixture.world.attach(
      ConfiguredDisplay(id: arrivingID, identity: arriving, name: "Arriving panel", isBuiltIn: false),
      modes: [Self.native, Self.smaller], current: Self.native,
      nativePixels: (width: 3440, height: 1440))
    persistence.setEnabled(true, for: arriving)
    persistence.store(Self.smaller.descriptor, for: arriving)
    fixture.configurator.updatesCurrentModeOnApply = true

    await fixture.modes.reapplyStoredModes()

    #expect(fixture.world.currentMode(for: arrivingID) == Self.smaller)
    #expect(await fixture.synthesis.session.previewedSynthesis?.physicalDisplayID == id,
      "the preview it arrived beside still stands")
    #expect(!fixture.world.applies.contains { $0.displayID == id && $0.mode == Self.smaller })
    await fixture.revertAnyPreview()
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
