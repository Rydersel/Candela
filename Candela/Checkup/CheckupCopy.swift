import CandelaKit

/// Every user-visible string in the checkup flow, in one place so the copy
/// rules can be checked over the whole surface at once: no em dashes, no
/// internal key names, and no verdict on the display. A checkup records
/// observations; it never certifies a panel, and no line here may imply it has.
enum CheckupCopy {

  // MARK: - Scenario

  static let scenarioTitle = "What is this checkup for?"
  static let scenarioSubtitle =
    "The answer is recorded on the report. Every check runs either way; nothing here changes what is measured."
  static let scenarioNew = "A new monitor, before the return window closes"
  static let scenarioUsed = "A used purchase"
  static let scenarioRecheck = "A recheck of a display already in use"

  static func scenarioLabel(_ scenario: CheckupScenario) -> String {
    switch scenario {
    case .newMonitor: scenarioNew
    case .usedPurchase: scenarioUsed
    case .recheck: scenarioRecheck
    }
  }

  // MARK: - Display pick

  static let pickTitle = "Which display?"
  static let pickSubtitle =
    "One run covers one display. The report is filed under the display's own identity, so a later run on the same panel lands beside this one."
  static let pickEmpty = "No display is attached that a checkup can run on."

  static func panelClassLine(_ c: CheckupPanelClass) -> String {
    switch c {
    case .readsDDC: "Answers DDC: readback checks will run."
    case .writeOnlyDDC: "Write-only DDC: readback checks will be recorded as not observed."
    case .noDDC: "No DDC path: readback checks will be recorded as not observed."
    }
  }

  // MARK: - Plan

  static let planTitle = "What will run"
  static let planSubtitle =
    "Each row below becomes one line in the report, with the evidence behind it."

  static func planWorstCase(seconds: Int) -> String {
    "The visual fields take at most \(seconds / 60) minutes if every one is shown three times. Nothing runs until you continue."
  }

  // MARK: - The measured legs

  static let identityTitle = "What the display reports about itself"
  static let capabilitiesTitle = "What the display answers"
  static let nativeModeTitle = "The native resolution"
  static let refreshTitle = "The refresh sweep"
  static let hdrTitle = "HDR"
  static let running = "Running this check on the display."
  static let refusalNote =
    "A refusal is recorded with its reason and the run carries on. Nothing here ends a checkup except you."

  // MARK: - The planted control

  static let plantDisclosureTitle = "One planted mark"
  static let plantDisclosure =
    "Before the colour fields, Candela will plant one small mark on the screen at a position it will not reveal. When you see it, tap where it is. This checks that a defect of that size is visible from where you sit, so the report can say how sensitive your answers were."

  static func plantMissed(size: Int) -> String {
    "At this distance a mark of \(size) pixels would not be visible. The same field will show once more with a larger mark."
  }

  static let plantMissedTwice =
    "A mark of 8 pixels was not visible either, so the colour fields will be recorded as inconclusive rather than clean. The other checks stand."

  // MARK: - Fields

  static let showAgain = "Show it again"
  static let showAgainCap = "Each field can be shown three times, so the run stays short on the panel."
  static let start = "Start"
  static let continueLabel = "Continue"
  static let back = "Back"
  static let answerPrompt = "What did you see?"
  static let recordedPrefix = "Recorded"

  static func instruction(for kind: CheckupFieldKind) -> String {
    switch kind {
    case .black: "The screen will be solid black for up to 20 seconds. Look for any point that is not black: a white, red, green or blue dot. You will be asked whether you saw none, one, or more than one."
    case .red: "The screen will be solid red for up to 20 seconds. Look for any dot that is not red: black, white or another colour. You will be asked whether you saw none, one, or more than one."
    case .green: "The screen will be solid green for up to 20 seconds. Look for any dot that is not green. You will be asked whether you saw none, one, or more than one."
    case .blue: "The screen will be solid blue for up to 20 seconds. Look for any dot that is not blue. You will be asked whether you saw none, one, or more than one."
    case .gray7: "The screen will be a very dark gray for up to 20 seconds. Look for vertical or horizontal bands, streaks, or areas that are lighter or darker than the rest. Answer whether you saw any."
    case .gray50: "The screen will be a mid gray for up to 20 seconds. Look for a faint ghost of a previous image, blotches, or a dirty-looking area. Answer whether you saw any."
    case .ramp: "The screen will show a smooth ramp from black on the left to white on the right for up to 20 seconds. Look for visible steps or bands instead of a smooth change. Answer whether you saw any."
    case .white: "The screen will be solid white for up to 10 seconds, the shortest field because it is the brightest. Look for any dot that is not white. You will be asked whether you saw none, one, or more than one."
    case .witness: "The screen will show a circle and a square for up to 20 seconds. Both should look round and square with nothing cut off at the edges. Answer whether the circle looked round and uncut."
    }
  }

  /// The field in prose, for a heading. Never the stored field name: `gray7`
  /// is a key, not something to read out.
  static func fieldName(_ kind: CheckupFieldKind) -> String {
    switch kind {
    case .black: "black field"
    case .red: "red field"
    case .green: "green field"
    case .blue: "blue field"
    case .gray7: "near-black gray field"
    case .gray50: "mid gray field"
    case .ramp: "black-to-white ramp"
    case .white: "white field"
    case .witness: "witness card"
    }
  }

  static func fieldTitle(_ kind: CheckupFieldKind) -> String {
    "The \(fieldName(kind))"
  }

  static let answerNothing = "Nothing"
  static let answerOne = "One mark"
  static let answerMore = "More than one"
  static let answerRound = "Round and uncut"
  static let answerNotRound = "Not round, or cut off"

  static func answerLabel(_ answer: CheckupFieldAnswer) -> String {
    switch answer {
    case .nothing: answerNothing
    case .oneMark: answerOne
    case .moreThanOne: answerMore
    case .roundAndUncut: answerRound
    case .notRound: answerNotRound
    }
  }

  /// The answers a field offers, in the order they are shown. The witness card
  /// asks about geometry, everything else about marks.
  static func answers(for kind: CheckupFieldKind) -> [CheckupFieldAnswer] {
    kind == .witness ? [.roundAndUncut, .notRound] : [.nothing, .oneMark, .moreThanOne]
  }

  static func secondsLeft(_ seconds: Int) -> String {
    seconds == 1 ? "1 second left" : "\(seconds) seconds left"
  }

  static let tapHint = "Tap the mark on the field itself before answering, so the report can record where it was."

  static let secondDotTitle = "Is the extra mark still there?"
  static let secondDotPrompt = "The same field is showing again with no planted mark. Is the extra mark still there? If so, tap it."

  /// The field strip's resting text, replaced by the field's own instruction
  /// before every showing. It says why the screen went solid and where the
  /// answers are, because on a one-display run the flow window is behind the
  /// field and cannot be reached.
  static let onlyDisplayStrip =
    "This display is showing a \(AppInfo.productName) checkup field. Answer below."

  // MARK: - Summary

  static let summaryTitle = "What this run observed"
  static let summaryComplete = "The run reached the end of the protocol."

  static func summaryIncomplete(reason: String) -> String {
    "This run ended early: \(reason). Everything recorded before that point stands."
  }

  static let selfReportedNote =
    "The visual fields are your own attestations, recorded at the control sensitivity above. Candela did not see your screen."

  static let export = "Export report"
  static let copySummary = "Copy summary"
  static let copied = "Copied"
  static let exportFailed = "The report could not be saved."
  static let acknowledge = "OK"
  static let headerSentence = CheckupReport.headerSentence

  // MARK: - Claims

  static func familyTitle(_ family: CheckupFamily) -> String {
    switch family {
    case .identity: "Identity"
    case .capabilities: "Capabilities"
    case .nativeMode: "Native mode"
    case .refresh: "Refresh"
    case .visualField: "Visual fields"
    case .hdr: "HDR"
    }
  }

  static func verdictLabel(_ verdict: CheckupVerdict) -> String {
    switch verdict {
    case .observed: "observed"
    case .refused: "refused"
    case .notObserved: "not observed"
    case .selfReported: "self-reported"
    case .inconclusive: "inconclusive"
    }
  }

  /// A check's name in prose. The stored ids are shipped schema and read like
  /// the keys they are, so nothing in the flow prints one.
  static func claimLabel(id: String) -> String {
    switch id {
    case CheckupCheckID.identity: return "The display's EDID"
    case CheckupCheckID.capabilityBrightness: return "Brightness over DDC"
    case CheckupCheckID.capabilityContrast: return "Contrast over DDC"
    case CheckupCheckID.capabilityVolume: return "Volume over DDC"
    case CheckupCheckID.nativeMode: return "Native resolution"
    case CheckupCheckID.refreshSweep: return "Refresh sweep"
    case CheckupCheckID.hdrFlags: return "HDR support"
    case CheckupCheckID.hdrSettle: return "HDR switch"
    default: break
    }
    for kind in CheckupFieldKind.allCases where id == CheckupCheckID.field(kind) {
      return fieldTitle(kind)
    }
    // One refresh rate out of the sweep. The ids carry the rate itself, so the
    // rate is what a person should read here.
    if id.hasPrefix("refresh."), let hz = id.split(separator: ".", maxSplits: 1).last {
      return "\(hz) Hz"
    }
    // Nothing reaches this today; it exists so a check added later cannot leak
    // its key onto the screen while nobody is looking.
    return id.split(separator: ".").map(String.init).last.map(sentenceCased) ?? id
  }

  private static func sentenceCased(_ s: String) -> String {
    guard let first = s.first else { return s }
    return first.uppercased() + s.dropFirst()
  }

  /// Every fixed string plus one sample of each parameterised one, so the copy
  /// rules can be asserted over the surface rather than over a reviewer's memory.
  static var allStringsForTest: [String] {
    [scenarioTitle, scenarioSubtitle, scenarioNew, scenarioUsed, scenarioRecheck, pickTitle,
     pickSubtitle, pickEmpty, planTitle, planSubtitle, identityTitle, capabilitiesTitle,
     nativeModeTitle, refreshTitle, hdrTitle, running, refusalNote, plantDisclosureTitle,
     plantDisclosure, plantMissedTwice, showAgain, showAgainCap, start, continueLabel, back,
     answerPrompt, recordedPrefix, answerNothing, answerOne, answerMore, answerRound,
     answerNotRound, tapHint, secondDotTitle, secondDotPrompt, onlyDisplayStrip, summaryTitle,
     summaryComplete, selfReportedNote, export, copySummary, copied, exportFailed, acknowledge,
     headerSentence, plantMissed(size: 4), planWorstCase(seconds: 600), secondsLeft(1),
     secondsLeft(20), summaryIncomplete(reason: "the display disconnected")]
      + CheckupFieldKind.allCases.map(instruction(for:))
      + CheckupFieldKind.allCases.map(fieldTitle)
      + CheckupFieldKind.allCases.map { claimLabel(id: CheckupCheckID.field($0)) }
      + CheckupFamily.allCases.map(familyTitle)
      + [CheckupPanelClass.readsDDC, .writeOnlyDDC, .noDDC].map(panelClassLine)
      + CheckupScenario.allCases.map(scenarioLabel)
      + [CheckupCheckID.identity, CheckupCheckID.capabilityBrightness,
         CheckupCheckID.capabilityContrast, CheckupCheckID.capabilityVolume,
         CheckupCheckID.nativeMode, CheckupCheckID.refreshSweep, CheckupCheckID.hdrFlags,
         CheckupCheckID.hdrSettle, CheckupCheckID.refresh(hz: 120)].map { claimLabel(id: $0) }
  }
}
