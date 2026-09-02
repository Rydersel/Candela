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

  /// "No reply" and "answered with zeros" are different facts about a panel, and only
  /// the second is the write-only signature.
  @Test func noReplyAndAllZerosAreNotTheSameFact() {
    #expect(DDCReadEvidence.noReply != DDCReadEvidence.allZeros)
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
