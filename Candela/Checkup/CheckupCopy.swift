import CandelaKit

/// Every user-visible string in the checkup flow, in one place so the copy rules
/// (no em dashes, no internal key names, no verdict on the display) can be
/// checked over the whole surface at once.
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

  /// The scenario in a few words, for the subject line; the scenario page's
  /// rows are full sentences.
  static func scenarioWords(_ scenario: CheckupScenario) -> String {
    switch scenario {
    case .newMonitor: "a new monitor"
    case .usedPurchase: "a used purchase"
    case .recheck: "a recheck"
    }
  }

  // MARK: - Display pick

  static let pickTitle = "Which display?"
  static let pickSubtitle =
    "One run covers one display. The report is filed under the display's own identity, so a later run on the same panel lands beside this one."
  static let pickEmpty = "No display is attached that a checkup can run on."

  /// Grouped digits: VoiceOver reads an ungrouped 3840 digit by digit. The row
  /// draws this same string, so what is seen and what is spoken cannot drift.
  static func pixelSizeLine(width: Int, height: Int) -> String {
    ModeSpeech.spoken(logicalWidth: width, logicalHeight: height, refreshHz: nil) + " pixels"
  }

  /// A button publishes no label of its own, so without this a display row
  /// announces as a bare "button". Speaks every line the row draws.
  static func displayRowLabel(_ entry: CheckupDisplayEntry) -> String {
    "\(entry.name), \(pixelSizeLine(width: entry.pixelWidth, height: entry.pixelHeight)). "
      + panelClassLine(entry.panelClass, hdrEngaged: entry.hdrEngaged)
  }

  static func panelClassLine(_ c: CheckupPanelClass, hdrEngaged: Bool) -> String {
    // No-DDC keeps its own line: HDR changes nothing for a panel with no DDC path.
    guard c == .noDDC || !hdrEngaged else { return hdrEngagedLine }
    switch c {
    case .readsDDC: return "Answers DDC: readback checks will run."
    case .writeOnlyDDC: return "Write-only DDC: readback checks will be recorded as not observed."
    case .noDDC: return "No DDC path: readback checks will be recorded as not observed."
    }
  }

  /// DDC is dead in HDR, so the line also says how to get the readback rows to run.
  static let hdrEngagedLine =
    "This display is in HDR mode, which stops DDC: readback checks will be recorded as not observed. Turn HDR off and run the checkup again to have them run."

  /// Quoted on the pick page and in the mid-run failure; both come from the missing NSScreen.
  static let mirroringReason = "mirroring another display; a field cannot be shown on it"

  static let fieldNotShown =
    "This field could not be shown on the display: \(mirroringReason). Nothing was recorded for it."

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

  /// The field's bare noun, for a list of several. Never the stored field name:
  /// `gray7` is a key, not something to read out.
  static func shortFieldName(_ kind: CheckupFieldKind) -> String {
    switch kind {
    case .black: "black"
    case .red: "red"
    case .green: "green"
    case .blue: "blue"
    case .gray7: "near-black gray"
    case .gray50: "mid gray"
    case .ramp: "black-to-white ramp"
    case .white: "white"
    case .witness: "witness card"
    }
  }

  /// The field as a noun phrase, for a heading or for naming the step a run
  /// stopped on. Built from the short name so the two cannot drift.
  static func fieldName(_ kind: CheckupFieldKind) -> String {
    switch kind {
    case .ramp, .witness: shortFieldName(kind)
    default: "\(shortFieldName(kind)) field"
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

  /// The strip's resting text. On a one-display run the flow window is behind
  /// the field, so the strip must say why the screen went solid and where the answers are.
  static let onlyDisplayStrip =
    "This display is showing a \(AppInfo.productName) checkup field. Answer below."

  /// The field window's own title. Borderless, so nobody reads it on screen,
  /// but it is what the Window menu, VoiceOver and every window listing say.
  static let fieldWindowTitle = "\(AppInfo.productName) Checkup Field"

  // MARK: - Summary

  static let summaryTitle = "What this run observed"

  /// Names the run. The date is the UTC day the exported file name carries, so
  /// document and file never disagree.
  static func subjectLine(for report: CheckupReport) -> String {
    let model = report.identity.productName.isEmpty ? "Display" : report.identity.productName
    return "\(model), \(scenarioWords(report.scenario)), \(CheckupStore.day(report.startedAt))"
  }

  /// CK16: which fields were shown with the strip over their lower edge. Nil
  /// when none were, so no caveat sits over an empty list.
  static func occlusionLine(fieldIDs: [String]) -> String? {
    let names = fieldIDs
      .compactMap { id in CheckupFieldKind.allCases.first { CheckupCheckID.field($0) == id } }
      .map(shortFieldName)
    guard !names.isEmpty else { return nil }
    return "Fields shown with the instruction strip over their lower edge: "
      + names.joined(separator: ", ") + "."
  }

  /// One place, because the summary page and the copied text must say it the same way.
  static func detectedAt(pixels: Int) -> String {
    "(control detected at \(pixels) px)"
  }
  static let summaryComplete = "The run reached the end of the protocol."

  static func summaryIncomplete(reason: String) -> String {
    "This run ended early: \(reason). Everything recorded before that point stands."
  }

  // MARK: - The document

  /// CK30: the document itself says the visual fields are attestations: a file
  /// handed to a stranger cannot point at the control sensitivity on screen.
  static let attestationNote =
    "These are the user's attestations at the recorded control sensitivity."

  static let serialLabel = "Serial:"
  static let manufacturedLabel = "Manufactured:"
  static let nativeResolutionLabel = "Native resolution:"
  static let maximumRefreshLabel = "Maximum refresh:"
  static let hdrFlagsLabel = "HDR flags in the display's EDID:"
  static let macOSLabel = "macOS:"
  static let notReported = "not reported"
  static let flagPresent = "present"
  static let flagAbsent = "absent"

  /// CK30: a run that never read the display may not print a serial, a size or
  /// an EDID flag.
  static let identityNotRead = "Identity: not read from the display"

  static func manufactured(week: Int, year: Int) -> String {
    "\(manufacturedLabel) week \(week) of \(year)"
  }

  static func hdrFlagsLine(pq: Bool, hdrGamma: Bool) -> String {
    "\(hdrFlagsLabel) PQ \(pq ? flagPresent : flagAbsent), "
      + "HDR gamma \(hdrGamma ? flagPresent : flagAbsent)"
  }

  /// How the run ended, as the document's last line.
  static func completionLine(_ completion: CheckupCompletion) -> String {
    switch completion {
    case .complete: "Completion: complete. \(summaryComplete)"
    case .incomplete(let reason): "Completion: incomplete. \(summaryIncomplete(reason: reason))"
    }
  }

  static let export = "Export report"
  static let copySummary = "Copy summary"
  static let copied = "Copied"
  static let exportFailed = "The report could not be saved."
  static let acknowledge = "OK"

  /// Why a run ended when the person closed the window. It is read back inside
  /// `summaryIncomplete`, so it is a phrase and not a state name.
  static let closedReason = "the checkup window was closed"
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
    // A check added without copy. The id is shipped schema and must never show,
    // so debug stops here and release says as little as it truthfully can.
    #if DEBUG
      assertionFailure("checkup check id with no copy: \(id)")
    #endif
    return "Check"
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
     summaryComplete, export, copySummary, copied, exportFailed, acknowledge,
     attestationNote, serialLabel, manufacturedLabel, nativeResolutionLabel,
     maximumRefreshLabel, hdrFlagsLabel, macOSLabel, notReported, flagPresent, flagAbsent,
     identityNotRead, manufactured(week: 51, year: 2025), hdrFlagsLine(pq: true, hdrGamma: false),
     completionLine(.complete), completionLine(.incomplete(reason: closedReason)),
     headerSentence, plantMissed(size: 4), planWorstCase(seconds: 600), secondsLeft(1),
     secondsLeft(20), summaryIncomplete(reason: closedReason), closedReason, fieldWindowTitle,
     detectedAt(pixels: 4), hdrEngagedLine, mirroringReason, fieldNotShown,
     pixelSizeLine(width: 3840, height: 2160),
     occlusionLine(fieldIDs: [CheckupCheckID.field(.black), CheckupCheckID.field(.gray7)]) ?? "",
     CheckupScenario.allCases.map(scenarioWords).joined(separator: " ")]
      + CheckupFieldKind.allCases.map(instruction(for:))
      + CheckupFieldKind.allCases.map(fieldTitle)
      + CheckupFieldKind.allCases.map(shortFieldName)
      + CheckupFieldKind.allCases.map { claimLabel(id: CheckupCheckID.field($0)) }
      + CheckupFamily.allCases.map(familyTitle)
      + [CheckupPanelClass.readsDDC, .writeOnlyDDC, .noDDC]
        .flatMap { [panelClassLine($0, hdrEngaged: false), panelClassLine($0, hdrEngaged: true)] }
      + CheckupScenario.allCases.map(scenarioLabel)
      + [CheckupCheckID.identity, CheckupCheckID.capabilityBrightness,
         CheckupCheckID.capabilityContrast, CheckupCheckID.capabilityVolume,
         CheckupCheckID.nativeMode, CheckupCheckID.refreshSweep, CheckupCheckID.hdrFlags,
         CheckupCheckID.hdrSettle, CheckupCheckID.refresh(hz: 120)].map { claimLabel(id: $0) }
  }
}
