import CandelaKit
import AppKit
import CoreGraphics
import Foundation
import Testing

@Suite("HDR shortcut") @MainActor
struct HDRShortcutTests {
  @Test func aMissingPointerTargetDoesNotToggleAnotherDisplay() async {
    let hdr = ShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    let action = HDRShortcutAction(gate: .init(), target: { _ in state })
    let outcome = await action.toggle(on: nil)
    #expect(outcome.message.contains("pointer"))
    #expect(await hdr.writes.isEmpty)
  }

  @Test func anUnknownDisplayNeverFallsBackToTheFirstMonitor() async {
    let hdr = ShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    let action = HDRShortcutAction(gate: .init(), target: { $0 == state.id ? state : nil })
    _ = await action.toggle(on: 999)
    #expect(await hdr.writes.isEmpty)
  }

  @Test func aShortcutTogglesOnlyTheRequestedDisplayAndReleasesTheGate() async {
    let hdr = ShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    await state.controller.noteHDRStateMayHaveChanged()
    let gate = DisplayReconfigurationGate()
    let action = HDRShortcutAction(gate: gate, target: { $0 == state.id ? state : nil })
    #expect(await action.toggle(on: state.id) == .changed(name: "Test Display", enabled: true))
    #expect(await hdr.writes == [true])
    #expect(await gate.holder == nil)
    #expect(await action.toggle(on: state.id) == .changed(name: "Test Display", enabled: false))
    #expect(await hdr.writes == [true, false])
    #expect(await gate.holder == nil)
  }

  @Test func anUnsupportedTargetAndASynthesizedSizeDoNotWriteHDR() async {
    let hdr = ShortcutHDR(supported: false)
    let state = TestFixtures.displayState(hdr: hdr)
    await state.controller.noteHDRStateMayHaveChanged()
    let action = HDRShortcutAction(gate: .init(), target: { _ in state })
    #expect(await action.toggle(on: state.id) == .refused(PanelView.hdrNoModesCaption))
    #expect(await hdr.writes.isEmpty)
    let supported = ShortcutHDR()
    let second = TestFixtures.displayState(hdr: supported)
    await second.controller.noteHDRStateMayHaveChanged()
    let blocked = HDRShortcutAction(gate: .init(), target: { _ in second }, isSynthesized: { _ in true })
    #expect(await blocked.toggle(on: second.id)
      == .refused("Turn off the synthesized display size before switching HDR on."))
    #expect(await supported.writes.isEmpty)
  }

  @Test func anExistingPreviewKeepsItsGateAndHDRUnchanged() async {
    let hdr = ShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    await state.controller.noteHDRStateMayHaveChanged()
    let gate = DisplayReconfigurationGate()
    _ = await gate.claim(.rotation)
    let action = HDRShortcutAction(gate: gate, target: { _ in state })
    #expect(await action.toggle(on: state.id).message.contains("Finish"))
    #expect(await hdr.writes.isEmpty)
    #expect(await gate.holder == .rotation)
  }

  @Test func aResetPreventsAnyHDRWrite() async {
    let hdr = ShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    let action = HDRShortcutAction(gate: .init(), target: { _ in state }, isBlocked: { true })
    #expect(await action.toggle(on: state.id).message.contains("reset"))
    #expect(await hdr.writes.isEmpty)
  }

  @Test func aRefusedHardwareWriteIsNotAnnouncedAsSuccess() async {
    let hdr = ShortcutHDR(accepts: false)
    let state = TestFixtures.displayState(hdr: hdr)
    await state.controller.noteHDRStateMayHaveChanged()
    let action = HDRShortcutAction(gate: .init(), target: { _ in state })
    if case .changed = await action.toggle(on: state.id) { Issue.record("Unachieved HDR reported as changed") }
    #expect(await hdr.writes == [true])
  }

  @Test func panelAndShortcutShareOneTransitionAndResetWaits() async throws {
    let hdr = PausedShortcutHDR()
    let discovery = ScriptedDiscovery([(id: 7, key: "hdr-shared-\(UUID())", name: "Test Display")])
    let model = AppModel(shade: FakeShade(), gamma: FakeGamma(), hdrToggling: hdr,
                         audioDevices: FakeAudio(), discoverDisplays: { discovery.discover($0) })
    await model.refresh()
    let state = try #require(model.displays.first)
    await state.controller.noteHDRStateMayHaveChanged()
    let shortcut = Task { await model.hdrAction.toggle(on: state.id) }
    await hdr.waitForWrite()
    #expect(!model.canResetSettings)
    #expect(await !model.beginReset())
    #expect(!model.isResetting)
    let panel = await model.hdrAction.toggle(state)
    #expect(panel.message.contains("finish"))
    #expect(await hdr.writes == [true])
    #expect(await model.reconfigurationGate.holder == .hdr)
    await hdr.releaseWrite()
    #expect(await shortcut.value == .changed(name: "Test Display", enabled: true))
    #expect(model.canResetSettings)
    #expect(await model.beginReset())
    await model.endReset()
    #expect(await model.reconfigurationGate.holder == nil)
  }

  @Test func aPanelSnapshotCannotToggleAReplacementWithTheSameDisplayID() async {
    let original = TestFixtures.displayState()
    let hdr = ShortcutHDR()
    let replacement = TestFixtures.displayState(hdr: hdr)
    await replacement.controller.noteHDRStateMayHaveChanged()
    let action = HDRShortcutAction(gate: .init(), target: { _ in replacement })
    #expect(await action.toggle(original).message.contains("changed"))
    #expect(await hdr.writes.isEmpty)
  }

  @Test func aResetStartingDuringTheWriteIsNotAnnouncedAsSuccess() async {
    let hdr = PausedShortcutHDR()
    let state = TestFixtures.displayState(hdr: hdr)
    await state.controller.noteHDRStateMayHaveChanged()
    var resetting = false
    let action = HDRShortcutAction(gate: .init(), target: { _ in state }, isBlocked: { resetting })
    let transition = Task { await action.toggle(on: state.id) }
    await hdr.waitForWrite()
    resetting = true
    await hdr.releaseWrite()
    if case .changed = await transition.value { Issue.record("Reset race reported as success") }
  }


  @Test func checkupOwnsTheGateUntilCleanupAndPreventsReset() async {
    let model = TestFixtures.appModel()
    #expect(await model.beginCheckupConfiguration() == nil)
    #expect(model.isCheckupRunning)
    #expect(!model.canResetSettings)
    #expect(await !model.beginReset())
    #expect(await model.reconfigurationGate.claim(.hdr) == .refused(by: .checkup))
    #expect(await model.beginCheckupConfiguration() != nil)
    await model.endCheckupConfiguration()
    #expect(!model.isCheckupRunning)
    #expect(model.canResetSettings)
    #expect(await model.reconfigurationGate.holder == nil)
  }

  @Test func aBusyGateRefusesCheckupWithoutStrandingItsResetLatch() async {
    let model = TestFixtures.appModel()
    _ = await model.reconfigurationGate.claim(.rotation)
    #expect(await model.beginCheckupConfiguration() != nil)
    #expect(!model.isCheckupRunning)
    #expect(model.canResetSettings)
    #expect(await model.reconfigurationGate.holder == .rotation)
  }

  @Test func feedbackReservesTheWrappedHeightBeforeItsWindowIsSized() {
    let message = String(repeating: "A long display name and a detailed HDR refusal. ", count: 8)
    let (content, label) = ShortcutFeedbackWindow.content(for: message, width: 360)
    #expect(content.frame.width == 360)
    #expect(label.frame.height > 34)
    #expect(content.frame.height >= label.fittingSize.height + 36)
    #expect(label.frame.minY >= 17)
    #expect(label.frame.maxY <= content.bounds.maxY - 17)
  }

}

private actor ShortcutHDR: HDRToggling {
  let supported: Bool
  let accepts: Bool
  var enabled = false
  var writes: [Bool] = []
  init(supported: Bool = true, accepts: Bool = true) { self.supported = supported; self.accepts = accepts }
  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool { supported }
  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
    writes.append(enabled)
    if accepts { self.enabled = enabled }
    return accepts
  }
  func displaysReconfigured() async {}
}


private actor PausedShortcutHDR: HDRToggling {
  var enabled = false
  var writes: [Bool] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool { true }
  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
    writes.append(enabled)
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      arrival?.resume()
      arrival = nil
    }
    self.enabled = enabled
    return true
  }
  func waitForWrite() async {
    if continuation != nil { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func releaseWrite() { continuation?.resume(); continuation = nil }
  func displaysReconfigured() async {}
}
