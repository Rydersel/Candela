import Foundation
import Testing
@testable import CandelaKit

@Suite("DDC read evidence")
struct DDCReadEvidenceTests {
  /// Worst evidence wins within a display: one `allZeros` is not cancelled by a later
  /// `notAttempted`. Otherwise a display that answered zeros on brightness and was never
  /// asked about contrast reports "not attempted" and the write-only line never appears.
  @Test func worseNeverForgetsABadOutcome() {
    #expect(DDCReadEvidence.worse(.allZeros, .notAttempted) == .allZeros)
    #expect(DDCReadEvidence.worse(.notAttempted, .allZeros) == .allZeros)
    #expect(DDCReadEvidence.worse(.answered, .allZeros) == .allZeros)
    #expect(DDCReadEvidence.worse(.answered, .noReply) == .noReply)
    #expect(DDCReadEvidence.worse(.noReply, .allZeros) == .allZeros)
  }

  /// `notAttempted` is the FLOOR, not a bad outcome: a display that answered
  /// once and was then not asked again has still answered.
  @Test func notAttemptedNeverOverridesARealAnswer() {
    #expect(DDCReadEvidence.worse(.answered, .notAttempted) == .answered)
    #expect(DDCReadEvidence.worse(.notAttempted, .answered) == .answered)
    #expect(DDCReadEvidence.worse(.notAttempted, .notAttempted) == .notAttempted)
  }

  @Test func worstFoldsAWholeDisplaysControllers() {
    #expect(DDCReadEvidence.worst([]) == .notAttempted)
    #expect(DDCReadEvidence.worst([.answered, .notAttempted, .answered]) == .answered)
    // The MAG 341C: brightness answers zeros, volume and contrast are never
    // attempted because startupAction is not `.read`.
    #expect(DDCReadEvidence.worst([.allZeros, .notAttempted, .notAttempted]) == .allZeros)
  }

  /// The Dell: brightness and contrast answer, and the volume register is refused
  /// because the panel carries no VCP 0x62. The display answers reads and the fold
  /// has to say so; ranking a refusal as a non-answer published "Not answering"
  /// about a panel that had just answered twice.
  @Test func arefusedRegisterLeavesAnAnsweringDisplayAnswering() {
    #expect(DDCReadEvidence.worst([.refused, .answered, .answered]) == .answered)
    #expect(DDCReadEvidence.worse(.refused, .answered) == .answered)
    #expect(DDCReadEvidence.worse(.answered, .refused) == .answered)
  }

  /// It is still a finding, though: above the floor, so a display that refused
  /// something does not read as one nothing has been asked of, and below both
  /// silences, which is what keeps it out of the "not answering" verdict.
  @Test func arefusalOutranksTheFloorAndNeitherSilence() {
    #expect(DDCReadEvidence.worse(.refused, .notAttempted) == .refused)
    #expect(DDCReadEvidence.worse(.notAttempted, .refused) == .refused)
    #expect(DDCReadEvidence.worse(.refused, .noReply) == .noReply)
    #expect(DDCReadEvidence.worse(.refused, .allZeros) == .allZeros)
  }

  /// "No reply", "answered with zeros" and "refused the code" are three different
  /// facts about a panel: only the second is the write-only signature, and only
  /// the third is the panel replying. Asserted through the copy, because three
  /// enum cases in a `Set` are distinct whatever the code does, and a check that
  /// cannot fail is not a check. Collapse an arm of `readEvidence` and this goes
  /// red.
  @Test func theThreeValuelessFindingsAreNotTheSameFact() {
    let sentences = [DDCReadEvidence.noReply, .allZeros, .refused]
      .map { DiagnosticsCopy.readEvidence($0, app: "Candela") }
    #expect(Set(sentences).count == 3)
  }
}

/// The enum in isolation is above; these pin it where it can be defeated, since replacing
/// a call site's fold with a plain assignment left every enum test green. They also pin the
/// scope: evidence is the verdict of the most recent pass that asked the panel something,
/// so a pass that asks nothing must not erase it and a pass that asks supersedes it.
@Suite("Read evidence at the brightness call site")
@MainActor
struct BrightnessReadEvidenceCallSiteTests {
  /// Mirrors `makeLegacyPathController` but hands back the prefs: some of these turn the
  /// read off mid-test, the only way to produce a pass that attempts nothing.
  private static func make(
    writer: any DDCWriting
  ) -> (controller: BrightnessController, prefs: DisplayPrefs) {
    let defaults = InMemoryDefaults()
    defaults.set(true, forKey: "disableCombinedBrightness")
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "evidence")
    let controller = BrightnessController(
      writer: writer,
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 1) { _, _ in false },
        hdr: nil, shade: nil, gamma: nil
      ),
      prefs: prefs, displayID: 1, store: nil, storageKey: nil,
      wireSiblings: []
    )
    return (controller, prefs)
  }

  private static func disableDDC(_ prefs: DisplayPrefs) {
    var tuning = prefs.tuning(for: .brightness)
    tuning.unavailableDDC = true
    prefs.setTuning(tuning, for: .brightness)
  }

  @Test func aControllerThatHasNotReadHasProvedNothing() {
    #expect(Self.make(writer: FakeDDC()).controller.readEvidence == .notAttempted)
  }

  /// The MAG 341C's signature, at the site that detects it.
  @Test func azerosAnswerIsPublishedAsAllZeros() async {
    let (controller, _) = Self.make(writer: FakeDDC(readResult: (current: 0, max: 0)))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .allZeros)
  }

  /// Two passes, unlike the zeros answer above: silence publishes only once it
  /// has happened twice running. `BrightnessReadSkipTests` pins the rule.
  @Test func asilentBusIsPublishedAsNoReplyOnTheSecondPass() async {
    let (controller, _) = Self.make(writer: FakeDDC(readResult: nil))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .notAttempted)
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .noReply)
  }

  @Test func apanelThatAnswersIsPublishedAsAnswered() async {
    let (controller, _) = Self.make(writer: FakeDDC(readResult: (current: 30, max: 100)))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .answered)
  }

  /// The half of the scope rule the fold protects: a later pass that never reaches the
  /// wire (here `unavailableDDC`, equally the native path or a built-in) proves nothing,
  /// so it must leave the write-only verdict standing rather than restoring a healthy look.
  @Test func apassThatAsksNothingLeavesTheVerdictStanding() async {
    let (controller, prefs) = Self.make(writer: FakeDDC(readResult: (current: 0, max: 0)))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .allZeros)

    Self.disableDDC(prefs)
    await controller.refreshFromHardware() // returns before touching the wire
    #expect(controller.readEvidence == .allZeros)
  }

  /// The other half, and the one a monotonic fold got wrong: a pass that does ask
  /// supersedes, or the app says "answers with zeros" about a panel that just answered.
  ///
  /// Nothing has to earn the second question here: the skip latches on the
  /// SECOND non-answer of a kind, so one zeros pass leaves the next one asking.
  /// A wake was called here for a while, which read as the thing that unlocked
  /// the re-ask and is not. `BrightnessReadSkipTests` pins the latch and every
  /// route out of it, the wake included.
  @Test func apassThatAsksAgainSupersedesTheOldVerdict() async {
    let fake = FakeDDC(readResult: (current: 0, max: 0))
    let (controller, _) = Self.make(writer: fake)
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .allZeros)

    await fake.setReadResult((current: 40, max: 80))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .answered)
  }
}

/// `didReadMaxDDC` is the provenance of `maxDDCValue`: did the panel say 100, or did we
/// assume 100 because it said nothing? The flag is only worth having if it can go back to
/// assumed, or a panel that replugs into a read-failing state keeps a previous read's claim.
@Suite("Max-DDC provenance")
@MainActor
struct MaxDDCProvenanceTests {
  @Test func afreshControllerHasAssumedItsMaximum() {
    let controller = makeLegacyPathController(writer: FakeDDC())
    #expect(controller.maxDDCValue == 100)
    #expect(controller.didReadMaxDDC == false)
  }

  @Test func areadThatAnswersMakesTheMaximumReported() async {
    let controller = makeLegacyPathController(writer: FakeDDC(readResult: (current: 30, max: 120)))
    await controller.refreshFromHardware()
    #expect(controller.maxDDCValue == 120)
    #expect(controller.didReadMaxDDC == true)
  }

  /// The 100 in `maxDDCValue` on a write-only panel is an assumption and must keep saying
  /// so: it is indistinguishable from a real read of 100 by inspection.
  @Test func azeroAnswerLeavesTheMaximumAssumed() async {
    let controller = makeLegacyPathController(writer: FakeDDC(readResult: (current: 0, max: 0)))
    await controller.refreshFromHardware()
    #expect(controller.maxDDCValue == 100)
    #expect(controller.didReadMaxDDC == false)
  }

  /// A different panel is a different subject. `AppModel.performRefresh` reuses the
  /// controller for any display whose `CGDirectDisplayID` reappears, and macOS reassigns
  /// those IDs across a replug, so a different monitor on the same port inherits this
  /// object. All three facts reset, `maxDDCValue` included: resetting only the flags left
  /// the new panel's writes scaled against the old panel's 120, with nothing to correct it.
  @Test func arebindToADifferentPanelReturnsTheMaximumToAssumed() async {
    let controller = makeLegacyPathController(
      writer: FakeDDC(readResult: (current: 30, max: 120)), panelIdentity: "panel-A"
    )
    await controller.refreshFromHardware()
    #expect(controller.didReadMaxDDC == true)
    #expect(controller.readEvidence == .answered)
    #expect(controller.maxDDCValue == 120)

    controller.rebind(writer: FakeDDC(readResult: nil), panelIdentity: "panel-B")
    #expect(controller.didReadMaxDDC == false)
    #expect(controller.readEvidence == .notAttempted)
    #expect(controller.maxDDCValue == 100) // the assumed default, as for any fresh display
  }

  /// `AppModel.performRefresh` rebinds every kept display on every pass (a wake, a
  /// resolution change, a menu open), not only after a replug. A reset that fires on the
  /// call rather than on a change drops a readable panel's reported maximum back to 100
  /// several times a session, and the recovering re-read is gated and useless write-only.
  @Test func arebindToTheSamePanelKeepsWhatThatPanelReported() async {
    let controller = makeLegacyPathController(
      writer: FakeDDC(readResult: (current: 30, max: 120)), panelIdentity: "panel-A"
    )
    await controller.refreshFromHardware()

    controller.rebind(writer: FakeDDC(readResult: nil), panelIdentity: "panel-A")
    #expect(controller.maxDDCValue == 120)
    #expect(controller.didReadMaxDDC == true)
    #expect(controller.readEvidence == .answered)
  }

  /// …and after a panel change the claim is earned back by the new panel's own
  /// read, not carried.
  @Test func areadOnTheNewPanelEarnsTheClaimBack() async {
    let controller = makeLegacyPathController(
      writer: FakeDDC(readResult: (current: 30, max: 120)), panelIdentity: "panel-A"
    )
    await controller.refreshFromHardware()

    controller.rebind(writer: FakeDDC(readResult: nil), panelIdentity: "panel-B")
    await controller.refreshFromHardware() // the new panel answers nothing
    #expect(controller.didReadMaxDDC == false)
    #expect(controller.maxDDCValue == 100)

    controller.rebind(writer: FakeDDC(readResult: (current: 40, max: 80)), panelIdentity: "panel-C")
    await controller.refreshFromHardware()
    #expect(controller.didReadMaxDDC == true)
    #expect(controller.maxDDCValue == 80)
  }
}

/// A panel that answers the read with its own result code: the Dell does this
/// for VCP 0x62, which it does not carry. Counted per command, because the pin
/// is that the refused register stops being asked while its siblings do not.
///
/// `outcomes` scripts the tries within one pass, the last entry repeating, so a
/// refusal can be followed by the contended silence the pass fold used to lose
/// it to. Default: every try refuses.
///
/// `@unchecked Sendable` is not needed: an actor confines the state, and the
/// controller awaits every call.
private actor RefusingDDC: DDCWriting {
  private var readsByCommand: [UInt8: Int] = [:]
  private var outcomes: [DDCReadOutcome]

  init(_ outcomes: [DDCReadOutcome] = [.refused]) { self.outcomes = outcomes }

  func write(command _: UInt8, value _: UInt16) async -> Bool { true }

  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    await readOutcome(command: command).value
  }

  func readOutcome(command: UInt8) async -> DDCReadOutcome {
    readsByCommand[command, default: 0] += 1
    return outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .refused)
  }

  func reads(of command: UInt8) -> Int { readsByCommand[command, default: 0] }
}

/// The configuration the round this fix came from is about: the Dell under "Ask
/// the display", whose volume register answers a refusal on every try.
@Suite("Read evidence for a refused register")
@MainActor
struct RefusedRegisterEvidenceTests {
  /// It publishes on the FIRST pass, unlike a silence: the panel's own result
  /// code is not a busy wire, so nothing is gained by waiting for a second.
  @Test func arefusedVolumeRegisterPublishesOnItsFirstPass() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-volume")
    prefs.startupAction = .read
    let volume = DDCValueController(writer: RefusingDDC(), command: .volume, prefs: prefs)

    await volume.refreshFromHardware()
    #expect(volume.readEvidence == .refused)
  }

  /// A refusal ends the pass on the try that carried it, so one contended try
  /// behind it cannot speak for the pass. Worst-wins ranks a silence above a
  /// refusal, so without the early exit this pass folded to `.noReply` and two of
  /// them published "Not answering" about a display that replied every time. The
  /// exit is also what stops a refused register costing `pollingTries`
  /// transactions a pass.
  @Test func arefusalEndsThePassOnTheTryThatCarriedIt() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-pass")
    prefs.startupAction = .read
    let writer = RefusingDDC([.refused, .noReply])
    let volume = DDCValueController(writer: writer, command: .volume, prefs: prefs)

    await volume.refreshFromHardware()
    #expect(volume.readEvidence == .refused)
    #expect(await writer.reads(of: VCP.audioSpeakerVolume) == 1)
  }

  /// The other half of that exit: ending the pass must not ERASE what an earlier
  /// try heard. Zeros outrank a refusal in the transport's fold and in the
  /// evidence ordering above, being the more specific finding about the register:
  /// a panel that put zeros on the bus said something about every code. Assigning
  /// the refusal over them left this suite green and contradicted both.
  @Test func arefusalDoesNotEraseAZerosAnswerFromEarlierInThePass() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-after-zeros")
    prefs.startupAction = .read
    let writer = RefusingDDC([.allZeros, .refused])
    let volume = DDCValueController(writer: writer, command: .volume, prefs: prefs)

    await volume.refreshFromHardware()
    #expect(volume.readEvidence == .allZeros)
    #expect(await writer.reads(of: VCP.audioSpeakerVolume) == 2, "control: both tries ran")
  }

  /// The direction the pass fold runs. A refusal supersedes a silence heard
  /// earlier in the same pass, which is the transport's own ordering: the panel
  /// answering "not this register" is a more specific observation than a busy
  /// wire. `DDCReadEvidence.worse` ranks it the other way, for the fold ACROSS
  /// controllers, where a refused register must never speak for a display; using
  /// that ordering inside the pass published `.noReply` off one contended try
  /// and closed the latch on a finding the panel never gave.
  @Test func arefusalSupersedesASilenceHeardEarlierInThePass() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-after-silence")
    prefs.startupAction = .read
    let writer = RefusingDDC([.noReply, .refused])
    let volume = DDCValueController(writer: writer, command: .volume, prefs: prefs)

    await volume.refreshFromHardware()
    #expect(volume.readEvidence == .refused, "it publishes on its first pass, as a refusal does")
    await volume.refreshFromHardware()
    #expect(volume.readEvidence == .refused)

    // And the latch closed on the refusal, not on a silence run the contended
    // try invented: two passes of the same finding stop the register being asked.
    let afterTwoPasses = await writer.reads(of: VCP.audioSpeakerVolume)
    await volume.refreshFromHardware()
    #expect(await writer.reads(of: VCP.audioSpeakerVolume) == afterTwoPasses)
  }

  /// And it latches on the same two-pass rule as the other findings, so the
  /// register is not re-asked for the life of the plug. Without this the Dell
  /// spends `pollingTries` transactions on VCP 0x62 on every pass, forever.
  @Test func arefusedVolumeRegisterStopsBeingAskedAfterTwoPasses() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-latch")
    prefs.startupAction = .read
    let writer = RefusingDDC()
    let volume = DDCValueController(writer: writer, command: .volume, prefs: prefs)

    await volume.refreshFromHardware()
    await volume.refreshFromHardware()
    let afterLatching = await writer.reads(of: VCP.audioSpeakerVolume)
    #expect(afterLatching > 0, "control: the register was asked at all")

    await volume.refreshFromHardware()
    #expect(await writer.reads(of: VCP.audioSpeakerVolume) == afterLatching)
    #expect(volume.readEvidence == .refused)
  }

  /// The brightness controller publishes the same verdict off its one read per
  /// pass, so the two call sites cannot drift.
  @Test func abrightnessRefusalPublishesTheSameVerdict() async {
    let controller = makeLegacyPathController(writer: RefusingDDC())

    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .refused)
    // A refusal carries no maximum, so the scale stays assumed and says so.
    #expect(controller.didReadMaxDDC == false)
    #expect(controller.maxDDCValue == 100)
  }

  /// The headline, at the surface the round-4 finding is about: the Dell answers
  /// brightness and contrast and refuses volume, and the display-level fold the
  /// hub, the Diagnostics row and the report all read has to call that display
  /// answering.
  @Test func adisplayThatRefusesOneRegisterStillReadsAsAnswering() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "refused-fold")
    prefs.startupAction = .read
    let volume = DDCValueController(writer: RefusingDDC(), command: .volume, prefs: prefs)
    let contrast = DDCValueController(
      writer: FakeDDC(readResult: (current: 50, max: 100)), command: .contrast, prefs: prefs
    )
    let brightness = makeLegacyPathController(writer: FakeDDC(readResult: (current: 30, max: 100)))

    await volume.refreshFromHardware()
    await contrast.refreshFromHardware()
    await brightness.refreshFromHardware()

    let folded = DDCReadEvidence.worst([
      brightness.readEvidence, volume.readEvidence, contrast.readEvidence,
    ])
    #expect(folded == .answered)
    #expect(DiagnosticsCopy.readbackVerdict(folded) == "Answers reads")
  }
}
