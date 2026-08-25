import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Software dimming reports failure instead of faking success (DT17)")
@MainActor
struct SoftwareDimmingReportingTests {
  private static let slaveID: CGDirectDisplayID = 3
  private static let masterID: CGDirectDisplayID = 2

  /// The slave `3` mirrors the master `2`, so anything needing a screen
  /// resolves to `2` and anything needing the panel keeps `3`.
  private func mirroredStore() -> MirrorTopologyStore {
    MirrorTopologyStore(MirrorTopology([
      MirrorFixtures.display(Self.masterID, inSet: true),
      MirrorFixtures.display(Self.slaveID, mirrors: Self.masterID),
    ]))
  }

  private func controller(
    shade: RecordingShade, gamma: RecordingGamma, store: MirrorTopologyStore,
    configure: (DisplayPrefs) -> Void
  ) -> BrightnessController {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "mirror")
    configure(prefs)
    return BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: nil, shade: shade, gamma: gamma
      ),
      prefs: prefs,
      displayID: Self.slaveID,
      mirrorTopology: store,
      wireSiblings: []
    )
  }

  /// The gamma WRITE keeps the panel's own ID — gamma is per-display and the
  /// slave's panel is what we want dimmed — while the activity enforcer goes to
  /// the display that actually has a compositor.
  @Test func theGammaWriteStaysOnThePanelWhileTheEnforcerMovesToTheMaster() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = false
    }
    controller.setBrightness(0.4)
    #expect(gamma.calls.last?.write == Self.slaveID)
    #expect(gamma.calls.last?.enforcer == Self.masterID)
  }

  /// The shade for a mirror set belongs on the master: it is the master's
  /// framebuffer every panel in the set is showing, and a shade keyed to a
  /// display with no desktop is a window nothing ever dims.
  @Test func theShadeIsAppliedToTheDisplayThatOwnsThePixels() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.last?.id == Self.masterID)
  }

  /// THE DEFECT. A software write that did not land must not be memoised as
  /// applied: today `lastAppliedSw` is set before the backend is even asked, so
  /// the identical value is deduped away forever and the display never dims
  /// again — while the engine reports a brightness it never achieved.
  @Test func aFailedShadeWriteIsRetriedRatherThanMemoisedAsApplied() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    shade.succeeds = false
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.count == 2)

    // And once it starts working, the dedupe comes back: the retry is because
    // the write FAILED, not because dedupe was abandoned.
    shade.succeeds = true
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.count == 3)
  }

  @Test func aFailedGammaWriteIsRetriedRatherThanMemoisedAsApplied() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    gamma.succeeds = false
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = false
    }
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(gamma.calls.count == 2)
  }

  /// An engine nobody wired a topology into behaves exactly as it does today:
  /// the identity function, not a crash and not a guess.
  @Test func anUnwiredEngineResolvesEveryDisplayToItself() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: MirrorTopologyStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.last?.id == Self.slaveID)
  }
}

/// Records the write target of every gamma apply and can be told which targets
/// refuse. `RecordingGamma`'s single `succeeds` flag answers the same for both
/// halves of a synthesis double write, which is exactly the distinction these
/// tests are about.
@MainActor
private final class SelectiveGamma: GammaApplying {
  struct Write: Equatable {
    var scale: Double
    var target: CGDirectDisplayID
    var enforcer: CGDirectDisplayID
    /// Which entry point issued it. The two legs differ in what they do about a
    /// display whose baseline cannot be captured, so a double that collapsed
    /// them could not see the companion routed through the leg that refuses.
    var assumesLinearBaseline: Bool
  }

  var refuses: Set<CGDirectDisplayID> = []
  private(set) var writes: [Write] = []
  private(set) var recaptured: [CGDirectDisplayID] = []

  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    writes.append(
      Write(scale: scale, target: displayID, enforcer: drawableDisplayID, assumesLinearBaseline: false)
    )
    return !refuses.contains(displayID)
  }

  @discardableResult
  func applyGammaScale(
    assumingLinearBaseline scale: Double, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    writes.append(
      Write(scale: scale, target: displayID, enforcer: drawableDisplayID, assumesLinearBaseline: true)
    )
    return !refuses.contains(displayID)
  }

  func verifyTableIntact(on _: CGDirectDisplayID) -> Bool { true }
  func recaptureDefaultTable(on displayID: CGDirectDisplayID) { recaptured.append(displayID) }
  func resetAllGamma() {}
}

/// SS15, amended by Phase 0 (d): a synthesis set has two display IDs and
/// nothing in software can say which one's transfer table reaches the glass, so
/// the dimming scale is written to both.
@Suite("Gamma dimming under an engaged synthesis set (SS15)")
@MainActor
struct SynthesisGammaRoutingTests {
  /// `MirrorFixtures.synthesisPair`: panel 2 shows virtual display 5's
  /// framebuffer, and the engine's pairing names 5.
  private static let panelID: CGDirectDisplayID = 2
  private static let virtualID: CGDirectDisplayID = 5

  /// Software path, gamma leg: the state every test here starts from.
  private func softwarePrefs() -> DisplayPrefs {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "synthesis")
    prefs.forceSoftware = true
    prefs.avoidGamma = false
    return prefs
  }

  private func controller(
    displayID: CGDirectDisplayID, gamma: any GammaApplying, store: MirrorTopologyStore,
    hdr: (any HDRToggling)? = nil, prefs: DisplayPrefs? = nil
  ) -> BrightnessController {
    let prefs = prefs ?? softwarePrefs()
    return BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: hdr, shade: RecordingShade(), gamma: gamma
      ),
      prefs: prefs,
      displayID: displayID,
      mirrorTopology: store,
      wireSiblings: []
    )
  }

  /// Every restore to 1.0 has to reach both legs, or the companion is a virtual
  /// display left holding a dark framebuffer that nothing else hands back. Three
  /// doors reach it, and each is pinned below.
  /// Counted in PAIRS rather than pinned to exactly one: an HDR entry clears the
  /// leg twice by design (the stale-cache fall-through re-runs it), and what
  /// matters is that no restore is ever a lone panel write.
  private func expectBothLegsRestored(
    _ gamma: SelectiveGamma, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let restores = gamma.writes.filter { $0.scale == 1.0 }
    #expect(!restores.isEmpty, "nothing was handed back at all", sourceLocation: sourceLocation)
    let pairs = restores.count / 2
    #expect(
      restores.map(\.target) == (0 ..< pairs).flatMap { _ in [Self.panelID, Self.virtualID] },
      sourceLocation: sourceLocation
    )
    #expect(
      restores.map(\.assumesLinearBaseline) == (0 ..< pairs).flatMap { _ in [false, true] },
      sourceLocation: sourceLocation
    )
  }

  @Test func theScaleIsWrittenToThePanelAndToTheVirtualDisplayItIsMirroredOnto() {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    #expect(gamma.writes.map(\.target) == [Self.panelID, Self.virtualID])
    // Both halves carry the same scale.
    #expect(Set(gamma.writes.map(\.scale)).count == 1)
    // And the enforcer stays where it has to be: only the virtual display has a
    // compositor to force a pass on.
    #expect(gamma.writes.allSatisfy { $0.enforcer == Self.virtualID })
  }

  /// THE DEFECT the first round shipped. The companion went through the ordinary
  /// leg, which refuses a display whose baseline it could not capture, and the
  /// creating process measurably cannot read a virtual display's table: the
  /// second write was issued and never made. The panel keeps the ordinary leg,
  /// which must keep refusing rather than flattening a real colour profile.
  @Test func theCompanionLegAssumesALinearBaselineAndThePanelLegDoesNot() {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    #expect(gamma.writes.map(\.assumesLinearBaseline) == [false, true])
  }

  /// A synthesis disengage destroys the virtual display, and CoreGraphics may
  /// reissue its ID. The baseline the island cached for it has to go with it, or
  /// a re-engaged slot scales a new display's table against a dead one's.
  @Test func aReconfigureDropsTheCompanionBaselineAsWellAsThePanels() async {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    await controller.handleReconfigure()
    #expect(gamma.recaptured.contains(Self.virtualID))
    #expect(gamma.recaptured.contains(Self.panelID))
  }

  /// And nothing is dropped for a display that never took a companion write, so
  /// an ordinary mirror set's master keeps the baseline it captured for itself.
  @Test func aReconfigureWithNoCompanionRecapturesOnlyThePanel() async {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: 3, gamma: gamma,
      store: MirrorTopologyStore(MirrorTopology([
        MirrorFixtures.display(2, inSet: true),
        MirrorFixtures.display(3, mirrors: 2),
      ]))
    )
    controller.setBrightness(0.4)
    await controller.handleReconfigure()
    #expect(gamma.recaptured == [3])
  }

  /// The carve-out is the pairing, not the mirror flags: a mirror set the user
  /// built keeps the single write to the panel. The master there is somebody
  /// else's desktop, and scaling its table would dim a display nobody asked
  /// about.
  @Test func aMirrorSetTheUserBuiltKeepsTheSingleWriteToThePanel() {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: 3, gamma: gamma,
      store: MirrorTopologyStore(MirrorTopology([
        MirrorFixtures.display(2, inSet: true),
        MirrorFixtures.display(3, mirrors: 2),
      ]))
    )
    controller.setBrightness(0.4)
    #expect(gamma.writes.map(\.target) == [3])
  }

  @Test func anUnmirroredDisplayKeepsTheSingleWrite() {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: 2, gamma: gamma, store: MirrorTopologyStore(MirrorFixtures.unmirroredPair)
    )
    controller.setBrightness(0.4)
    #expect(gamma.writes.map(\.target) == [2])
  }

  /// Only the PANEL's write decides whether the dimming landed. The process that
  /// created a virtual display cannot read it back, so its write can refuse for
  /// reasons that say nothing about the dimming; letting that clear the dedupe
  /// memo would re-attempt on every drag event, which is the live-lock DT17's
  /// reporting rule was written to avoid.
  @Test func aRefusedCompanionWriteDoesNotUnMemoiseTheValue() {
    let gamma = SelectiveGamma()
    gamma.refuses = [Self.virtualID]
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(gamma.writes.count == 2)
  }

  /// The other direction, unchanged: a refused PANEL write is still retried.
  @Test func aRefusedPanelWriteIsStillRetried() {
    let gamma = SelectiveGamma()
    gamma.refuses = [Self.panelID]
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(gamma.writes.count == 4)
  }

  /// The interference-accept hand-back. The app's hook used to write the island
  /// directly at the panel ID, so an engaged pairing kept its scaled companion
  /// table after the display had switched to the shade for good: two dimmers on
  /// one scanout chain, and no door left that hands the second one back.
  @Test func theInterferenceHandBackRestoresBothTables() {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair())
    )
    controller.setBrightness(0.4)
    controller.handBackGammaTables()
    expectBothLegsRestored(gamma)
  }

  /// `applySoftwareSideOfPrefChange`: turning the shade on abandons gamma, so
  /// both tables it scaled go back.
  @Test func abandoningGammaForTheShadeRestoresBothTables() {
    let gamma = SelectiveGamma()
    let prefs = softwarePrefs()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair()), prefs: prefs
    )
    controller.setBrightness(0.4)
    prefs.avoidGamma = true
    controller.reapplyAfterPrefChange()
    expectBothLegsRestored(gamma)
  }

  /// `clearSoftwareLeg`: entering the native path (C1) takes the software leg
  /// down, and gamma is broken under HDR, so a companion left scaled would
  /// survive with nothing able to clear it.
  @Test func enteringTheNativePathRestoresBothTables() async {
    let gamma = SelectiveGamma()
    let controller = controller(
      displayID: Self.panelID, gamma: gamma,
      store: MirrorTopologyStore(MirrorFixtures.synthesisPair()),
      hdr: FakeHDR(supports: true)
    )
    controller.settleDelay = .milliseconds(1)
    controller.setBrightness(0.4)
    await controller.setHDRMode(.alwaysOn)
    expectBothLegsRestored(gamma)
  }
}
