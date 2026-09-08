import CoreGraphics
import Testing
@testable import CandelaKit

/// A silent panel is asked once per plug, and every route that can make it
/// answer again clears the verdict that stopped the asking.

@MainActor
private func makeHDRController(writer: any DDCWriting, hdr: FakeHDR) -> BrightnessController {
  let defaults = InMemoryDefaults()
  defaults.set(true, forKey: "disableCombinedBrightness")
  return BrightnessController(
    writer: writer,
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 1) { _, _ in false },
      hdr: hdr,
      shade: nil,
      gamma: nil
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "hdr-read-skip"),
    displayID: 1,
    wireSiblings: []
  )
}

/// The control for every count below: a panel that answers is asked on every
/// pass, so a read counter that stays at 1 is the skip and not a broken fake.
@MainActor
@Test func aPanelThatAnswersIsAskedOnEveryPass() async {
  let fake = FakeDDC(readResult: (current: 50, max: 100))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 2)
}

@MainActor
@Test func aSilentPanelIsAskedOnce() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  #expect(await fake.recordedReadCount() == 1)
}

@MainActor
@Test func aPanelAnsweringZerosIsAskedOnce() async {
  let fake = FakeDDC(readResult: (current: 0, max: 0))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .allZeros)
  #expect(await fake.recordedReadCount() == 1)
}

@MainActor
@Test func wakeAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  controller.noteWake()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}

/// The replug route. `rebind` compares the panel IDENTITY, which a new cable or
/// a new port on the same monitor does not change, so a reconfiguration is the
/// only thing that gives that panel another hearing.
@MainActor
@Test func aReconfigurationAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 1)
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}

@MainActor
@Test func anotherPanelOnTheWireIsAskedForItself() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-b")
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}

/// A verdict earned while HDR held the register is a fact about the window, not
/// about the panel, so it must not outlive it.
@MainActor
@Test func anHDRWindowClosingAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let hdr = FakeHDR(supports: true, enabled: false)
  let controller = makeHDRController(writer: fake, hdr: hdr)
  await controller.initialHDRRefresh?.value
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)

  // HDR engaged outside the app, discovered on the next observation: the fake's
  // own cache catches up first, the way the real backend's ~2 s cache does.
  await hdr.stubEnabled(true)
  _ = await hdr.measuredHDREnabled(displayID: 1)
  await controller.noteHDRStateMayHaveChanged()
  #expect(controller.isHDREngaged)
  // Entering is a window opening: nothing earned through it exists yet, and the
  // native path is what skips the read here.
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 1)

  await hdr.stubEnabled(false)
  _ = await hdr.measuredHDREnabled(displayID: 1)
  await controller.noteHDRStateMayHaveChanged()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}
