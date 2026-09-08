import CoreGraphics
import Testing
@testable import CandelaKit

/// A panel that says nothing TWICE RUNNING is asked once per plug, and every
/// route that can make it answer again clears the verdict that stopped the
/// asking. One bad pass is not a verdict: bus contention, the probe holding the
/// wire and another panel entering HDR all produce one, on displays that answer
/// perfectly on the next pass.

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

// MARK: - The latch itself

@Test func oneSilentPassDoesNotLatchTheSkip() {
  var latch = DDCReadSkipLatch()
  latch.record(.noReply)
  #expect(!latch.skipsRead)
  latch.record(.allZeros)
  #expect(latch.skipsRead)
}

/// Consecutive, not cumulative: a panel that answered between two bad passes has
/// proved the wire works, and the count starts again.
@Test func anAnswerBetweenTwoSilentPassesResetsTheCount() {
  var latch = DDCReadSkipLatch()
  latch.record(.noReply)
  latch.record(.answered)
  latch.record(.noReply)
  #expect(!latch.skipsRead)
}

/// A pass that never reached the wire has learned nothing either way, so it
/// neither counts towards the latch nor clears it.
@Test func aPassThatAttemptedNothingLeavesTheCountAlone() {
  var latch = DDCReadSkipLatch()
  latch.record(.noReply)
  latch.record(.notAttempted)
  #expect(!latch.skipsRead)
  latch.record(.noReply)
  #expect(latch.skipsRead)
  latch.record(.notAttempted)
  #expect(latch.skipsRead)
  latch.clear()
  #expect(!latch.skipsRead)
}

// MARK: - The brightness read

/// The control for every count below: a panel that answers is asked on every
/// pass, so a read counter that stops rising is the skip and not a broken fake.
@MainActor
@Test func aPanelThatAnswersIsAskedOnEveryPass() async {
  let fake = FakeDDC(readResult: (current: 50, max: 100))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 3)
}

@MainActor
@Test func aSilentPanelIsAskedTwiceAndThenNotAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  // The verdict is published from the FIRST pass: diagnostics reports what the
  // wire proved, and only the asking waits for a second silent pass.
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  #expect(await fake.recordedReadCount() == 2)
}

@MainActor
@Test func aPanelAnsweringZerosIsAskedTwiceAndThenNotAgain() async {
  let fake = FakeDDC(readResult: (current: 0, max: 0))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .allZeros)
  #expect(await fake.recordedReadCount() == 2)
}

/// The defect the two-pass rule exists for. One transient silence on a panel
/// that answers used to publish "does not answer reads" for the rest of the
/// plug.
@MainActor
@Test func oneSilentPassSelfCorrectsOnTheNextOne() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)

  await fake.setReadResult((current: 50, max: 100))
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 2)

  // And the answer put the count back to zero, so the next bad pass is a first
  // one again rather than the second of a pair.
  await fake.setReadResult(nil)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 4)
}

@MainActor
@Test func wakeAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  controller.noteWake()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

/// The replug route. `rebind` compares the panel IDENTITY, which a new cable or
/// a new port on the same monitor does not change, so a reconfiguration is the
/// only thing that gives that panel another hearing.
@MainActor
@Test func aReconfigurationAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

@MainActor
@Test func anotherPanelOnTheWireIsAskedForItself() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-b")
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

/// A verdict earned while HDR held the register is a fact about the window, not
/// about the panel, so it must not outlive it. It must also not be WIPED while
/// the window is still open: no read follows under the native path, so a clear
/// there would replace a real write-only verdict with silence in the diagnostics
/// report and nothing would put it back until HDR ends.
@MainActor
@Test func anHDRWindowClosingAsksASilentPanelAgain() async {
  let fake = FakeDDC(readResult: nil)
  let hdr = FakeHDR(supports: true, enabled: false)
  let controller = makeHDRController(writer: fake, hdr: hdr)
  await controller.initialHDRRefresh?.value
  await controller.refreshFromHardware()
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
  #expect(await fake.recordedReadCount() == 2)

  // A reconfiguration inside the window keeps the verdict, for the reason above.
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .noReply)

  await hdr.stubEnabled(false)
  _ = await hdr.measuredHDREnabled(displayID: 1)
  await controller.noteHDRStateMayHaveChanged()
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

// MARK: - The volume and contrast reads

@MainActor
private func makeValueController(
  writer: any DDCWriting, panelIdentity: String? = nil
) -> DDCValueController {
  let defaults = InMemoryDefaults()
  let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "value-read-skip")
  prefs.startupAction = .read
  // One transaction per pass, so the counts below are passes and nothing else.
  prefs.pollingMode = .minimal
  return DDCValueController(
    writer: writer, command: .volume, prefs: prefs, panelIdentity: panelIdentity
  )
}

/// The cost this skip is about: five transactions a pass by default and twenty
/// on heavy, against the brightness read's one.
@MainActor
@Test func aSilentValueRegisterIsAskedTwiceAndThenNotAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeValueController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}

@MainActor
@Test func aValueRegisterThatAnswersIsAskedOnEveryPass() async {
  let fake = FakeDDC(readResult: (current: 50, max: 100))
  let controller = makeValueController(writer: fake)
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 3)
}

@MainActor
@Test func oneSilentValuePassSelfCorrectsOnTheNextOne() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeValueController(writer: fake)
  await controller.refreshFromHardware()
  await fake.setReadResult((current: 50, max: 100))
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 2)
}

@MainActor
@Test func rebindingAValueControllerOntoAnotherPanelAsksItAgain() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeValueController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-b")
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

/// Wake, reconfiguration and the HDR-off edge all reach the value controllers
/// through the display's brightness controller: the three share one wire, and
/// only the brightness controller can see the HDR window that locked it.
@MainActor
@Test func theWiresWakeAndReconfigurationReachTheValueControllers() async {
  let fake = FakeDDC(readResult: nil)
  let volume = makeValueController(writer: fake)
  let defaults = InMemoryDefaults()
  defaults.set(true, forKey: "disableCombinedBrightness")
  let brightness = BrightnessController(
    writer: fake,
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 1) { _, _ in false },
      hdr: nil, shade: nil, gamma: nil
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "wire-siblings"),
    displayID: 1,
    wireSiblings: [volume]
  )

  await volume.refreshFromHardware()
  await volume.refreshFromHardware()
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)

  brightness.noteWake()
  #expect(volume.readEvidence == .notAttempted)
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)

  await volume.refreshFromHardware()
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 4)
  await brightness.handleReconfigure()
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 5)
}
