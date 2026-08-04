import Foundation
import Testing
@testable import CandelaKit

@Suite("DDC read evidence (B3)")
struct DDCReadEvidenceTests {
  /// Worst evidence wins WITHIN a display: one `allZeros` is not cancelled by
  /// a later `notAttempted`. Without this a display that answered zeros on
  /// brightness and was never asked about contrast would report "not
  /// attempted" and the write-only line would never appear.
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

  /// A three-state collapse is the defect this enum exists to prevent: "no
  /// reply" and "answered with zeros" are DIFFERENT facts about a panel, and
  /// only the second is the write-only signature.
  @Test func noReplyAndAllZerosAreNotTheSameFact() {
    #expect(DDCReadEvidence.noReply != DDCReadEvidence.allZeros)
  }
}

/// Everything above is the enum in isolation. These pin it where it is
/// actually used, which is where the type can be defeated: replacing a
/// call site's fold with a plain assignment — the precise defect
/// `DDCReadEvidence` exists to prevent — left every enum test green.
///
/// They also pin the SCOPE of the fold, which is not a property of the enum
/// at all. Evidence is the verdict of the most recent pass that asked the
/// panel something: a pass that asks nothing must not erase it, a pass that
/// asks supersedes it.
@Suite("Read evidence at the brightness call site (B3)")
@MainActor
struct BrightnessReadEvidenceCallSiteTests {
  /// Mirrors `makeLegacyPathController`, but hands back the prefs — some of
  /// these need to turn the read OFF mid-test, which is the only way to
  /// produce a pass that attempts nothing.
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
      prefs: prefs, displayID: 1, store: nil, storageKey: nil
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

  @Test func asilentBusIsPublishedAsNoReply() async {
    let (controller, _) = Self.make(writer: FakeDDC(readResult: nil))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .noReply)
  }

  @Test func apanelThatAnswersIsPublishedAsAnswered() async {
    let (controller, _) = Self.make(writer: FakeDDC(readResult: (current: 30, max: 100)))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .answered)
  }

  /// The half of the scope rule that the fold protects: a later pass that
  /// never reaches the wire (here `unavailableDDC`; equally the native path
  /// or role `.builtIn`) attempts nothing and therefore proves nothing. It
  /// must leave the write-only verdict standing rather than quietly restoring
  /// the display to looking healthy.
  @Test func apassThatAsksNothingLeavesTheVerdictStanding() async {
    let (controller, prefs) = Self.make(writer: FakeDDC(readResult: (current: 0, max: 0)))
    await controller.refreshFromHardware()
    #expect(controller.readEvidence == .allZeros)

    Self.disableDDC(prefs)
    await controller.refreshFromHardware() // returns before touching the wire
    #expect(controller.readEvidence == .allZeros)
  }

  /// The other half, and the one a monotonic fold got wrong: a pass that DOES
  /// ask supersedes. Anything else publishes "this display answers with zeros"
  /// about a panel that has just answered properly — a false sentence from the
  /// feature built to stop false sentences.
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

/// `didReadMaxDDC` is the provenance of `maxDDCValue`: did the PANEL say 100,
/// or did we assume 100 because it said nothing? The flag is only worth having
/// if it can go back to "assumed" — a display that replugs into a read-failing
/// state and keeps claiming "the maximum was read from the panel" on the
/// strength of a read from a previous binding is exactly the class of untruth
/// this feature exists to remove.
@Suite("Max-DDC provenance (B5)")
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

  /// The 100 standing in `maxDDCValue` on a write-only panel is an assumption,
  /// and must keep saying so — it is indistinguishable from a real read of 100
  /// by inspection, which is why the provenance is recorded beside it.
  @Test func azeroAnswerLeavesTheMaximumAssumed() async {
    let controller = makeLegacyPathController(writer: FakeDDC(readResult: (current: 0, max: 0)))
    await controller.refreshFromHardware()
    #expect(controller.maxDDCValue == 100)
    #expect(controller.didReadMaxDDC == false)
  }

  /// A replug is a new wire, and evidence is about a wire. This matters more
  /// than it sounds: `AppModel.performRefresh` REUSES the controller for any
  /// display whose `CGDirectDisplayID` reappears, and macOS reassigns those
  /// IDs across a replug — so a different physical monitor on the same port
  /// inherits this object and, without the reset, the previous panel's claims
  /// about itself.
  @Test func arebindReturnsTheMaximumToAssumedAndTheEvidenceToTheFloor() async {
    let controller = makeLegacyPathController(writer: FakeDDC(readResult: (current: 30, max: 120)))
    await controller.refreshFromHardware()
    #expect(controller.didReadMaxDDC == true)
    #expect(controller.readEvidence == .answered)

    controller.rebind(writer: FakeDDC(readResult: nil))
    #expect(controller.didReadMaxDDC == false)
    #expect(controller.readEvidence == .notAttempted)
    // The number itself is deliberately NOT reset: `maxDDCValue` feeds the DDC
    // write path, and rewriting it here would change what lands on the wire.
    // The honest reading of the pair after a replug is "120, which we can no
    // longer vouch for" — which is what an assumed maximum is.
    #expect(controller.maxDDCValue == 120)
  }

  /// …and the claim is earned back by this binding's own read, not carried.
  @Test func areadOnTheNewBindingEarnsTheClaimBack() async {
    let controller = makeLegacyPathController(writer: FakeDDC(readResult: (current: 30, max: 120)))
    await controller.refreshFromHardware()

    controller.rebind(writer: FakeDDC(readResult: nil))
    await controller.refreshFromHardware() // the new wire answers nothing
    #expect(controller.didReadMaxDDC == false)

    controller.rebind(writer: FakeDDC(readResult: (current: 40, max: 80)))
    await controller.refreshFromHardware()
    #expect(controller.didReadMaxDDC == true)
    #expect(controller.maxDDCValue == 80)
  }
}
