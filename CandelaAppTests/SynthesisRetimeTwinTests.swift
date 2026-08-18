import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The engage tail's re-time target and the disengage restore that pairs with
/// it.
///
/// The defect both halves answer is a pointer, not a picture: the hardware
/// cursor is sized by the SLAVE's own mode scale while the content comes from
/// the 2x master, so a panel re-timed onto its 1x native mode draws a tiny
/// cursor over an enlarged UI. Re-timing onto the HiDPI twin instead keeps the
/// identical framebuffer and refresh, so the wire timing does not move, and
/// sizes the cursor to the desktop the user is looking at.
///
/// The twin costs a restore, which is the other half: the panel spends the
/// engagement on a mode this feature applied, and a mirror break can leave a
/// slave on whichever mode it last held.
@Suite("Synthesized sizes: the re-time target and its restore") @MainActor
struct SynthesisRetimeTwinTests {
  private static let panelID = SynthesisFixture.panelID
  private static let identityKey = "retime-twin-tests"

  private func firstStop(_ fixture: SynthesisFixture) throws -> SyntheticSize {
    try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)
  }

  // MARK: - Which mode the engage re-times onto

  /// The fix, end to end through the real engine: with the HiDPI twin published,
  /// the re-time lands on it rather than on the 1x mode the user chose. Same
  /// framebuffer, same refresh, half the logical size, which is what makes the
  /// cursor match without touching the timing.
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

  /// And the fallback, which is the shape this tail shipped in: a panel that
  /// publishes no twin at its own framebuffer and refresh is re-timed onto its
  /// own mode. The cursor mismatch comes back and nothing else changes, so the
  /// re-time must still run.
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

  /// A panel left on the twin by the mirror break is put back on the mode the
  /// user chose. The world resurrects the twin here, which is the case
  /// `restoreOwnMode` exists for.
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

  /// The control. A mirror break that already left the panel on its own scale
  /// gets no apply at all: a reconfiguration for nothing is not free, and an
  /// unconditional reapply would hide a restore that never had to run.
  @Test func aDisengageThatCameBackOnItsOwnScaleAppliesNothing() async throws {
    let rig = Rig()
    _ = await rig.driver.engage(rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    let afterEngage = rig.configurator.applies.count

    _ = await rig.driver.disengage(fromPhysical: Self.panelID)

    #expect(rig.configurator.applies.count == afterEngage)
  }

  /// The ledger's rule, and the reason it is first-write-wins. Switching from
  /// one stop to another re-enters the engage while the previous re-time still
  /// stands, so the panel's current mode reads as the twin: recording that would
  /// make the twin the thing this restores, which is the defect inverted.
  @Test func switchingStopsStillRestoresTheOriginalMode() async throws {
    let rig = Rig()
    _ = await rig.driver.engage(rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    // What the panel reads as its own mode for the rest of the sequence: the
    // first engage's re-time, standing.
    rig.configurator.panelCurrentOverride = rig.twin
    _ = await rig.driver.engage(
      rig.secondStop, onPhysical: Self.panelID, identityKey: Self.identityKey)
    rig.configurator.resurrectsOnUnmirror = rig.twin

    _ = await rig.driver.disengage(fromPhysical: Self.panelID)

    let restored = try #require(rig.configurator.applies.last)
    #expect(restored.mode.logicalWidth == SynthesisFixture.nativeWidth)
    #expect(!restored.mode.isHiDPI)
  }

  /// A failed engage owes no restore: nothing of this feature's stands, and a
  /// record kept past it would reassert a mode the user may have changed since.
  @Test func aFailedEngageLeavesNothingToRestore() async throws {
    let rig = Rig()
    rig.configurator.base.refusesMirroring = true

    let result = await rig.driver.engage(
      rig.stop, onPhysical: Self.panelID, identityKey: Self.identityKey)

    #expect(result.isFailure)
    #expect(rig.driver.ownModes.mode(for: Self.panelID) == nil)
  }

  // MARK: - The rig

  /// A driver over the shared fakes, built directly rather than through
  /// `SynthesisFixture`: the coordinator's own disengage paths go to the engine,
  /// so the driver's disengage is only reachable from here.
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

  /// The shared fake configurator with two scripted answers the world cannot
  /// model on its own: a mirror break that resurrects the mode the slave last
  /// held, and a panel whose current mode is a previous re-time still standing.
  ///
  /// File-local, so the shared fakes stay the shape every other suite reads.
  private final class ScriptedConfigurator: DisplayConfiguring, @unchecked Sendable {
    let base: FakeSynthesisDisplayConfigurator
    let panel: CGDirectDisplayID
    /// What the panel reports as its current mode, overriding the world.
    var panelCurrentOverride: DisplayMode?
    /// Installed as the override the moment the panel leaves a mirror set, which
    /// is what a mirror break resurrecting the slave's last mode looks like.
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

    /// Recorded, and it clears the override: the fake world does not move on an
    /// apply, so without this the restore's own achieved-state check could never
    /// pass and the test would pin a landed restore it never proved.
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
      try base.apply(mode, to: displayID, scope: scope)
      if displayID == panel { panelCurrentOverride = nil }
    }

    /// A mirror that STANDS clears the override, because a slave reports its
    /// master's geometry and the engine's own achieved-state check reads that.
    /// A mirror that BREAKS installs the resurrection, which is the scripted
    /// half.
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

/// File-private, like the sibling suite's copy: at file scope `private` is
/// `fileprivate`, so each suite keeps its own and neither has to import the
/// other's helpers.
private extension Result {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var isFailure: Bool { !isSuccess }
}
