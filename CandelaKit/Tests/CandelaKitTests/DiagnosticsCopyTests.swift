import Foundation
import Testing

@testable import CandelaKit

/// The diagnostics copy is the app's most load-bearing writing: it is the one
/// surface whose entire purpose is to tell the truth about hardware precisely.
/// Until #127 these sentences lived inline in `DiagnosticsPage`, where the only
/// thing defending their distinctions was somebody reading them carefully in
/// situ.
///
/// So these tests pin EXACT STRINGS. That is deliberate and it is the point: an
/// edit that collapses two states into one plausible generic sentence is exactly
/// the failure mode, and it passes every test that only checks "contains the
/// word unavailable". If a test here fails, the question to ask is not "how do I
/// make it pass" but "was this distinction meant to go".
///
/// The product name is passed in as "Candela" throughout, which is what
/// `AppInfo.productName` holds. `theProductNameIsNeverBakedIn` is the one test
/// that varies it.
@Suite("Diagnostics copy")
struct DiagnosticsCopyTests {

  private static let app = "Candela"

  // MARK: - The three distinctions this type exists to keep

  /// DISTINCTION 1: readback has THREE answers past "not asked", not two.
  ///
  /// "Not answering" is a display that stayed silent; "write-only" is a display
  /// that is on the bus, takes every command, and never answers a read. That is
  /// the MAG, it is permanent, it explains every other value on the page, and a
  /// user who has it needs the words to search for. Folding it into "not
  /// answering" would delete the only sentence that names the fault.
  @Test func readbackHasThreeAnswersAndNoneIsTheOther() {
    #expect(
      DiagnosticsCopy.readEvidence(.answered, app: Self.app)
        == "This display answers reads")
    #expect(
      DiagnosticsCopy.readEvidence(.noReply, app: Self.app)
        == "This display did not reply to a read")
    #expect(
      DiagnosticsCopy.readEvidence(.allZeros, app: Self.app)
        == "Write-only: this display takes commands but never answers a read")
    #expect(
      DiagnosticsCopy.readEvidence(.notAttempted, app: Self.app)
        == "Candela has not read from this display")

    // Four inputs, four sentences. A duplicate here is a collapsed state.
    let all = [DDCReadEvidence.notAttempted, .answered, .allZeros, .noReply]
      .map { DiagnosticsCopy.readEvidence($0, app: Self.app) }
    #expect(Set(all).count == 4)
  }

  /// The same three states in the SHORT form, which is what the hub's chevron
  /// preview and the report's `readback:` field carry. Capitalised as the page
  /// capitalises them, which is the casing ruling this type owns.
  @Test func theShortReadbackVerdictKeepsTheSameThreeStates() {
    #expect(DiagnosticsCopy.readbackVerdict(.notAttempted) == "Not asked yet")
    #expect(DiagnosticsCopy.readbackVerdict(.answered) == "Answers reads")
    #expect(DiagnosticsCopy.readbackVerdict(.allZeros) == "Write-only")
    #expect(DiagnosticsCopy.readbackVerdict(.noReply) == "Not answering")
  }

  /// The capability request has FOUR states, and the middle two are the ones an
  /// edit flattens: a display that answered something unreadable is not a
  /// display that stayed silent, and neither is a display nobody has asked.
  @Test func theCapabilityRequestTellsAnsweredFromUnreadableFromSilentFromUnasked() {
    #expect(
      DiagnosticsCopy.capabilityAnswer(
        hasDescription: true, parsedACommandList: true, wasAsked: true, app: Self.app)
        == "The display answered")
    #expect(
      DiagnosticsCopy.capabilityAnswer(
        hasDescription: true, parsedACommandList: false, wasAsked: true, app: Self.app)
        == "The display answered, but Candela could not read its description")
    #expect(
      DiagnosticsCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: true, app: Self.app)
        == "Candela asked and the display sent nothing it could read")
    #expect(
      DiagnosticsCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: false, app: Self.app)
        == "Not asked yet")
  }

  /// DISTINCTION 2: a maximum that was READ never reads like one that was
  /// assumed.
  ///
  /// "This display reported a maximum of 100" is a fact the display supplied.
  /// The other two arms both say "Assumed 100" outright, and they are two arms
  /// rather than one because `didReadMax == false` is not a single fact: the
  /// read may never have been attempted, which is not the display declining to
  /// answer.
  @Test func aReadMaximumIsNeverConfusedWithAnAssumedOne() {
    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: true, maxValue: 100, evidence: .answered, app: Self.app)
        == "This display reported a maximum of 100")
    // The value 100 is also the assumed default, so this pair is the exact
    // place the distinction could vanish without any string looking wrong.
    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: false, maxValue: 100, evidence: .notAttempted, app: Self.app)
        == "Assumed 100: Candela has not asked this display for its scale")
    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: false, maxValue: 100, evidence: .allZeros, app: Self.app)
        == "Assumed 100: the display did not report one")
    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: false, maxValue: 100, evidence: .noReply, app: Self.app)
        == "Assumed 100: the display did not report one")
  }

  /// A read maximum reports the REAL number, whatever it is (DT30 rule (g)).
  @Test func aReadMaximumReportsTheNumberTheDisplayGave() {
    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: true, maxValue: 255, evidence: .answered, app: Self.app)
        == "This display reported a maximum of 255")
  }

  /// DISTINCTION 3: the DISPLAY denying volume and a SETTING turning it off are
  /// different sentences, because they have different fixes.
  ///
  /// The `.unsupported` sentence is reachable only from a description that
  /// parsed cleanly end to end and did not list VCP 0x62 (D24). That is the
  /// Dell. It must never be worded so that a display that merely stayed silent
  /// could wear it.
  @Test func theDisplayDenyingVolumeIsNotASettingTurningItOff() {
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: true, support: .unsupported,
        hasDescription: true, forceSoftware: false, app: Self.app)
        == "Unavailable: this display's description parsed cleanly and does not list the volume command")

    #expect(
      DiagnosticsCopy.muteAvailability(
        muteEnabled: false, volumeAvailable: true, forceSoftware: false)
        == "Unavailable: muting with the display's own mute command is turned off")

    // The third and fourth reasons a command can be off, which name the setting
    // rather than shrugging: one command, or every command on this display.
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: false, support: .supported,
        hasDescription: true, forceSoftware: false, app: Self.app)
        == "Unavailable: the volume command is turned off for this display")
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: false, support: .supported,
        hasDescription: true, forceSoftware: true, app: Self.app)
        == "Unavailable: hardware control is turned off for this display")
  }

  /// D24's doctrine said out loud: unknown resolves to ENABLED, and the sentence
  /// says why the control stays on. A page that flattened three states to two
  /// would grey a working control on a display that merely stayed silent.
  ///
  /// The two `.unknown` arms are separate because a stored `.unknown` has two
  /// producers, and only one of them is silence. Saying "this display sent no
  /// answer" when a description IS on screen three rows above contradicts the
  /// page's own evidence.
  @Test func unknownVolumeSupportKeepsTheControlOnAndSaysWhy() {
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: true, support: .unknown,
        hasDescription: false, forceSoftware: false, app: Self.app)
        == "Available: this display sent no answer Candela could read, so the control stays on")
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: true, support: .unknown,
        hasDescription: true, forceSoftware: false, app: Self.app)
        == "Available: Candela could not read a command list out of this display's description, so the control stays on")
  }

  /// A display nobody has asked is not a display that answered `.unknown`.
  /// Folding the two put "this display did not answer" against a display that
  /// was never spoken to.
  @Test func anUnaskedDisplayIsNotAnUnansweringOne() {
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: true, support: nil,
        hasDescription: false, forceSoftware: false, app: Self.app)
        == "Available: Candela has not asked this display yet, so the control stays on")
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .auto, isAvailable: true, support: .supported,
        hasDescription: true, forceSoftware: false, app: Self.app)
        == "Available: this display lists the volume command")
  }

  /// The user's own override outranks everything and says so: neither sentence
  /// blames the display for a choice the user made.
  @Test func aUserOverrideNamesItselfAsTheReason() {
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .forceNone, isAvailable: true, support: .supported,
        hasDescription: true, forceSoftware: false, app: Self.app)
        == "Unavailable: you set this display's volume slider to always off")
    #expect(
      DiagnosticsCopy.volumeAvailability(
        override: .forcePresent, isAvailable: false, support: .unsupported,
        hasDescription: true, forceSoftware: true, app: Self.app)
        == "Available: you set this display's volume slider to always on")
  }

  // MARK: - Availability, the rest

  @Test func contrastAndMuteNameTheSettingThatTookThemAway() {
    #expect(
      DiagnosticsCopy.contrastAvailability(isAvailable: true, forceSoftware: false)
        == "Available")
    #expect(
      DiagnosticsCopy.contrastAvailability(isAvailable: false, forceSoftware: false)
        == "Unavailable: the contrast command is turned off for this display")
    #expect(
      DiagnosticsCopy.contrastAvailability(isAvailable: false, forceSoftware: true)
        == "Unavailable: hardware control is turned off for this display")
    #expect(
      DiagnosticsCopy.muteAvailability(
        muteEnabled: true, volumeAvailable: true, forceSoftware: false) == "Available")
    #expect(
      DiagnosticsCopy.muteAvailability(
        muteEnabled: true, volumeAvailable: false, forceSoftware: false)
        == "Unavailable: the volume command is turned off for this display")
  }

  /// No row in Availability may read a bare "Unavailable" or "Not supported"
  /// (DT30 rule (a)). Every one names what took the feature away.
  @Test func noAvailabilityAnswerIsABareUnavailable() {
    var answers: [String] = [
      DiagnosticsCopy.brightnessAvailability(.unavailable(.ddcTurnedOffWithNoSoftwareLeg)),
      DiagnosticsCopy.contrastAvailability(isAvailable: false, forceSoftware: false),
      DiagnosticsCopy.contrastAvailability(isAvailable: false, forceSoftware: true),
      DiagnosticsCopy.muteAvailability(
        muteEnabled: false, volumeAvailable: true, forceSoftware: false),
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: false, supportsHDR: true, app: Self.app),
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: true, supportsHDR: false, app: Self.app),
    ]
    for support in [VCPSupport.unsupported, .unknown] {
      answers.append(
        DiagnosticsCopy.volumeAvailability(
          override: .auto, isAvailable: true, support: support,
          hasDescription: true, forceSoftware: false, app: Self.app))
    }
    answers.append(
      DiagnosticsCopy.volumeAvailability(
        override: .forceNone, isAvailable: true, support: .supported,
        hasDescription: true, forceSoftware: false, app: Self.app))

    for answer in answers {
      #expect(answer != "Unavailable")
      #expect(answer != "Not supported")
      // Every one of them states a reason after the verdict.
      #expect(answer.contains(":") || answer.contains("Either"), "bare verdict: \(answer)")
    }
  }

  /// Brightness has THREE outcomes, and `.softwareOnly` is the one where PART of
  /// the slider works. Reporting it as either available or unavailable would be
  /// false in the half that matters.
  @Test func partlyAvailableBrightnessSaysWhichPartMoves() {
    #expect(DiagnosticsCopy.brightnessAvailability(.hardware) == "Available")
    #expect(DiagnosticsCopy.brightnessAvailability(.native) == "Available")
    #expect(
      DiagnosticsCopy.brightnessAvailability(
        .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.25))
        == "Partly available: the hardware brightness command is turned off, so only the part of the slider below 25% moves anything")
    #expect(
      DiagnosticsCopy.brightnessAvailability(.unavailable(.ddcTurnedOffWithNoSoftwareLeg))
        == "Unavailable: combined dimming is off for this display and its hardware brightness command is turned off")
  }

  /// `supportsHDR` false has three causes and only one of them is the display's
  /// fault, so the sentence names two possibilities and says they are
  /// indistinguishable from here. The DisplayServices arm is checked FIRST and
  /// is a different framework.
  @Test func hdrNamesBothCausesRatherThanBlamingTheDisplay() {
    #expect(
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: true, supportsHDR: true, app: Self.app) == "Available")
    #expect(
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: false, supportsHDR: true, app: Self.app)
        == "Unavailable: macOS did not load the framework Candela needs for HDR brightness")
    #expect(
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: true, supportsHDR: false, app: Self.app)
        == "Unavailable: Candela has no HDR answer for this display. Either it lists no HDR modes, or macOS did not load the framework Candela asks. From here the two look the same.")
    // A machine with no private frameworks at all fails the FIRST guard, not
    // the second: behind the supportsHDR check this arm could never fire.
    #expect(
      DiagnosticsCopy.hdrAvailability(
        displayServicesAvailable: false, supportsHDR: false, app: Self.app)
        == "Unavailable: macOS did not load the framework Candela needs for HDR brightness")
  }

  // MARK: - Verdict

  /// The arms are an ORDER, not a set, and each was previously tested only with
  /// the others neutral, so swapping two of them changed no test. Added after a
  /// review mutation swapped `.unavailable` past `lastApplyFailed` and all 39
  /// tests still passed: a display with DDC turned off AND a failed apply would
  /// have said "try a different cable" about a path that sends nothing over a
  /// cable at all. The HDR precedence below was already pinned this way, so the
  /// omission was an oversight rather than a decision.
  @Test func unavailableOutranksAFailedApplyWhenBothAreTrue() {
    #expect(
      DiagnosticsCopy.verdict(
        isBuiltIn: false, path: .unavailable(.ddcTurnedOffWithNoSoftwareLeg),
        lastApplyFailed: true, hasAppliedTarget: true, evidence: .answered, app: Self.app)
        == "Nothing is moving this display's brightness. See Availability below.")
  }

  @Test func theVerdictSaysTheMostActionableTrueThing() {
    #expect(
      DiagnosticsCopy.verdict(
        isBuiltIn: true, path: .native, lastApplyFailed: false,
        hasAppliedTarget: true, evidence: .answered, app: Self.app)
        == "macOS controls this display's brightness directly, so there is nothing for Candela to send over a cable.")
    #expect(
      DiagnosticsCopy.verdict(
        isBuiltIn: false, path: .unavailable(.ddcTurnedOffWithNoSoftwareLeg),
        lastApplyFailed: false, hasAppliedTarget: true, evidence: .answered, app: Self.app)
        == "Nothing is moving this display's brightness. See Availability below.")
    #expect(
      DiagnosticsCopy.verdict(
        isBuiltIn: false, path: .hardware, lastApplyFailed: true,
        hasAppliedTarget: true, evidence: .answered, app: Self.app)
        == "The last brightness command was not accepted. Try a different cable or port.")
    #expect(
      DiagnosticsCopy.verdict(
        isBuiltIn: false, path: .hardware, lastApplyFailed: false,
        hasAppliedTarget: false, evidence: .answered, app: Self.app)
        == "Candela has not sent anything to this display yet.")
  }

  /// The three "it is working" endings, and the write-only one is its own
  /// sentence: a display that is accepting every command while never answering
  /// a read is working, and saying so without the caveat would leave every
  /// other row on the page unexplained.
  @Test func aWorkingDisplayStillReportsHowItAnswersReads() {
    func verdict(_ evidence: DDCReadEvidence) -> String {
      DiagnosticsCopy.verdict(
        isBuiltIn: false, path: .hardware, lastApplyFailed: false,
        hasAppliedTarget: true, evidence: evidence, app: Self.app)
    }
    #expect(verdict(.answered) == "Brightness is being sent to this display and accepted.")
    #expect(verdict(.notAttempted) == "Brightness is being sent to this display and accepted.")
    #expect(
      verdict(.allZeros)
        == "Brightness is being sent to this display and accepted, but it never answers a read.")
    #expect(
      verdict(.noReply)
        == "Brightness is being sent to this display and accepted, but it is not answering reads.")
  }

  // MARK: - This display

  /// "Not enumerated yet" and "reported nothing" are different facts, and this
  /// row used to collapse them, saying the display reported nothing when nothing
  /// had been READ.
  /// `notStated` is a tag the capabilities string does not CARRY, which is not
  /// the display answering with an empty one. Its own docstring forbids "None"
  /// for exactly that reason, and nothing enforced it: a review mutation
  /// changed it to "None" and all 39 tests passed, because it appeared only
  /// inside the everySentence sweep and never in an equality. Its neighbour
  /// `notEnumerated` was pinned below from the start, so this was an asymmetry
  /// rather than a decision.
  @Test func aTagTheDescriptionLacksIsNeverReportedAsNone() {
    #expect(DiagnosticsCopy.notStated == "Not stated")
  }

  @Test func nothingLookedForIsNeverReportedAsNothingFound() {
    #expect(DiagnosticsCopy.connection(nil) == "Not enumerated yet")
    #expect(DiagnosticsCopy.manufacturer(nil) == "Not enumerated yet")
    #expect(DiagnosticsCopy.serial(nil) == "Not enumerated yet")
    #expect(DiagnosticsCopy.displayKey(nil) == "Not enumerated yet")
    #expect(DiagnosticsCopy.mirroring(isMirrorSlave: nil) == "Not enumerated yet")

    let silent = facts(transportUp: nil, transportDown: nil, manufacturer: nil)
    #expect(DiagnosticsCopy.connection(silent) == "This display does not report its connection type")
    #expect(DiagnosticsCopy.manufacturer(silent) == "Not reported")
    #expect(DiagnosticsCopy.serial(silent) == "Not reported")
  }

  /// Rendered as the kernel spelled it. One value when the two ends agree, both
  /// when they do not, and nil only when neither end said anything.
  @Test func theTransportIsCarriedVerbatim() {
    #expect(DiagnosticsCopy.transport(nil) == nil)
    #expect(DiagnosticsCopy.transport(facts(transportUp: "DisplayPort", transportDown: "DisplayPort")) == "DisplayPort")
    #expect(DiagnosticsCopy.transport(facts(transportUp: "USB-C", transportDown: "DisplayPort")) == "USB-C → DisplayPort")
    #expect(DiagnosticsCopy.transport(facts(transportUp: "HDMI", transportDown: nil)) == "HDMI")
    #expect(DiagnosticsCopy.transport(facts(transportUp: nil, transportDown: "HDMI")) == "HDMI")
    #expect(DiagnosticsCopy.transport(facts(transportUp: nil, transportDown: nil)) == nil)
    #expect(DiagnosticsCopy.connection(facts(transportUp: "HDMI", transportDown: "HDMI")) == "HDMI")
  }

  @Test func anAlphanumericSerialWinsOverANumericOne() {
    #expect(DiagnosticsCopy.serial(facts(alphanumericSerial: "ABC123", numericSerial: 42)) == "ABC123")
    #expect(DiagnosticsCopy.serial(facts(alphanumericSerial: nil, numericSerial: 42)) == "42")
  }

  /// The tooltip carries the PATH, and tells "not read yet" from "reports none":
  /// the same rule as every other identity row.
  @Test func theSystemPortPathTellsUnreadFromUnreported() {
    #expect(
      DiagnosticsCopy.ioregPath(nil)
        == "The system port path for this display has not been read yet.")
    #expect(
      DiagnosticsCopy.ioregPath(facts(ioDisplayLocation: nil))
        == "This display reports no system port path.")
    #expect(
      DiagnosticsCopy.ioregPath(facts(ioDisplayLocation: "IOService:/AppleARMPE/dp"))
        == "System port path: IOService:/AppleARMPE/dp")
  }

  @Test func aDisplaySizeReadsInCentimetres() {
    #expect(DiagnosticsCopy.displaySize(widthCm: 79, heightCm: 34) == "79 × 34 cm")
  }

  /// Three distinct answers: "none on this display" is a measurement, "not
  /// available" is a missing capability, and conflating them would report a
  /// capability gap as a fact about the display.
  @Test func revealedResolutionsTellAMeasurementFromAMissingCapability() {
    #expect(
      DiagnosticsCopy.additionalResolutions(revealed: 0, revealsHiddenModes: false)
        == "Not available on this version of macOS")
    // The count is ignored when the capability is missing: a 0 there would be a
    // measurement nobody took.
    #expect(
      DiagnosticsCopy.additionalResolutions(revealed: 7, revealsHiddenModes: false)
        == "Not available on this version of macOS")
    #expect(
      DiagnosticsCopy.additionalResolutions(revealed: 0, revealsHiddenModes: true)
        == "None for this display")
    #expect(
      DiagnosticsCopy.additionalResolutions(revealed: 7, revealsHiddenModes: true) == "7")
  }

  // MARK: - Brightness control

  @Test func everyBrightnessPathHasItsOwnSentence() {
    #expect(DiagnosticsCopy.brightnessPath(.native) == "macOS native brightness")
    #expect(DiagnosticsCopy.brightnessPath(.hardware) == "Hardware commands over the data cable")
    #expect(
      DiagnosticsCopy.brightnessPath(.software(.gamma))
        == "Software, through the display's color profile")
    #expect(
      DiagnosticsCopy.brightnessPath(.software(.overlay)) == "Software, through a dark overlay")
    #expect(
      DiagnosticsCopy.brightnessPath(.combined(switchingValue: 0.25, backend: .gamma))
        == "Split at 25%: software below, the data cable above")
    #expect(
      DiagnosticsCopy.brightnessPath(.combined(switchingValue: 0.25, backend: .overlay))
        == "Split at 25%: overlay below, the data cable above")
    #expect(
      DiagnosticsCopy.brightnessPath(
        .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.3))
        == "Software only below 30%, through the display's color profile")
    #expect(
      DiagnosticsCopy.brightnessPath(
        .softwareOnly(backend: .overlay, reason: .ddcTurnedOff, dimsBelow: 0.3))
        == "Software only below 30%, through a dark overlay")
    #expect(
      DiagnosticsCopy.brightnessPath(.unavailable(.ddcTurnedOffWithNoSoftwareLeg))
        == "Nothing is moving this display's brightness")
  }

  @Test func nativeBrightnessNamesTheFrameworkThatDidNotLoad() {
    #expect(
      DiagnosticsCopy.nativeBrightness(isAvailable: true, app: Self.app)
        == "Available on this Mac")
    #expect(
      DiagnosticsCopy.nativeBrightness(isAvailable: false, app: Self.app)
        == "Unavailable: macOS did not load the framework Candela needs for it")
  }

  /// The built-in's DDC story is not a failure, a preference, or something a
  /// future release fixes, so it is not phrased as any of those.
  @Test func theBuiltInsHardwareControlIsNotPhrasedAsAFailure() {
    #expect(
      DiagnosticsCopy.builtInHardwareControl
        == "Does not apply: this display has no data cable to carry hardware commands")
  }

  /// "None noticed" is not "None this session": the counter restarts on every
  /// reconfiguration, and it only counts what was looked at.
  @Test func gammaConflictsClaimNoWindowTheCounterDoesNotHave() {
    #expect(DiagnosticsCopy.gammaConflicts(0) == "None noticed")
    #expect(
      DiagnosticsCopy.gammaConflicts(3)
        == "3: another app keeps taking this display's color profile back")
  }

  // MARK: - Advertised commands

  /// Never a claim about what macOS hides, only about what the display listed.
  /// nil codes is a description that did not parse, which is NOT an empty list.
  @Test func advertisedCommandsClaimNothingAboutADescriptionThatDidNotParse() {
    #expect(
      DiagnosticsCopy.advertisedCommands(nil, app: Self.app)
        == "The description did not parse, so Candela makes no claim about it")
    #expect(
      DiagnosticsCopy.advertisedCommands([0x02, 0x04, 0x06], app: Self.app)
        == "None of the four Candela uses, out of 3 listed")
  }

  @Test func advertisedCommandsNameTheOnesTheAppSpeaksInOrder() {
    #expect(
      DiagnosticsCopy.advertisedCommands(
        [VCP.brightness, VCP.contrast, VCP.audioSpeakerVolume, VCP.audioMuteScreenBlank, 0x02],
        app: Self.app)
        == "brightness, contrast, volume, mute (of 5 commands listed)")
    // The Dell: full description, no VCP 0x62.
    #expect(
      DiagnosticsCopy.advertisedCommands([VCP.brightness, VCP.contrast], app: Self.app)
        == "brightness, contrast (of 2 commands listed)")
  }

  // MARK: - Right now

  @Test func theWriteGateAndHDRStateHaveWordsNotColours() {
    #expect(DiagnosticsCopy.hdrState(engaged: true) == "Engaged")
    #expect(DiagnosticsCopy.hdrState(engaged: false) == "Off")
    #expect(DiagnosticsCopy.writeGate(isSending: true) == "Being sent")
    #expect(
      DiagnosticsCopy.writeGate(isSending: false)
        == "Paused while displays are changing or asleep")
    #expect(DiagnosticsCopy.safeModeState == "On for this session")
  }

  /// "Watching nothing" and "not running" are different facts, and the tap not
  /// running is the one the user can act on.
  @Test func watchingNothingIsNotTheSameAsTheTapNotRunning() {
    #expect(
      DiagnosticsCopy.watchedKeys(families: [], tapRunning: false)
        == "None: the media-key tap is not running")
    #expect(
      DiagnosticsCopy.watchedKeys(families: [], tapRunning: true)
        == "None: every media key is going straight to macOS")
    #expect(
      DiagnosticsCopy.watchedKeys(families: ["brightness"], tapRunning: true) == "brightness")
    #expect(
      DiagnosticsCopy.watchedKeys(families: ["brightness", "volume and mute"], tapRunning: true)
        == "brightness, volume and mute")
  }

  @Test func keyFamiliesAreNamedInAFixedOrder() {
    #expect(DiagnosticsCopy.watchedKeyFamilies(brightness: false, volume: false, mute: false) == [])
    #expect(
      DiagnosticsCopy.watchedKeyFamilies(brightness: true, volume: true, mute: true)
        == ["brightness", "volume and mute"])
    #expect(
      DiagnosticsCopy.watchedKeyFamilies(brightness: false, volume: true, mute: true)
        == ["volume and mute"])
  }

  /// The volume keys and the mute key are armed on separate verdicts, because
  /// they write separate registers: a display can list one and deny the other.
  /// The report has to be able to say so, or it describes a tap that is not the
  /// one running.
  @Test func volumeAndMuteAreNamedApartWhenOnlyOneIsWatched() {
    #expect(
      DiagnosticsCopy.watchedKeyFamilies(brightness: false, volume: true, mute: false)
        == ["volume"])
    #expect(
      DiagnosticsCopy.watchedKeyFamilies(brightness: true, volume: false, mute: true)
        == ["brightness", "mute"])
  }

  @Test func theSoundOutputRowNamesTheDeviceEitherWay() {
    #expect(DiagnosticsCopy.noDefaultOutputDevice == "macOS reports no default output device")
    #expect(
      DiagnosticsCopy.audioMatch(deviceName: "MAG 341C", matches: true)
        == "MAG 341C: matched to this display")
    #expect(
      DiagnosticsCopy.audioMatch(deviceName: "MacBook Pro Speakers", matches: false)
        == "MacBook Pro Speakers: not matched to this display")
  }

  /// A failure after a success keeps BOTH facts: what is on the display now, and
  /// that the most recent attempt did not land. Reporting only the second would
  /// lose the value the display is actually showing.
  @Test func aFailedCommandNeverErasesTheLastAcceptedOne() {
    #expect(
      DiagnosticsCopy.lastWrite(target: nil, failed: false)
        == "Nothing has been sent to this display yet")
    #expect(
      DiagnosticsCopy.lastWrite(target: nil, failed: true)
        == "The last command was not accepted")
    #expect(
      DiagnosticsCopy.lastWrite(target: .ddc(raw: 42), failed: false)
        == "Accepted: value 42 over the data cable")
    #expect(
      DiagnosticsCopy.lastWrite(target: .ddc(raw: 42), failed: true)
        == "Last accepted: value 42 over the data cable. The most recent command was not accepted.")
    #expect(
      DiagnosticsCopy.lastWrite(target: .native(0.5), failed: false)
        == "Accepted: 50% through macOS")
  }

  /// Claims only what `CGDisplayMirrorsDisplay` can support: a master reports
  /// null and so does a standalone display, so this is never a membership test.
  @Test func mirroringClaimsOnlyWhatTheCallCanSupport() {
    #expect(
      DiagnosticsCopy.mirroring(isMirrorSlave: true) == "Showing another display's contents")
    #expect(DiagnosticsCopy.mirroring(isMirrorSlave: false) == "Showing its own contents")
  }

  // MARK: - Modes

  @Test func aModeReadsAsSizeAndRefreshRate() {
    let mode = DisplayModeFixtures.mode(1, logical: (3440, 1440), pixels: (3440, 1440), hz: 175)
    #expect(DiagnosticsCopy.mode(mode) == "3440 × 1440 at 175 Hz")
  }

  /// The page's row and the event ring say the same three things at two lengths.
  /// Neither may report a substitution without naming what is on the display.
  @Test func theReapplyProblemAndItsEventEntryAgree() {
    let mode = DisplayModeFixtures.mode(1, logical: (1920, 1080), pixels: (3840, 2160), hz: 60)
    #expect(
      DiagnosticsCopy.reapplyProblem(.substituted(mode), app: Self.app)
        == "Candela could not restore your saved resolution and used 1920 × 1080 at 60 Hz instead")
    #expect(
      DiagnosticsCopy.reapplyEvent(.substituted(mode))
        == "saved resolution unavailable, used 1920 × 1080 at 60 Hz")
    #expect(
      DiagnosticsCopy.reapplyProblem(.unavailable, app: Self.app)
        == "Your saved resolution is not offered by this display right now")
    #expect(DiagnosticsCopy.reapplyEvent(.unavailable) == "saved resolution not offered")
    #expect(
      DiagnosticsCopy.reapplyProblem(.failed(DisplayConfigError(cgErrorCode: 1000)), app: Self.app)
        == "Restoring your saved resolution failed")
    #expect(
      DiagnosticsCopy.reapplyEvent(.failed(DisplayConfigError(cgErrorCode: 1000)))
        == "restoring the saved resolution failed")
  }

  // MARK: - House rules

  /// The product name is provisional (it lives in `AppInfo` so the rename is one
  /// line), so nothing here may bake in the literal.
  @Test func theProductNameIsNeverBakedIn() {
    let renamed = DiagnosticsCopy.readEvidence(.notAttempted, app: "Lumen")
    #expect(renamed == "Lumen has not read from this display")
    #expect(!renamed.contains("Candela"))

    #expect(
      DiagnosticsCopy.brightnessScale(
        didReadMax: false, maxValue: 100, evidence: .notAttempted, app: "Lumen")
        == "Assumed 100: Lumen has not asked this display for its scale")
  }

  /// SO14: hardware is always a "display" in user-visible copy. The type and
  /// comment vocabulary still says panel; the strings do not.
  @Test func noProducedStringSaysPanel() {
    for produced in Self.everySentence() {
      #expect(!produced.lowercased().contains("panel"), "says panel: \(produced)")
    }
  }

  /// §6: no em dashes in user-visible copy. The one exception used to be the
  /// row label "Not offered - no matching timing", which lived inline in the
  /// view where no test could reach it, and shipped with an em dash from the
  /// day it was written until #129. It is now `wireTimingWithheldLabel` here,
  /// so this guard covers it and the class of defect is closed rather than
  /// documented.
  @Test func noProducedStringContainsAnEmDash() {
    for produced in Self.everySentence() {
      #expect(!produced.contains("—"), "em dash: \(produced)")
    }
  }

  /// Internal key names never reach copy (D25). `forceSw` and `unavailableDDC`
  /// are the two that the availability sentences are derived from and so the two
  /// most likely to leak.
  @Test func noProducedStringLeaksAPrefKeyName() {
    for produced in Self.everySentence() {
      for key in ["forceSw", "unavailableDDC", "audioSinkOverride", "enableMuteUnmute"] {
        #expect(!produced.contains(key), "leaks \(key): \(produced)")
      }
    }
  }

  // MARK: - Fixtures

  /// Every sentence this type can produce, for the rules that bind all of them.
  private static func everySentence() -> [String] {
    let evidences: [DDCReadEvidence] = [.notAttempted, .answered, .allZeros, .noReply]
    let paths: [BrightnessPath] = [
      .native, .hardware, .software(.gamma), .software(.overlay),
      .combined(switchingValue: 0.25, backend: .gamma),
      .combined(switchingValue: 0.25, backend: .overlay),
      .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.3),
      .softwareOnly(backend: .overlay, reason: .ddcTurnedOff, dimsBelow: 0.3),
      .unavailable(.ddcTurnedOffWithNoSoftwareLeg),
    ]
    let mode = DisplayModeFixtures.mode(1, logical: (3440, 1440), pixels: (3440, 1440), hz: 175)

    let notices: [ModeReapplyNotice] = [
      .substituted(mode), .unavailable, .failed(DisplayConfigError(cgErrorCode: 1000)),
    ]

    var out: [String] = [
      DiagnosticsCopy.notEnumerated,
      DiagnosticsCopy.notStated,
      DiagnosticsCopy.wireTimingWithheldLabel,
      DiagnosticsCopy.wireTimingCheckLabel,
      DiagnosticsCopy.wireTimingGuardOff,
      DiagnosticsCopy.wireTimingWithheld,
      DiagnosticsCopy.builtInHardwareControl,
      DiagnosticsCopy.safeModeState,
      DiagnosticsCopy.noDefaultOutputDevice,
      DiagnosticsCopy.mode(mode),
      DiagnosticsCopy.displaySize(widthCm: 79, heightCm: 34),
      DiagnosticsCopy.audioMatch(deviceName: "MAG 341C", matches: true),
      DiagnosticsCopy.audioMatch(deviceName: "MAG 341C", matches: false),
      DiagnosticsCopy.gammaConflicts(0),
      DiagnosticsCopy.gammaConflicts(3),
      DiagnosticsCopy.ioregPath(nil),
      DiagnosticsCopy.ioregPath(facts(ioDisplayLocation: nil)),
      DiagnosticsCopy.ioregPath(facts()),
      DiagnosticsCopy.connection(nil),
      DiagnosticsCopy.connection(facts(transportUp: nil, transportDown: nil)),
      DiagnosticsCopy.connection(facts()),
      DiagnosticsCopy.manufacturer(nil),
      DiagnosticsCopy.manufacturer(facts(manufacturer: nil)),
      DiagnosticsCopy.serial(nil),
      DiagnosticsCopy.serial(facts()),
      DiagnosticsCopy.displayKey(nil),
      DiagnosticsCopy.displayKey("dell-u2725qe"),
      DiagnosticsCopy.mirroring(isMirrorSlave: nil),
      DiagnosticsCopy.mirroring(isMirrorSlave: true),
      DiagnosticsCopy.mirroring(isMirrorSlave: false),
      DiagnosticsCopy.hdrState(engaged: true),
      DiagnosticsCopy.hdrState(engaged: false),
      DiagnosticsCopy.writeGate(isSending: true),
      DiagnosticsCopy.writeGate(isSending: false),
      DiagnosticsCopy.nativeBrightness(isAvailable: true, app: app),
      DiagnosticsCopy.nativeBrightness(isAvailable: false, app: app),
      DiagnosticsCopy.advertisedCommands(nil, app: app),
      DiagnosticsCopy.advertisedCommands([0x02], app: app),
      DiagnosticsCopy.advertisedCommands([VCP.brightness, VCP.contrast], app: app),
      DiagnosticsCopy.lastWrite(target: nil, failed: false),
      DiagnosticsCopy.lastWrite(target: nil, failed: true),
      DiagnosticsCopy.lastWrite(target: .ddc(raw: 42), failed: false),
      DiagnosticsCopy.lastWrite(target: .ddc(raw: 42), failed: true),
      DiagnosticsCopy.lastWrite(target: .native(0.5), failed: false),
      DiagnosticsCopy.watchedKeys(families: [], tapRunning: false),
      DiagnosticsCopy.watchedKeys(families: [], tapRunning: true),
      DiagnosticsCopy.watchedKeys(
        families: ["brightness", "volume and mute"], tapRunning: true),
      DiagnosticsCopy.additionalResolutions(revealed: 0, revealsHiddenModes: false),
      DiagnosticsCopy.additionalResolutions(revealed: 0, revealsHiddenModes: true),
      DiagnosticsCopy.additionalResolutions(revealed: 7, revealsHiddenModes: true),
    ]
    out += notices.map { DiagnosticsCopy.reapplyProblem($0, app: app) }
    out += notices.map { DiagnosticsCopy.reapplyEvent($0) }
    out += DiagnosticsCopy.watchedKeyFamilies(brightness: true, volume: true, mute: true)
    out += DiagnosticsCopy.watchedKeyFamilies(brightness: false, volume: true, mute: false)
    out += DiagnosticsCopy.watchedKeyFamilies(brightness: false, volume: false, mute: true)
    out += evidences.map { DiagnosticsCopy.readEvidence($0, app: app) }
    out += evidences.map { DiagnosticsCopy.readbackVerdict($0) }
    out += paths.map { DiagnosticsCopy.brightnessPath($0) }
    out += paths.map { DiagnosticsCopy.brightnessAvailability($0) }
    for evidence in evidences {
      out.append(
        DiagnosticsCopy.brightnessScale(
          didReadMax: true, maxValue: 100, evidence: evidence, app: app))
      out.append(
        DiagnosticsCopy.brightnessScale(
          didReadMax: false, maxValue: 100, evidence: evidence, app: app))
    }
    for isBuiltIn in [true, false] {
      for path in paths {
        for failed in [true, false] {
          for hasTarget in [true, false] {
            for evidence in evidences {
              out.append(
                DiagnosticsCopy.verdict(
                  isBuiltIn: isBuiltIn, path: path, lastApplyFailed: failed,
                  hasAppliedTarget: hasTarget, evidence: evidence, app: app))
            }
          }
        }
      }
    }
    for hasDescription in [true, false] {
      for parsed in [true, false] {
        for asked in [true, false] {
          out.append(
            DiagnosticsCopy.capabilityAnswer(
              hasDescription: hasDescription, parsedACommandList: parsed,
              wasAsked: asked, app: app))
        }
      }
    }
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for isAvailable in [true, false] {
        for support in [VCPSupport?.none, .supported, .unsupported, .unknown] {
          for hasDescription in [true, false] {
            for forceSoftware in [true, false] {
              out.append(
                DiagnosticsCopy.volumeAvailability(
                  override: override, isAvailable: isAvailable, support: support,
                  hasDescription: hasDescription, forceSoftware: forceSoftware, app: app))
            }
          }
        }
      }
    }
    for available in [true, false] {
      for forceSoftware in [true, false] {
        out.append(
          DiagnosticsCopy.contrastAvailability(
            isAvailable: available, forceSoftware: forceSoftware))
        for muteEnabled in [true, false] {
          out.append(
            DiagnosticsCopy.muteAvailability(
              muteEnabled: muteEnabled, volumeAvailable: available,
              forceSoftware: forceSoftware))
        }
        out.append(
          DiagnosticsCopy.hdrAvailability(
            displayServicesAvailable: available, supportsHDR: forceSoftware, app: app))
      }
    }
    return out
  }

  private static func facts(
    transportUp: String? = "DisplayPort",
    transportDown: String? = "DisplayPort",
    manufacturer: String? = "DEL",
    alphanumericSerial: String? = nil,
    numericSerial: Int64? = nil,
    ioDisplayLocation: String? = "IOService:/dp"
  ) -> DisplayHardwareFacts {
    DisplayHardwareFacts(
      transportUpstream: transportUp,
      transportDownstream: transportDown,
      manufacturerID: manufacturer,
      alphanumericSerialNumber: alphanumericSerial,
      numericSerialNumber: numericSerial,
      physicalWidthCm: 60,
      physicalHeightCm: 34,
      ioDisplayLocation: ioDisplayLocation,
      ioregMatchScore: 16
    )
  }

  private func facts(
    transportUp: String? = "DisplayPort",
    transportDown: String? = "DisplayPort",
    manufacturer: String? = "DEL",
    alphanumericSerial: String? = nil,
    numericSerial: Int64? = nil,
    ioDisplayLocation: String? = "IOService:/dp"
  ) -> DisplayHardwareFacts {
    Self.facts(
      transportUp: transportUp, transportDown: transportDown, manufacturer: manufacturer,
      alphanumericSerial: alphanumericSerial, numericSerial: numericSerial,
      ioDisplayLocation: ioDisplayLocation)
  }
}
