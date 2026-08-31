import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The engage's re-time target, and the disengage restore that pairs with it.
///
/// The hardware cursor is sized by the SLAVE's own mode scale while content comes
/// from the 2x master, so re-timing onto 1x native draws a tiny cursor over an
/// enlarged UI. The HiDPI twin has the same framebuffer and refresh, so the wire
/// timing does not move. The twin costs a restore: a mirror break can leave a
/// slave on whichever mode it last held.
@Suite("Synthesized sizes: the re-time target and its restore") @MainActor
struct SynthesisRetimeTwinTests {
  private static let panelID = SynthesisFixture.panelID
  private static let identityKey = "retime-twin-tests"

  private func firstStop(_ fixture: SynthesisFixture) throws -> SyntheticSize {
    try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)
  }

  // MARK: - Which mode the engage re-times onto

  @Test func theRetimeLandsOnTheHiDPITwinWhenThePanelPublishesOne() async throws {
    let fixture = SynthesisFixture(nativeRidesTheHiDPITwin: true)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)

    _ = await fixture.synthesis.engage(stop, on: display)

    let retimed = try #require(fixture.configurator.applies.first)
    #expect(retimed.displayID == Self.panelID)
    #expect(retimed.mode.logicalWidth == SynthesisFixture.nativeWidth / 2)
    #expect(retimed.mode.logicalHeight == SynthesisFixture.nativeHeight / 2)
    #expect(retimed.mode.pixelWidth == SynthesisFixture.nativeWidth)
    #expect(retimed.mode.pixelHeight == SynthesisFixture.nativeHeight)
    #expect(retimed.mode.refreshHz == SynthesisFixture.nativeHz)
    #expect(retimed.mode.isHiDPI)
  }

  /// No twin means the cursor mismatch stays, but the re-time still has to run.
  @Test func aPanelWithNoTwinIsRetimedOntoItsOwnMode() async throws {
    let fixture = SynthesisFixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try firstStop(fixture)

    _ = await fixture.synthesis.engage(stop, on: display)

    let retimed = try #require(fixture.configurator.applies.first)
    #expect(retimed.mode.logicalWidth == SynthesisFixture.nativeWidth)
    #expect(retimed.mode.pixelWidth == SynthesisFixture.nativeWidth)
    #expect(!retimed.mode.isHiDPI)
  }

  // MARK: - What the disengage puts back

  /// The world resurrects the twin here, which is the case `restoreOwnMode` exists for.
  @Test func aDisengageRestoresTheModeTheUserChose() async throws {
    let rig = Rig()
    _ = await rig.driver.engage(rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    rig.configurator.resurrectsOnUnmirror = rig.twin

    let result = await rig.driver.disengage(fromPhysical: Self.panelID)

    #expect(result.isSuccess)
    let restored = try #require(rig.configurator.applies.last)
    #expect(restored.displayID == Self.panelID)
    #expect(restored.mode.logicalWidth == SynthesisFixture.nativeWidth)
    #expect(!restored.mode.isHiDPI)
  }

  /// A reconfiguration for nothing is not free, and an unconditional reapply would
  /// hide a restore that never had to run.
  @Test func aDisengageThatCameBackOnItsOwnScaleAppliesNothing() async throws {
    let rig = Rig()
    _ = await rig.driver.engage(rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    let afterEngage = rig.configurator.applies.count

    _ = await rig.driver.disengage(fromPhysical: Self.panelID)

    #expect(rig.configurator.applies.count == afterEngage)
  }

  /// Why the ledger is first-write-wins. Switching stops re-enters the engage while
  /// the previous re-time still stands, so the panel's current mode reads as the
  /// twin, and recording that would make the twin the thing this restores.
  @Test func switchingStopsStillRestoresTheOriginalMode() async throws {
    let rig = Rig()
    _ = await rig.driver.engage(rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    // The first engage's re-time, still standing.
    rig.configurator.panelCurrentOverride = rig.twin
    _ = await rig.driver.engage(
      rig.secondStop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    rig.configurator.resurrectsOnUnmirror = rig.twin

    _ = await rig.driver.disengage(fromPhysical: Self.panelID)

    let restored = try #require(rig.configurator.applies.last)
    #expect(restored.mode.logicalWidth == SynthesisFixture.nativeWidth)
    #expect(!restored.mode.isHiDPI)
  }

  /// A record kept past a failed engage would reassert a mode the user may have
  /// changed since.
  @Test func aFailedEngageLeavesNothingToRestore() async throws {
    let rig = Rig()
    rig.configurator.base.refusesMirroring = true

    let result = await rig.driver.engage(
      rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)

    #expect(result.isFailure)
    #expect(rig.driver.ownModes.mode(for: Self.panelID) == nil)
  }

  // MARK: - The rig

  /// Built directly rather than through `SynthesisFixture`: the coordinator's
  /// disengage paths go to the engine, so the driver's disengage is only reachable
  /// this way.
  @MainActor
  private struct Rig {
    let world = FakeDisplayWorld()
    let configurator: ScriptedConfigurator
    let driver: BouncingSynthesisDriver
    let twin: DisplayMode
    let stop = SyntheticSize(logicalWidth: 2580, logicalHeight: 1080, percentOfNative: 75)
    let secondStop = SyntheticSize(logicalWidth: 2408, logicalHeight: 1008, percentOfNative: 70)

    init() {
      let native = DisplayMode(
        ioModeID: 1,
        logicalWidth: SynthesisFixture.nativeWidth, logicalHeight: SynthesisFixture.nativeHeight,
        pixelWidth: SynthesisFixture.nativeWidth, pixelHeight: SynthesisFixture.nativeHeight,
        refreshHz: SynthesisFixture.nativeHz, isNative: true
      )
      twin = DisplayMode(
        ioModeID: 3,
        logicalWidth: SynthesisFixture.nativeWidth / 2,
        logicalHeight: SynthesisFixture.nativeHeight / 2,
        pixelWidth: SynthesisFixture.nativeWidth, pixelHeight: SynthesisFixture.nativeHeight,
        refreshHz: SynthesisFixture.nativeHz, isNative: true
      )
      world.attach(
        ConfiguredDisplay(
          id: SynthesisRetimeTwinTests.panelID,
          identity: DisplayConfigIdentity(vendor: 0x3669, model: 1, serial: 1, isBuiltIn: false),
          name: "MAG341C", isBuiltIn: false
        ),
        modes: [native, twin], current: native,
        nativePixels: (width: SynthesisFixture.nativeWidth, height: SynthesisFixture.nativeHeight)
      )
      configurator = ScriptedConfigurator(
        FakeSynthesisDisplayConfigurator(world), panel: SynthesisRetimeTwinTests.panelID)
      let engine = ModeSynthesisEngine(
        virtualDisplays: FakeSynthesisVirtualDisplayHost(world), configurator: configurator
      )
      driver = BouncingSynthesisDriver(
        engine: engine, hdr: FakeSynthesisHDR(supports: false).seam,
        configurator: configurator, durations: SynthesisFixture.instantDurations
      )
    }
  }

  /// Two answers the fake world cannot model on its own: a mirror break that
  /// resurrects the mode the slave last held, and a panel whose current mode is a
  /// previous re-time still standing. File-local, so the shared fakes keep the
  /// shape every other suite reads.
  private final class ScriptedConfigurator: DisplayConfiguring, @unchecked Sendable {
    let base: FakeSynthesisDisplayConfigurator
    let panel: CGDirectDisplayID
    var panelCurrentOverride: DisplayMode?
    /// Becomes the override the moment the panel leaves a mirror set.
    var resurrectsOnUnmirror: DisplayMode?

    init(_ base: FakeSynthesisDisplayConfigurator, panel: CGDirectDisplayID) {
      self.base = base
      self.panel = panel
    }

    var applies: [(mode: DisplayMode, displayID: CGDirectDisplayID)] { base.applies }

    func displays() -> [ConfiguredDisplay] { base.displays() }
    func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { base.modes(for: displayID) }

    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
      if displayID == panel, let panelCurrentOverride { return panelCurrentOverride }
      return base.currentMode(for: displayID)
    }

    func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
      base.nativePixels(for: displayID)
    }

    /// Clears the override: the fake world does not move on an apply, so otherwise
    /// the restore's achieved-state check could never pass.
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
      try base.apply(mode, to: displayID, scope: scope)
      if displayID == panel { panelCurrentOverride = nil }
    }

    /// A mirror that STANDS clears the override, because a slave reports its
    /// master's geometry and the achieved-state check reads that. A mirror that
    /// BREAKS installs the resurrection.
    func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
      try base.applyMirroring(changes, scope: scope)
      for change in changes where change.display == panel {
        if change.master == kCGNullDirectDisplay {
          panelCurrentOverride = resurrectsOnUnmirror
        } else {
          panelCurrentOverride = nil
        }
      }
    }

    var revealsHiddenModes: Bool { base.revealsHiddenModes }
    var guardsWireTiming: Bool { base.guardsWireTiming }
    func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int {
      base.modesWithheldByWireTimingGuard(for: displayID)
    }

    var canRotate: Bool { base.canRotate }
    func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { base.rotation(of: displayID) }
    func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {
      try base.applyRotation(rotation, to: displayID)
    }
  }
}

/// At file scope `private` is `fileprivate`, so each suite keeps its own copy.
private extension Result {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var isFailure: Bool { !isSuccess }
}
