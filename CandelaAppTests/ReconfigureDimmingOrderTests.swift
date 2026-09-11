import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// One ordered log across the three protocols, so calls stay comparable by
/// index. Per-protocol recorders could count calls but never answer what ran
/// between two of them, which is the whole question here.
private enum ReconfigureEvent: Equatable {
  case hdrCacheDropped
  case hdrRead(CGDirectDisplayID)
  case recoveryPaused
  case gammaReset
  case shadeRemoveAll
  case gammaRecapture(CGDirectDisplayID)
  case gammaApply(CGDirectDisplayID)
  case shadeAlpha(CGDirectDisplayID)

  var isHDRRead: Bool {
    if case .hdrRead = self { return true }
    return false
  }

  var isRecapture: Bool {
    if case .gammaRecapture = self { return true }
    return false
  }

  /// Anything the per-display re-apply pass emits. The recapture is its first
  /// call, so this is what "the dim went back on" looks like from outside.
  var isReapply: Bool {
    switch self {
    case .gammaRecapture, .gammaApply, .shadeAlpha: return true
    case .hdrCacheDropped, .hdrRead, .recoveryPaused, .gammaReset, .shadeRemoveAll: return false
    }
  }
}

/// One instance is all three backends AND the pass's own collaborators, so it
/// sees every call in the order it was made.
///
/// `isHDREnabled` answers false deliberately: true puts every controller on the
/// native path, where `handleReconfigure` returns before the software leg and
/// there is no re-apply left to measure.
@MainActor
private final class ReconfigureRecorder: GammaApplying, ShadeRendering, HDRToggling {
  private(set) var events: [ReconfigureEvent] = []
  func pauseRecovery() { events.append(.recoveryPaused) }

  // MARK: - HDRToggling

  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool {
    events.append(.hdrRead(displayID))
    return false
  }

  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool {
    events.append(.hdrRead(displayID))
    return false
  }

  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool {
    events.append(.hdrRead(displayID))
    return false
  }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled _: Bool) async -> Bool { true }

  func displaysReconfigured() async {
    events.append(.hdrCacheDropped)
  }

  // MARK: - GammaApplying

  @discardableResult
  func applyGammaScale(
    _: Double, on displayID: CGDirectDisplayID, enforcerOn _: CGDirectDisplayID
  ) -> Bool {
    events.append(.gammaApply(displayID))
    return true
  }

  func verifyTableIntact(on _: CGDirectDisplayID) -> Bool { true }

  func recaptureDefaultTable(on displayID: CGDirectDisplayID) {
    events.append(.gammaRecapture(displayID))
  }

  func resetAllGamma() {
    events.append(.gammaReset)
  }

  // MARK: - ShadeRendering

  @discardableResult
  func setShadeAlpha(_: Double, on displayID: CGDirectDisplayID) -> Bool {
    events.append(.shadeAlpha(displayID))
    return true
  }

  func removeShade(for _: CGDirectDisplayID) {}

  func removeAllShades() {
    events.append(.shadeRemoveAll)
  }

  func repinFrames() {}
}

/// Every dimmed display is undimmed between the wholesale shade removal and the
/// per-display re-apply, so anything that runs in that gap shows as a flash. The
/// HDR re-evaluation is the one that fits: two MonitorPanel enumerations per
/// display, off the main actor and back.
///
/// These pin the order, not the timing. A duration assertion would measure the
/// machine; what shuts the window is that nothing in the gap can suspend.
@Suite("Reconfigure dimming order")
@MainActor
struct ReconfigureDimmingOrderTests {
  /// Two displays, because a single one cannot tell a hoisted loop from a
  /// per-display reordering: with one display both shapes emit the same log.
  private func run() async -> [ReconfigureEvent] {
    let recorder = ReconfigureRecorder()
    let displays = [
      TestFixtures.displayState(
        id: 7, name: "Panel A", persistenceKey: "reconfigure-order-a",
        gamma: recorder, shade: recorder, hdr: recorder),
      TestFixtures.displayState(
        id: 8, name: "Panel B", persistenceKey: "reconfigure-order-b",
        gamma: recorder, shade: recorder, hdr: recorder),
    ]
    await ReconfigureDimming.run(
      displays: displays, hdrToggling: recorder, gamma: recorder, shade: recorder,
      beforeReset: { recorder.pauseRecovery() })
    return recorder.events
  }

  @Test("early recovery remains active through HDR preparation")
  func recoveryPausesOnlyAtTheResetBoundary() async {
    let events = await run()
    #expect(events.lastIndex(where: \.isHDRRead)! < events.firstIndex(of: .recoveryPaused)!)
    #expect(events.firstIndex(of: .recoveryPaused)! + 1 == events.firstIndex(of: .gammaReset)!)
  }

  @Test("nothing at all sits between the shade removal and the re-apply")
  func theDimIsReappliedWithNothingBetweenItAndTheRemoval() async {
    let events = await run()
    #expect(
      events.firstIndex(of: .shadeRemoveAll)! + 1 == events.firstIndex(where: \.isReapply)!)
  }

  @Test("every HDR read happens before the gamma table is handed back")
  func everyHDRReadHappensBeforeTheTableIsHandedBack() async {
    let events = await run()
    #expect(events.lastIndex(where: \.isHDRRead)! < events.firstIndex(of: .gammaReset)!)
  }

  @Test("the reconfiguration notice still precedes the reads")
  func theReconfigurationNoticeStillPrecedesTheReads() async {
    let events = await run()
    #expect(events.firstIndex(of: .hdrCacheDropped)! < events.firstIndex(where: \.isHDRRead)!)
  }

  @Test("the recapture still sees an OS-owned table")
  func theRecaptureStillSeesAnOSOwnedTable() async {
    let events = await run()
    #expect(events.firstIndex(of: .gammaReset)! < events.firstIndex(where: \.isRecapture)!)
  }

  @Test("both displays are covered, from one snapshot")
  func bothDisplaysAreCoveredFromOneSnapshot() async {
    let events = await run()
    #expect(events.filter(\.isRecapture) == [.gammaRecapture(7), .gammaRecapture(8)])
  }
}
