import CoreGraphics
import Testing
@testable import CandelaKit

/// A panel that says nothing TWICE RUNNING is asked once per plug, and every
/// route that can make it answer again clears the skip. The clears reach the
/// skip only: the app runs the read pass before it fans a reconfiguration out,
/// so a clear there wiped the verdict that pass had just earned.

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
  latch.record(.noReply)
  #expect(latch.skipsRead)
}

/// The two zeros passes a write-only panel is asked before it is left alone.
@Test func twoZerosPassesLatchTheSkip() {
  var latch = DDCReadSkipLatch()
  latch.record(.allZeros)
  #expect(!latch.skipsRead)
  latch.record(.allZeros)
  #expect(latch.skipsRead)
}

/// Zeros and silence are different findings: one of each is a contended wire,
/// and taking it as a pair flipped the MAG to "Not answering" on one bad pass.
@Test func aZerosPassAndASilentPassAreNotAPair() {
  var mixed = DDCReadSkipLatch()
  mixed.record(.allZeros)
  #expect(mixed.record(.noReply) == false)
  #expect(!mixed.skipsRead)

  var reversed = DDCReadSkipLatch()
  reversed.record(.noReply)
  #expect(reversed.record(.allZeros) == true) // zeros is the panel's own word
  #expect(!reversed.skipsRead)
}

/// And the run the broken pair was hiding: the silence still latches and
/// publishes, one pass later than it used to, once a second silence agrees.
@Test func aZerosPassThenTwoSilentPassesPublishesOnTheThird() {
  var latch = DDCReadSkipLatch()
  #expect(latch.record(.allZeros) == true)
  #expect(latch.record(.noReply) == false)
  #expect(!latch.skipsRead)
  #expect(latch.record(.noReply) == true)
  #expect(latch.skipsRead)
}

/// The publish half, which the read sites read straight off `record`.
@Test func aLoneSilencePublishesNothingAndTheSecondOnePublishes() {
  var latch = DDCReadSkipLatch()
  #expect(latch.record(.noReply) == false)
  #expect(latch.record(.noReply) == true)
}

/// A zeros reply is the panel's own word about itself, so it never waits for a
/// second pass the way a silence does, and neither does a frame.
@Test func anAnswerPublishesOnItsFirstPass() {
  var zeros = DDCReadSkipLatch()
  #expect(zeros.record(.allZeros) == true)
  var frames = DDCReadSkipLatch()
  #expect(frames.record(.answered) == true)
}

/// A pass that never reached the wire proved nothing, so it publishes nothing.
@Test func aPassThatAttemptedNothingPublishesNothing() {
  var latch = DDCReadSkipLatch()
  #expect(latch.record(.notAttempted) == false)
}

/// The clear is about the ASKING. A cleared latch has to earn a silent verdict
/// over again, which is what stops one stale silence from publishing alone.
@Test func aClearedLatchMakesASilenceWaitForItsPairAgain() {
  var latch = DDCReadSkipLatch()
  latch.record(.noReply)
  latch.record(.noReply)
  latch.clear()
  #expect(latch.record(.noReply) == false)
  #expect(latch.record(.noReply) == true)
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
  // One silence is what a held wire looks like, so the row keeps saying nothing
  // has been proved yet.
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  // The second one in a row is: it trips the latch, and the pass that trips it is
  // the pass that publishes.
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  #expect(await fake.recordedReadCount() == 2)
}

/// The Dell's measured behaviour: silence once on a plug-in pass and once right
/// after a mode change, with a clean frame on the next pass each time.
@MainActor
@Test func oneSilenceLeavesAnAnsweringPanelsVerdictStanding() async {
  let fake = FakeDDC(readResult: (current: 50, max: 100))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)

  await fake.setReadResult(nil)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)

  await fake.setReadResult((current: 60, max: 100))
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  #expect(await fake.recordedReadCount() == 3)
}

/// A frame resets both halves: the verdict it publishes and the silent count
/// behind the skip, so the next bad pass is a first one again.
@MainActor
@Test func aFrameResetsTheVerdictAndTheCount() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)

  // The latch is set, so nothing would be asked without this. The clear is the
  // asking half only: the verdict is still the one the reads earned.
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .noReply)

  await fake.setReadResult((current: 50, max: 100))
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)

  // The discriminator for the count: without the frame's reset this pass would be
  // the second silence of a pair and would publish on its own.
  await fake.setReadResult(nil)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  #expect(await fake.recordedReadCount() == 5)
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
  #expect(controller.readEvidence == .notAttempted)

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
  // The skip is gone; the verdict is not. Nothing has asked the panel since it
  // was earned, so there is nothing to replace it with.
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
  // And the cleared count means that pass was a first silence again, so it did
  // not re-publish on its own.
  #expect(controller.readEvidence == .noReply)
}

/// The replug route: `rebind` compares panel IDENTITY, which a new cable or port
/// does not change, so only a reconfiguration gives that panel another hearing.
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
  // The app reads BEFORE it reconfigures each display, so a verdict dropped here
  // is the one the pass just earned.
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
}

/// A reconfiguration in the app's real order: the read pass runs first, then the
/// per-display fan-out. The verdict that pass earned has to survive it.
@MainActor
@Test func aReconfigurationKeepsTheVerdictTheReadPassJustEarned() async {
  let fake = FakeDDC(readResult: (current: 0, max: 0))
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .allZeros)

  await fake.setReadResult((current: 50, max: 100))
  await controller.refreshFromHardware()
  await controller.handleReconfigure()
  #expect(controller.readEvidence == .answered)
}

@MainActor
@Test func anotherPanelOnTheWireIsAskedForItself() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake, panelIdentity: "panel-a")
  await controller.refreshFromHardware()
  await controller.refreshFromHardware()
  controller.rebind(writer: fake, panelIdentity: "panel-b")
  // Both halves, unlike every other clear: a verdict earned by the panel that was
  // here is not a fact about the one that replaced it.
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
  #expect(controller.readEvidence == .notAttempted)
}

/// A skip earned while HDR held the register is a fact about the window, not the
/// panel, so it must not outlive it. The verdict does: nothing has asked since.
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
  #expect(controller.readEvidence == .noReply)
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
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 2)
}

/// The same rule as the brightness read, at the register that costs the most to
/// ask: a lone silence leaves standing whatever the panel last proved.
@MainActor
@Test func oneSilenceLeavesTheValueRegistersVerdictStanding() async {
  let fake = FakeDDC(readResult: (current: 50, max: 100))
  let controller = makeValueController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)

  await fake.setReadResult(nil)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .answered)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .noReply)
  #expect(await fake.recordedReadCount() == 3)
}

/// A zeros reply is the panel's word about itself, so it publishes on its first
/// pass the way a frame does, without waiting for a pair.
@MainActor
@Test func aValueRegisterAnsweringZerosPublishesAtOnce() async {
  let fake = FakeDDC(readResult: (current: 0, max: 0))
  let controller = makeValueController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.readEvidence == .allZeros)
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
  #expect(controller.readEvidence == .notAttempted)
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
  // Both halves, unlike every other clear: a verdict earned by the panel that was
  // here is not a fact about the one that replaced it.
  #expect(controller.readEvidence == .notAttempted)
  await controller.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)
  #expect(controller.readEvidence == .notAttempted)
}

/// The value controllers are reached through the brightness controller, the only
/// one of the three that can see the HDR window that locked their shared wire.
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
  // The skip travels down the wire; the verdict stays where the reads left it.
  #expect(volume.readEvidence == .noReply)
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 3)

  await volume.refreshFromHardware()
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 4)
  await brightness.handleReconfigure()
  #expect(volume.readEvidence == .noReply)
  await volume.refreshFromHardware()
  #expect(await fake.recordedReadCount() == 5)
}

/// The same order at the sibling registers: read pass first, reconfiguration
/// fan-out second, and the diagnostics row still reads the answer afterwards.
@MainActor
@Test func aReconfigurationKeepsTheValueRegistersFreshVerdict() async {
  let fake = FakeDDC(readResult: (current: 40, max: 100))
  let volume = makeValueController(writer: fake)
  let defaults = InMemoryDefaults()
  defaults.set(true, forKey: "disableCombinedBrightness")
  let brightness = BrightnessController(
    writer: fake,
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 1) { _, _ in false },
      hdr: nil, shade: nil, gamma: nil
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "wire-siblings-verdict"),
    displayID: 1,
    wireSiblings: [volume]
  )

  await volume.refreshFromHardware()
  await brightness.handleReconfigure()
  #expect(volume.readEvidence == .answered)
}
