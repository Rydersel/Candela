import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

// Direct assertions over the app target's copy builders, plus the two
// suite-wide scans that make house rules mechanical rather than review habits:
// no em dash anywhere, and no visible "panel". `SynthesisCopy`'s own
// pins, and the scans only that feature needs, live in `SynthesisCopyTests`.
//
// Every builder is read through `String(describing:)`. `Text` reflects to its
// resolved words because an unlocalized bundle falls back to the key, but a
// `LocalizedStringKey` reflects to the KEY plus its arguments as separate
// values: an interpolated sentence comes back as "%@ could not ..." with
// "Candela" alongside rather than spliced in, so assertions on those pin the
// literal half and the argument half separately.
//
// `theScanCanSeeThroughEveryReturnType` is the positive control: if reflection
// stops carrying the words, both scans pass vacuously and that test fails first.
@Suite("Copy builders")
@MainActor
struct CopyBuilderTests {

  // MARK: - Reading a builder's output

  private func render(_ key: LocalizedStringKey) -> String { unescaped(String(describing: key)) }
  private func render(_ text: Text) -> String { unescaped(String(describing: text)) }

  /// Reflection dumps a literal the way source would spell it, so the
  /// apostrophes and quotes inside the copy come back backslash-escaped. Undone
  /// once here so an assertion can be written the way the sentence reads.
  private func unescaped(_ dump: String) -> String {
    dump
      .replacingOccurrences(of: "\\'", with: "'")
      .replacingOccurrences(of: "\\\"", with: "\"")
  }

  private static let emDash = "\u{2014}"

  private static let mag: CGDirectDisplayID = 101
  private static let dell: CGDirectDisplayID = 102
  private static let builtIn: CGDirectDisplayID = 103

  /// The surface's naming closure. Unknown displays answer "", which is the
  /// case every named builder has a fallback sentence for.
  private static func naming(_ names: [CGDirectDisplayID: String]) -> (CGDirectDisplayID) -> String {
    { names[$0] ?? "" }
  }

  private static let bothNamed = naming([mag: "MAG 341C", dell: "DELL U2725QE"])
  private static let noneNamed = naming([:])

  private static func display(
    _ id: CGDirectDisplayID, name: String, mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(vendor: 1, model: UInt32(id), serial: 0, isBuiltIn: false),
      name: name,
      isBuiltIn: false,
      mirrorsDisplay: mirrors,
      isInMirrorSet: inSet)
  }

  private static let mode = DisplayMode(
    ioModeID: 3, logicalWidth: 2560, logicalHeight: 1440,
    pixelWidth: 5120, pixelHeight: 2880, refreshHz: 60, isNative: false)

  private static let descriptor = DisplayModeDescriptor(
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175)

  // MARK: - ArrangementCopy

  @Test func arrangementReportTitleNamesWhatTheCardReports() {
    // Three subjects, three distinct titles: the whole reason the title is
    // derived rather than fixed is that two of them contradict "not changed".
    #expect(render(ArrangementCopy.reportTitle(.nothingChanged)).contains("Arrangement not changed"))
    #expect(render(ArrangementCopy.reportTitle(.restoreFailed)).contains("Saved arrangement not restored"))
    #expect(render(ArrangementCopy.reportTitle(.diverged)).contains("Arrangement changed unexpectedly"))
    #expect(Set(Self.allReportSubjects.map { render(ArrangementCopy.reportTitle($0)) }).count == 3)
  }

  @Test func arrangementCountdownCarriesTheNumberAndPluralizes() {
    #expect(ArrangementCopy.countdown(1) == "Reverting in 1 second")
    #expect(ArrangementCopy.countdown(2) == "Reverting in 2 seconds")
    #expect(ArrangementCopy.countdown(30) == "Reverting in 30 seconds")
    #expect(ArrangementCopy.countdown(0) == "Reverting in 0 seconds")
  }

  @Test func arrangementPreviewSubtitleNamesTheMenuBarDisplayWhenItCan() {
    let one = ArrangementCopy.previewSubtitle(displayCount: 1, mainDisplayName: "MAG 341C")
    #expect(one == "1 display was moved. The menu bar is on MAG 341C.")

    let many = ArrangementCopy.previewSubtitle(displayCount: 3, mainDisplayName: "MAG 341C")
    #expect(many.contains("3 displays are arranged."))

    // The unnamed fallback drops the whole sentence rather than emitting a gap.
    let unnamed = ArrangementCopy.previewSubtitle(displayCount: 2, mainDisplayName: "")
    #expect(unnamed == "2 displays are arranged.")
    #expect(!unnamed.contains("menu bar"))
  }

  @Test func arrangementInvalidLayoutSaysWhatHasToMove() {
    let overlap: [ArrangementProblem] = [.overlap(Self.mag, Self.dell)]
    let named = render(ArrangementCopy.invalidLayout(overlap, name: Self.bothNamed))
    #expect(named.contains("MAG 341C and DELL U2725QE overlap"))
    #expect(named.contains("they cannot cover each other"))

    // One unnamable display drops the whole naming, never half of it.
    let halfNamed = render(
      ArrangementCopy.invalidLayout(overlap, name: Self.naming([Self.mag: "MAG 341C"])))
    #expect(halfNamed.contains("Two displays overlap"))
    #expect(!halfNamed.contains("MAG 341C"))

    let stranded = render(
      ArrangementCopy.invalidLayout([.disconnected(Self.dell)], name: Self.bothNamed))
    #expect(stranded.contains("DELL U2725QE is not touching any other display"))

    let strandedPair = render(
      ArrangementCopy.invalidLayout(
        [.disconnected(Self.dell), .disconnected(Self.mag)], name: Self.bothNamed))
    #expect(strandedPair.contains("One or more displays are not touching the rest"))

    // An overlap outranks a stranding: mixing the two sentences would report a
    // reachability answer that the overlap makes meaningless.
    let mixed = render(
      ArrangementCopy.invalidLayout(
        [.disconnected(Self.mag), .overlap(Self.mag, Self.dell)], name: Self.bothNamed))
    #expect(mixed.contains("overlap"))
    #expect(!mixed.contains("not touching"))
  }

  @Test func arrangementFailureSentencesNameTheProductAndTheState() {
    #expect(render(ArrangementCopy.applyFailure).contains("could not rearrange the displays"))
    #expect(render(ArrangementCopy.applyFailure).contains(AppInfo.productName))
    #expect(render(ArrangementCopy.resolveFailure).contains("still showing the preview"))
    #expect(render(ArrangementCopy.expiryAlreadyRan).contains("countdown has already run"))
    #expect(render(ArrangementCopy.divergedOffer).contains("did not end up where they were asked to go"))
    #expect(render(ArrangementCopy.question).contains("Keep this arrangement?"))
    #expect(render(ArrangementCopy.keep).contains("Keep"))
    #expect(render(ArrangementCopy.revert).contains("Revert Now"))
    #expect(render(ArrangementCopy.restore).contains("Put Them Back"))
  }

  @Test func arrangementRestoreNoticeGivesEveryRefusalItsOwnReason() {
    let ambiguous = render(
      ArrangementCopy.restoreNotice(.ambiguousIdentity(["a", "b"]), name: Self.bothNamed))
    #expect(ambiguous.contains("report the same identity"))
    // The ambiguous-identity restore refuses BECAUSE two displays are
    // indistinguishable, so naming one would be the guess the refusal exists
    // to avoid.
    #expect(!ambiguous.contains("MAG 341C"))

    #expect(
      render(ArrangementCopy.restoreNotice(.setDiffers(missing: ["a"], extra: []), name: Self.bothNamed))
        .contains("different set of displays"))
    #expect(
      render(ArrangementCopy.restoreNotice(.failed(DisplayConfigError(cgErrorCode: 1001)), name: Self.bothNamed))
        .contains("could not restore the saved arrangement"))

    // The invalid-layout arm reuses the interactive sentence, deliberately.
    let refit = render(
      ArrangementCopy.restoreNotice(
        .layoutNoLongerFits([.overlap(Self.mag, Self.dell)]), name: Self.bothNamed))
    #expect(refit == render(ArrangementCopy.invalidLayout([.overlap(Self.mag, Self.dell)], name: Self.bothNamed)))

    // A layout declined because a display resized must NOT borrow the overlap
    // sentence: nothing on the machine overlaps, and that sentence was written
    // for someone who had just dragged one display onto another.
    let resized = render(
      ArrangementCopy.restoreNotice(.savedForDifferentGeometry(["a"]), name: Self.bothNamed))
    #expect(resized.contains("not the size they were"))
    #expect(!resized.contains("overlap"))
    #expect(!resized.contains("cover each other"))
    // It names the way out, because nothing else ends this state: the saved
    // layout is deliberately never rewritten.
    #expect(resized.contains("Arrange them again"))
    // Says nothing about a particular screen; the fact is about the layout.
    #expect(!resized.contains("MAG 341C"))
    #expect(!resized.contains("DELL"))

    #expect(Set(Self.allReapplyNotices.map { render(ArrangementCopy.restoreNotice($0, name: Self.bothNamed)) }).count == 5)
  }

  @Test func arrangementApplyNoticeNamesTheDisplayWhenItCan() {
    #expect(
      render(ArrangementCopy.notice(.adjusted(DisplayArrangement(tiles: [])), name: Self.bothNamed))
        .contains("macOS moved some of the displays"))
    #expect(
      render(ArrangementCopy.notice(.mainDisplayUnchanged(Self.dell), name: Self.bothNamed))
        .contains("The menu bar did not move to DELL U2725QE."))
    #expect(
      render(ArrangementCopy.notice(.mainDisplayUnchanged(Self.dell), name: Self.noneNamed))
        .contains("did not move to the display that was asked for"))
  }

  // MARK: - DiagnosticsPageCopy

  @Test func diagnosticsIdentityKeysSurvivesTwoIdenticalKeys() {
    #expect(render(DiagnosticsPageCopy.identityKeys(keysMatch: true)).contains("They are the same here"))
    #expect(!render(DiagnosticsPageCopy.identityKeys(keysMatch: false)).contains("They are the same here"))
  }

  @Test func diagnosticsBrightnessPathCoversEveryPathAndCarriesItsPercentages() {
    #expect(render(DiagnosticsPageCopy.brightnessPath(.native)).contains("macOS sets this display's brightness directly"))
    #expect(render(DiagnosticsPageCopy.brightnessPath(.hardware)).contains("sent to the display over its data cable"))
    #expect(render(DiagnosticsPageCopy.brightnessPath(.software(.gamma))).contains("darkens what is drawn on it"))

    // The switching point reaches the key as a `%@` argument, so the sentence
    // and the percentage are pinned separately: a key is not resolved copy.
    let combined = render(
      DiagnosticsPageCopy.brightnessPath(.combined(switchingValue: 0.4, backend: .gamma)))
    #expect(combined.contains("this display dims in software"))
    #expect(combined.contains("40%"))
    #expect(!combined.contains("50%"))

    let partial = render(
      DiagnosticsPageCopy.brightnessPath(
        .softwareOnly(backend: .overlay, reason: .ddcTurnedOff, dimsBelow: 0.25)))
    #expect(partial.contains("only the part of the slider below"))
    #expect(partial.contains("25%"))
    #expect(partial.contains("turned off for this display"))

    #expect(
      render(DiagnosticsPageCopy.brightnessPath(.unavailable(.ddcTurnedOffWithNoSoftwareLeg)))
        .contains("nothing is left to carry the value"))

    // The wire's two arms name the display's own silence, never a setting:
    // otherwise someone goes looking for a switch they never touched.
    let deadWire = render(
      DiagnosticsPageCopy.brightnessPath(
        .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.25)))
    #expect(deadWire.contains("stopped answering brightness commands"))
    #expect(deadWire.contains("25%"))
    #expect(!deadWire.contains("turned off"))
    #expect(
      render(DiagnosticsPageCopy.brightnessPath(.unavailable(.ddcUnresponsiveWithNoSoftwareLeg)))
        .contains("stopped answering brightness commands"))

    // One representative per switch arm, each with its own sentence. Both software
    // backends are deliberately not in this list: they share one sentence,
    // because the user is told the backlight is untouched, not which trick does
    // the darkening.
    let perArm: [BrightnessPath] = [
      .native, .hardware, .software(.gamma),
      .combined(switchingValue: 0.4, backend: .gamma),
      .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.25),
      .unavailable(.ddcTurnedOffWithNoSoftwareLeg),
      .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.25),
      .unavailable(.ddcUnresponsiveWithNoSoftwareLeg),
    ]
    #expect(Set(perArm.map { render(DiagnosticsPageCopy.brightnessPath($0)) }).count == 8)
    #expect(
      render(DiagnosticsPageCopy.brightnessPath(.software(.gamma)))
        == render(DiagnosticsPageCopy.brightnessPath(.software(.overlay))))
  }

  @Test func diagnosticsCapabilityAnswerTellsFourStatesApart() {
    let unbalanced = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: true, parsedACommandList: false, wasAsked: true, isHDREngaged: false))
    #expect(unbalanced.contains("It is unbalanced"))

    let parsed = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: true, parsedACommandList: true, wasAsked: true, isHDREngaged: false))
    #expect(parsed.contains("asks each display to describe itself once"))
    #expect(!parsed.contains("has not asked this one yet"))

    let silent = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: true, isHDREngaged: false))
    #expect(silent.contains("asked once since this display was plugged in"))

    // The HDR arm is the one skip that is not "hasn't got round to it yet".
    let hdr = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: false, isHDREngaged: true))
    #expect(hdr.contains("does not ask a display that is in HDR mode"))

    let notYet = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: false, isHDREngaged: false))
    #expect(notYet.contains("has not asked this one yet"))

    // wasAsked wins over the HDR arm: a display already asked is not pending.
    let askedThenHDR = render(
      DiagnosticsPageCopy.capabilityAnswer(
        hasDescription: false, parsedACommandList: false, wasAsked: true, isHDREngaged: true))
    #expect(askedThenHDR == silent)
  }

  @Test func diagnosticsReadEvidenceSaysWhereTheValuesCameFrom() {
    #expect(
      render(DiagnosticsPageCopy.readEvidence(.answered, isSafeMode: false, readsBackAtStartup: true))
        .contains("come from the display itself"))
    // The two silent panels are indistinguishable from the user's seat, and the
    // sentence says so by being the same one.
    let zeros = render(DiagnosticsPageCopy.readEvidence(.allZeros, isSafeMode: false, readsBackAtStartup: true))
    let noReply = render(DiagnosticsPageCopy.readEvidence(.noReply, isSafeMode: false, readsBackAtStartup: true))
    #expect(zeros == noReply)
    #expect(zeros.contains("what \(AppInfo.productName) last wrote") || zeros.contains("last wrote"))

    #expect(
      render(DiagnosticsPageCopy.readEvidence(.notAttempted, isSafeMode: true, readsBackAtStartup: true))
        == render(DiagnosticsPageCopy.notAttempted(isSafeMode: true, readsBackAtStartup: true)))
  }

  @Test func diagnosticsNotAttemptedNamesOnlyTheTwoKnowableCauses() {
    // Safe Mode is read FIRST: under it the startupAction getter reports
    // .doNothing regardless of what is stored, so the other order would report
    // the pref rather than the session.
    let safe = render(DiagnosticsPageCopy.notAttempted(isSafeMode: true, readsBackAtStartup: false))
    #expect(safe.contains("Safe Mode is on for this session"))

    let notSet = render(DiagnosticsPageCopy.notAttempted(isSafeMode: false, readsBackAtStartup: false))
    #expect(notSet.contains("is not set to read values back from displays at startup"))

    let nothingYet = render(DiagnosticsPageCopy.notAttempted(isSafeMode: false, readsBackAtStartup: true))
    #expect(nothingYet.contains("Nothing has been read from this display yet"))
  }

  @Test func diagnosticsWriteGateLabelNamesNoWireTheBuiltInLacks() {
    #expect(render(DiagnosticsPageCopy.writeGateLabel(isBuiltIn: true)).contains("Brightness commands"))
    #expect(render(DiagnosticsPageCopy.writeGateLabel(isBuiltIn: false)).contains("Hardware commands"))
  }

  @Test func diagnosticsFixedCaptionsCarryTheirSubject() {
    #expect(render(DiagnosticsPageCopy.connection).contains("Which cable"))
    #expect(render(DiagnosticsPageCopy.noSerialNumber).contains("reports no serial number"))
    #expect(render(DiagnosticsPageCopy.nativeBrightness).contains("only path that works while a display is in HDR mode"))
    #expect(render(DiagnosticsPageCopy.builtInHardwareControl).contains("drives the built-in display's backlight itself"))
    #expect(render(DiagnosticsPageCopy.gammaConflicts).contains("the count starts again"))
    #expect(render(DiagnosticsPageCopy.gammaWatchSuspended).contains("until it is relaunched"))
    #expect(render(DiagnosticsPageCopy.capabilityRequestHelp).contains("0xF3"))
    #expect(render(DiagnosticsPageCopy.advertisedCommands).contains("brightness, contrast, volume and mute"))
    #expect(render(DiagnosticsPageCopy.rawDescriptionDisclosure).contains("What the display sent"))
    #expect(render(DiagnosticsPageCopy.volumeHelp) .contains("0x62"))
    #expect(render(DiagnosticsPageCopy.contrastHelp).contains("0x12"))
    #expect(render(DiagnosticsPageCopy.muteHelp).contains("0x8D"))
    #expect(render(DiagnosticsPageCopy.hdrTurnedOnOutside).contains("HDR was turned on outside"))
    #expect(render(DiagnosticsPageCopy.watchedKeys).contains("go straight to macOS"))
    #expect(render(DiagnosticsPageCopy.accessibilityMissing).contains("does not have Accessibility permission"))
    #expect(render(DiagnosticsPageCopy.reportScope).contains("doesn't include serial numbers"))
    #expect(DiagnosticsPageCopy.controlMethodTitle == "Hardware control not responding?")
    #expect(DiagnosticsPageCopy.controlMethodValue == "Control Method")
    #expect(render(DiagnosticsPageCopy.copyReport).contains("Copy Report"))
    #expect(render(DiagnosticsPageCopy.saveReport).contains("Save Report"))
    #expect(render(DiagnosticsPageCopy.copied).contains("Copied"))
    #expect(render(DiagnosticsPageCopy.copiedAccessibly).contains("Report copied to the clipboard"))
    #expect(render(DiagnosticsPageCopy.saveFailed).contains("could not be saved"))
    #expect(render(DiagnosticsPageCopy.acknowledge).contains("OK"))
    #expect(DiagnosticsPageCopy.reportFileName == "\(AppInfo.productName) Diagnostics.txt")
    #expect(DiagnosticsPageCopy.safeMode == SafeModeCopy.diagnosticsRow(app: AppInfo.productName))
  }

  @Test func diagnosticsKeyWatchRequirementsSpeakEveryRowItShows() {
    let rows = DiagnosticsPageCopy.keyWatchRequirements
    #expect(rows.count == 3)
    #expect(rows.map(\.title) == ["Brightness keys", "Volume keys", "Mute key"])
    // The visible half states what holds in every mode, the spoken half
    // carries the corners, so neither may be empty and they must differ.
    for row in rows {
      #expect(!row.needs.isEmpty)
      #expect(row.spoken.count > row.needs.count)
    }
  }

  // MARK: - DisplayModeCopy

  @Test func displayModeSizeHasOneSpellingAcrossAllThreeEntryPoints() {
    #expect(DisplayModeCopy.size(width: 2560, height: 1440) == "2560 × 1440")
    #expect(DisplayModeCopy.size(Self.mode) == "2560 × 1440")
    #expect(DisplayModeCopy.size(Self.descriptor) == "3440 × 1440")
    // The stored descriptor and the live mode name the same size the same way.
    #expect(DisplayModeCopy.size(Self.mode) == DisplayModeCopy.size(Self.mode.descriptor))
  }

  @Test func displayModeRefreshKeepsTheDecimalWhenThereIsOne() {
    #expect(DisplayModeCopy.refresh(60) == "60 Hz")
    #expect(DisplayModeCopy.refresh(175) == "175 Hz")
    #expect(DisplayModeCopy.refresh(59.9) == "59.9 Hz")
    #expect(DisplayModeCopy.refresh(23.976) == "24.0 Hz")
  }

  @Test func displayModeCountdownsCarryTheNumberAndPluralize() {
    #expect(DisplayModeCopy.countdown(1) == "Reverting to the previous resolution in 1 second.")
    #expect(DisplayModeCopy.countdown(15) == "Reverting to the previous resolution in 15 seconds.")
    #expect(DisplayModeCopy.passiveCountdown(1) == "Reverting in 1 second. Answer in the confirmation window.")
    #expect(DisplayModeCopy.passiveCountdown(9).contains("9 seconds"))
    // The passive line always points at where the buttons are.
    #expect(DisplayModeCopy.passiveCountdown(9).contains("Answer in the confirmation window"))
  }

  @Test func displayModePreviewAnnouncementSpeaksTheModeAndTheDeadline() {
    let spoken = DisplayModeCopy.previewAnnouncement(mode: Self.mode, seconds: 15)
    #expect(spoken.contains("2,560 by 1,440 at 60 hertz"))
    #expect(spoken.contains("Keep this resolution?"))
    #expect(spoken.contains(DisplayModeCopy.countdown(15)))
    // No glyphs in a spoken string: the times sign is read inconsistently.
    #expect(!spoken.contains("×"))
  }

  @Test func displayModeMarksMakeNoQualityClaim() {
    #expect(DisplayModeCopy.addedByApp == "Added by \(AppInfo.productName)")
    #expect(DisplayModeCopy.recommended == "Recommended")
    #expect(DisplayModeCopy.recommendationApply == "Use This Size")
    #expect(DisplayModeCopy.recommendationDismiss == "Dismiss")
  }

  @Test func displayModeRecommendationCalloutPicksItsSecondSentenceFromTheFlag() {
    let native = DisplayModeCopy.recommendationCallout(width: 3440, height: 1440, isNative: true)
    #expect(native.contains("3440 × 1440 is the comfortable fit"))
    #expect(native.contains("It is this display's native resolution."))

    let scaled = DisplayModeCopy.recommendationCallout(width: 2560, height: 1440, isNative: false)
    #expect(scaled.contains("2560 × 1440 is the comfortable fit"))
    #expect(scaled.contains("It renders larger and scales the result."))
    #expect(!scaled.contains("native"))
  }

  @Test func displayModeStartFailureStatesEitherReason() {
    #expect(render(DisplayModeCopy.startFailure).contains("could not switch this display"))
    #expect(
      render(DisplayModeCopy.startFailure(.failed(DisplayConfigError(cgErrorCode: 1001))))
        == render(DisplayModeCopy.startFailure))
    // The gate's refusal is not a failure, so it borrows the shared sentence.
    #expect(
      render(DisplayModeCopy.startFailure(.blocked(by: .mirroring)))
        == render(ReconfigurationCopy.blocked(by: .mirroring)))

    #expect(
      DisplayModeCopy.startFailureDiagnostic(.failed(DisplayConfigError(cgErrorCode: 1001)))
        == "CoreGraphics error 1001")
    #expect(DisplayModeCopy.startFailureDiagnostic(.blocked(by: .rotation)) == "Held by rotation")
  }

  @Test func displayModeResolveFailuresInviteAnotherAttempt() {
    #expect(render(DisplayModeCopy.resolveFailure).contains("still showing the preview"))
    #expect(render(DisplayModeCopy.resolveFailure).contains("Try again"))
    #expect(render(DisplayModeCopy.expiryAlreadyRan).contains("already run"))
  }

  @Test func displayModeReapplyNamesTheRequestedResolutionFirst() {
    let applied = DisplayMode(
      ioModeID: 9, logicalWidth: 2560, logicalHeight: 1080,
      pixelWidth: 2560, pixelHeight: 1080, refreshHz: 60, isNative: false)

    let substituted = render(
      DisplayModeCopy.reapplySubstituted(requested: Self.descriptor, applied: applied))
    #expect(substituted.contains("3440 × 1440"))
    #expect(substituted.contains("175 Hz"))
    #expect(substituted.contains("2560 × 1080"))
    // The requested size leads: it is the one the user recognises.
    let requestedAt = substituted.range(of: "3440 × 1440")
    let appliedAt = substituted.range(of: "2560 × 1080")
    #expect(requestedAt != nil && appliedAt != nil)
    if let requestedAt, let appliedAt { #expect(requestedAt.lowerBound < appliedAt.lowerBound) }

    let unavailable = render(DisplayModeCopy.reapplyUnavailable(requested: Self.descriptor))
    #expect(unavailable.contains("left this display as it found it"))

    let failed = render(DisplayModeCopy.reapplyFailed(requested: Self.descriptor))
    #expect(failed.contains("Nothing was changed"))

    // One sentence per notice, and each routes to its own builder.
    #expect(
      render(DisplayModeCopy.reapply(requested: Self.descriptor, notice: .substituted(applied)))
        == substituted)
    #expect(
      render(DisplayModeCopy.reapply(requested: Self.descriptor, notice: .unavailable)) == unavailable)
    #expect(
      render(DisplayModeCopy.reapply(
        requested: Self.descriptor, notice: .failed(DisplayConfigError(cgErrorCode: 1001))))
        == failed)
  }

  // MARK: - MirroringCopy

  @Test func mirroringRefusalGivesEachOfTheEightCasesItsOwnSentence() {
    let rendered = Self.allMirrorRefusals.map { render(MirroringCopy.refusal($0, name: Self.bothNamed)) }
    #expect(rendered.count == 8)
    #expect(Set(rendered).count == 8)

    #expect(render(MirroringCopy.refusal(.onlyOneDisplay, name: Self.bothNamed)).contains("needs a second display"))
    #expect(render(MirroringCopy.refusal(.noEligibleMaster, name: Self.bothNamed)).contains("No display here can show the picture"))
    #expect(render(MirroringCopy.refusal(.noSuchDisplay, name: Self.bothNamed)).contains("no longer connected"))
    #expect(render(MirroringCopy.refusal(.masterIsAlwaysMirrored, name: Self.bothNamed)).contains("cannot show the picture for the others"))
    #expect(render(MirroringCopy.refusal(.nothingToMirror, name: Self.bothNamed)).contains("No other display can be mirrored onto this one"))
    #expect(render(MirroringCopy.refusal(.alreadyMirrored, name: Self.bothNamed)).contains("already is"))
    #expect(render(MirroringCopy.refusal(.notInASet, name: Self.bothNamed)).contains("is not mirroring anything"))

    // The one refusal with a payload names it.
    #expect(
      render(MirroringCopy.refusal(.setCannotBeBroken([Self.mag]), name: Self.bothNamed))
        .contains("MAG 341C"))
  }

  @Test func mirroringSetCannotBeBrokenNamesMembersOnlyWhenItCanNameThemAll() {
    #expect(
      MirroringCopy.setCannotBeBroken(members: [Self.mag], name: Self.bothNamed)
        == "macOS will not let mirroring be turned off for MAG 341C.")
    #expect(
      MirroringCopy.setCannotBeBroken(members: [Self.mag, Self.dell], name: Self.bothNamed)
        == "macOS will not let mirroring be turned off for these displays: MAG 341C, DELL U2725QE.")
    // Half a list reads as a bug rather than as a report, so it falls to a count.
    #expect(
      MirroringCopy.setCannotBeBroken(
        members: [Self.mag, Self.builtIn], name: Self.naming([Self.mag: "MAG 341C"]))
        == "macOS will not let mirroring be turned off for those 2 displays.")
    #expect(
      MirroringCopy.setCannotBeBroken(members: [Self.builtIn], name: Self.noneNamed)
        == "macOS will not let mirroring be turned off for that display.")
  }

  @Test func mirroringPartialBreakReportsWhatSurvived() {
    #expect(
      MirroringCopy.partialBreak(residual: [Self.mag, Self.dell], name: Self.bothNamed)
        == "Still mirrored, because macOS will not let them be separated: MAG 341C, DELL U2725QE.")
    #expect(
      MirroringCopy.partialBreak(residual: [Self.builtIn], name: Self.noneNamed)
        == "One display is still mirrored, because macOS will not let it be separated.")
    #expect(
      MirroringCopy.partialBreak(residual: [Self.builtIn, Self.mag], name: Self.noneNamed)
        .contains("2 displays are still mirrored"))
  }

  @Test func mirroringStateSpellsOutTheTopologyInWords() {
    let set = MirrorTopology([
      Self.display(Self.dell, name: "DELL U2725QE", inSet: true),
      Self.display(Self.mag, name: "MAG 341C", mirrors: Self.dell),
    ])
    #expect(MirroringCopy.state(topology: set, displayID: Self.mag, name: Self.bothNamed) == "Showing DELL U2725QE")
    #expect(MirroringCopy.state(topology: set, displayID: Self.dell, name: Self.bothNamed) == "Mirrored to 1 display")

    let bigger = MirrorTopology([
      Self.display(Self.dell, name: "DELL U2725QE", inSet: true),
      Self.display(Self.mag, name: "MAG 341C", mirrors: Self.dell),
      Self.display(Self.builtIn, name: "Built-in", mirrors: Self.dell),
    ])
    #expect(MirroringCopy.state(topology: bigger, displayID: Self.dell, name: Self.bothNamed) == "Mirrored to 2 displays")

    let alone = MirrorTopology([Self.display(Self.mag, name: "MAG 341C")])
    #expect(MirroringCopy.state(topology: alone, displayID: Self.mag, name: Self.bothNamed) == MirroringCopy.notMirroredText)
  }

  @Test func mirroringCountdownAndFixedSentences() {
    #expect(MirroringCopy.countdown(1) == "Reverting in 1 second")
    #expect(MirroringCopy.countdown(30) == "Reverting in 30 seconds")

    #expect(MirroringCopy.notMirroredText == "Not mirrored")
    #expect(render(MirroringCopy.notMirrored).contains(MirroringCopy.notMirroredText))
    #expect(render(MirroringCopy.sectionTitle).contains("Mirroring"))
    #expect(render(MirroringCopy.statusLabel).contains("Mirroring"))
    #expect(render(MirroringCopy.question).contains("Keep mirroring?"))
    #expect(render(MirroringCopy.keep).contains("Keep"))
    #expect(render(MirroringCopy.stopNow).contains("Stop Mirroring Now"))
    #expect(render(MirroringCopy.startMirroring).contains("Start Mirroring"))
    #expect(render(MirroringCopy.stopMirroring).contains("Stop Mirroring"))
    #expect(render(MirroringCopy.reportTitle).contains("Mirroring not changed"))
    #expect(render(MirroringCopy.pickMaster).contains("Show the picture from"))
    #expect(render(MirroringCopy.cannotBeUnmirrored).contains("will not let it be separated"))
    #expect(render(MirroringCopy.applyInProgress).contains("Waiting for the last mirroring change"))
    #expect(render(MirroringCopy.applyFailure).contains("nothing was altered"))
    #expect(render(MirroringCopy.resolveFailure).contains("Try again"))
  }

  @Test func mirroringExplanationsPromiseLessWhenSomethingIsLocked() {
    // The locked variants must not promise "every other display": the apply
    // stages no change for a display macOS keeps mirrored elsewhere.
    #expect(render(MirroringCopy.startExplanation).contains("every other display"))
    #expect(!render(MirroringCopy.startExplanationSomeLocked).contains("every other display"))
    #expect(render(MirroringCopy.startExplanationSomeLocked).contains("apart from"))

    #expect(render(MirroringCopy.stopExplanation).contains("every display in the set"))
    #expect(!render(MirroringCopy.stopExplanationSomeLocked).contains("every display"))
    #expect(render(MirroringCopy.stopExplanationSomeLocked).contains("stay mirrored"))

    // Both Start variants still name the thirty seconds the user gets.
    #expect(render(MirroringCopy.startExplanation).contains("thirty seconds"))
    #expect(render(MirroringCopy.startExplanationSomeLocked).contains("thirty seconds"))
  }

  // MARK: - ReconfigurationCopy

  @Test func reconfigurationBlockedNamesEveryClaimant() {
    let rendered = ReconfigurationClaimant.allCases.map { render(ReconfigurationCopy.blocked(by: $0)) }
    #expect(rendered.count == ReconfigurationClaimant.allCases.count)
    #expect(Set(rendered).count == rendered.count)
    for sentence in rendered {
      // The reconfiguration gate: name the holder and hand the user their
      // next move.
      #expect(sentence.contains("Finish that first."))
      #expect(sentence.contains(AppInfo.productName))
    }
    #expect(render(ReconfigurationCopy.blocked(by: .displayModes)).contains("changing a display's resolution"))
    #expect(render(ReconfigurationCopy.blocked(by: .mirroring)).contains("changing mirroring"))
    #expect(render(ReconfigurationCopy.blocked(by: .rotation)).contains("rotating a display"))
    #expect(render(ReconfigurationCopy.blocked(by: .arrangement)).contains("changing the display arrangement"))
  }

  // MARK: - RotationCopy

  @Test func rotationAngleUsesTheSystemsOwnFourWords() {
    let spelled = DisplayRotation.allCases.map { render(RotationCopy.angle($0)) }
    #expect(Set(spelled).count == DisplayRotation.allCases.count)
    #expect(render(RotationCopy.angle(.standard)).contains("Standard"))
    #expect(render(RotationCopy.angle(.ninety)).contains("90°"))
    #expect(render(RotationCopy.angle(.oneEighty)).contains("180°"))
    #expect(render(RotationCopy.angle(.twoSeventy)).contains("270°"))
  }

  @Test func rotationPreviewSubtitleFallsBackToTheAngleAlone() {
    #expect(RotationCopy.previewSubtitle(name: "DELL U2725QE", to: .twoSeventy) == "DELL U2725QE: 270°")
    #expect(RotationCopy.previewSubtitle(name: "", to: .ninety) == "90°")
  }

  @Test func rotationRefusalStatesItsOwnReasonForEveryCase() {
    let rendered = Self.allRotationRefusals.map { render(RotationCopy.refusal($0)) }
    #expect(rendered.count == 4)
    #expect(Set(rendered).count == 4)
    #expect(render(RotationCopy.refusal(.unavailable)) == render(RotationCopy.unavailable))
    #expect(render(RotationCopy.refusal(.displayGone)).contains("disconnected before the change could be made"))
    #expect(render(RotationCopy.refusal(.unreadable)).contains("does not recognize"))
    #expect(render(RotationCopy.refusal(.unchanged(.ninety))).contains("already in this orientation"))
  }

  @Test func rotationCountdownAndFixedSentences() {
    #expect(RotationCopy.countdown(1) == "Reverting in 1 second")
    #expect(RotationCopy.countdown(30) == "Reverting in 30 seconds")
    #expect(render(RotationCopy.label).contains("Rotation"))
    #expect(render(RotationCopy.question).contains("Keep this orientation?"))
    #expect(render(RotationCopy.keep).contains("Keep"))
    #expect(render(RotationCopy.revert).contains("Revert Now"))
    #expect(render(RotationCopy.reportTitle).contains("Display not rotated"))
    #expect(render(RotationCopy.unavailable).contains("does not expose display rotation"))
    #expect(render(RotationCopy.applyFailure).contains("did not rotate"))
    #expect(render(RotationCopy.resolveFailure).contains("Nothing retries this on its own"))
  }

  // MARK: - OledCareCopy

  /// The whole point of the parameter is that the sentences differ: a person
  /// who never mirrored anything must not be told they did. The scans below
  /// reach every arm but would pass with all of them saying the mirrored words.
  @Test func theSuspendedCopySaysWhichPauseItIsAbout() {
    // No terminal period on any arm (ruled 2026-08-18): a status row reads
    // like its neighbours, and every one of those is period-free.
    #expect(render(OledCareCopy.suspendedStatus(reason: .synthesizedSize))
      .contains("\"Paused while a synthesized size is active\""))
    #expect(OledCareCopy.suspendedPreview(reason: .synthesizedSize)
      == "Paused for a synthesized size")
    #expect(OledCareCopy.suspendedSpokenPreview(reason: .synthesizedSize)
      == "Paused while a synthesized size is active")

    #expect(render(OledCareCopy.suspendedStatus(reason: .mirrored))
      .contains("\"Paused while this display is mirrored\""))
    #expect(OledCareCopy.suspendedPreview(reason: .mirrored) == "Paused while mirrored")
    #expect(OledCareCopy.suspendedSpokenPreview(reason: .mirrored)
      == "Paused while this display is mirrored")

    #expect(render(OledCareCopy.suspendedStatus(reason: .checkup))
      .contains("\"Paused while a checkup field is showing\""))
    #expect(OledCareCopy.suspendedPreview(reason: .checkup) == "Paused for a checkup")
    #expect(OledCareCopy.suspendedSpokenPreview(reason: .checkup)
      == "Paused while a checkup field is showing")
  }

  /// A switch arm that fell through to its neighbour cannot pass. `allCases` is
  /// what makes a new reason arrive as a failure rather than a duplicated
  /// sentence.
  @Test func noTwoSuspensionReasonsShareTheirWords() {
    let statuses = OledCareSuspensionReason.allCases.map {
      render(OledCareCopy.suspendedStatus(reason: $0))
    }
    let previews = OledCareSuspensionReason.allCases.map { OledCareCopy.suspendedPreview(reason: $0) }
    let spoken = OledCareSuspensionReason.allCases.map {
      OledCareCopy.suspendedSpokenPreview(reason: $0)
    }
    #expect(Set(statuses).count == OledCareSuspensionReason.allCases.count)
    #expect(Set(previews).count == OledCareSuspensionReason.allCases.count)
    #expect(Set(spoken).count == OledCareSuspensionReason.allCases.count)
  }

  /// The wear fraction's denominator is MASK-COULD-APPLY time (ruled
  /// 2026-08-18) and the histogram beside it covers every state. Pinned
  /// because a caption that lost either scope leaves the two numbers looking
  /// like a share of each other.
  @Test func theWearFractionCaptionNamesBothScopes() {
    #expect(OledCareCopy.wearFractionScope == """
      The bars cover every state this display was tracked in. \
      The percentage covers only the time a protective dim could apply.
      """)
  }

  // MARK: - The suite-wide em-dash scan

  @Test func noBuilderEmitsAnEmDash() {
    for entry in everyBuilderString() {
      #expect(!entry.text.contains(Self.emDash), "\(entry.site) emits an em dash: \(entry.text)")
    }
  }

  /// The panel-retirement rule applies over every builder rather than over one
  /// feature's. Hardware is always
  /// a "display" in visible copy; the type and comment vocabulary keeps the
  /// word, and none of that is read here.
  @Test func noBuilderSaysPanel() {
    for entry in everyBuilderString() {
      #expect(!entry.text.lowercased().contains("panel"), "\(entry.site) says panel: \(entry.text)")
    }
  }

  @Test func theScanCanSeeThroughEveryReturnType() {
    // Positive control: the scan reads three return types through reflection,
    // and one that stopped carrying words would pass over an em dash it never
    // saw. Each shape is proven readable and a planted em dash detectable.
    #expect(render(RotationCopy.question).contains("Keep this orientation?"))
    #expect(render(MirroringCopy.refusal(.notInASet, name: Self.noneNamed)).contains("not mirroring anything"))
    #expect(MirroringCopy.countdown(2).contains("2 seconds"))

    #expect(render(LocalizedStringKey("planted \(Self.emDash) key")).contains(Self.emDash))
    #expect(render(Text(verbatim: "planted \(Self.emDash) verbatim")).contains(Self.emDash))
    #expect(render(Text(LocalizedStringKey("planted \(Self.emDash) localized"))).contains(Self.emDash))
    #expect(render(LocalizedStringKey("planted panel key")).lowercased().contains("panel"))

    // A collapse detector, not a limit that only tightens: a scan down to a
    // handful of strings would still pass. The floor sits far below the real
    // count.
    #expect(everyBuilderString().count > 100)
  }

  /// Every string the builders can emit under fixture inputs, each tagged with
  /// the call that produced it so a violation names its site.
  private func everyBuilderString() -> [(site: String, text: String)] {
    var out: [(site: String, text: String)] = []
    func add(_ site: String, _ text: String) { out.append((site, text)) }
    func add(_ site: String, _ key: LocalizedStringKey) { out.append((site, render(key))) }
    func add(_ site: String, _ text: Text) { out.append((site, render(text))) }

    let names = [Self.bothNamed, Self.noneNamed]
    let counts = [0, 1, 2, 30]

    // ArrangementCopy
    add("ArrangementCopy.question", ArrangementCopy.question)
    add("ArrangementCopy.keep", ArrangementCopy.keep)
    add("ArrangementCopy.revert", ArrangementCopy.revert)
    add("ArrangementCopy.restore", ArrangementCopy.restore)
    add("ArrangementCopy.applyFailure", ArrangementCopy.applyFailure)
    add("ArrangementCopy.resolveFailure", ArrangementCopy.resolveFailure)
    add("ArrangementCopy.expiryAlreadyRan", ArrangementCopy.expiryAlreadyRan)
    add("ArrangementCopy.divergedOffer", ArrangementCopy.divergedOffer)
    for subject in Self.allReportSubjects {
      add("ArrangementCopy.reportTitle(\(subject))", ArrangementCopy.reportTitle(subject))
    }
    for seconds in counts { add("ArrangementCopy.countdown(\(seconds))", ArrangementCopy.countdown(seconds)) }
    for count in [1, 2, 3] {
      for name in ["MAG 341C", ""] {
        add(
          "ArrangementCopy.previewSubtitle(\(count), \"\(name)\")",
          ArrangementCopy.previewSubtitle(displayCount: count, mainDisplayName: name))
      }
    }
    for name in names {
      for problems in Self.allProblemShapes {
        add("ArrangementCopy.invalidLayout", ArrangementCopy.invalidLayout(problems, name: name))
      }
      for notice in Self.allReapplyNotices {
        add("ArrangementCopy.restoreNotice(\(notice))", ArrangementCopy.restoreNotice(notice, name: name))
      }
      for notice in Self.allApplyNotices {
        add("ArrangementCopy.notice(\(notice))", ArrangementCopy.notice(notice, name: name))
      }
    }

    // DiagnosticsPageCopy
    add("DiagnosticsPageCopy.connection", DiagnosticsPageCopy.connection)
    add("DiagnosticsPageCopy.noSerialNumber", DiagnosticsPageCopy.noSerialNumber)
    add("DiagnosticsPageCopy.identityKeys(true)", DiagnosticsPageCopy.identityKeys(keysMatch: true))
    add("DiagnosticsPageCopy.identityKeys(false)", DiagnosticsPageCopy.identityKeys(keysMatch: false))
    for path in Self.allBrightnessPaths {
      add("DiagnosticsPageCopy.brightnessPath(\(path))", DiagnosticsPageCopy.brightnessPath(path))
    }
    add("DiagnosticsPageCopy.nativeBrightness", DiagnosticsPageCopy.nativeBrightness)
    add("DiagnosticsPageCopy.builtInHardwareControl", DiagnosticsPageCopy.builtInHardwareControl)
    add("DiagnosticsPageCopy.gammaConflicts", DiagnosticsPageCopy.gammaConflicts)
    add("DiagnosticsPageCopy.gammaWatchSuspended", DiagnosticsPageCopy.gammaWatchSuspended)
    for hasDescription in [true, false] {
      for parsed in [true, false] {
        for asked in [true, false] {
          for hdr in [true, false] {
            add(
              "DiagnosticsPageCopy.capabilityAnswer(\(hasDescription), \(parsed), \(asked), \(hdr))",
              DiagnosticsPageCopy.capabilityAnswer(
                hasDescription: hasDescription, parsedACommandList: parsed,
                wasAsked: asked, isHDREngaged: hdr))
          }
        }
      }
    }
    add("DiagnosticsPageCopy.capabilityRequestHelp", DiagnosticsPageCopy.capabilityRequestHelp)
    add("DiagnosticsPageCopy.advertisedCommands", DiagnosticsPageCopy.advertisedCommands)
    add("DiagnosticsPageCopy.rawDescriptionDisclosure", DiagnosticsPageCopy.rawDescriptionDisclosure)
    for evidence in Self.allReadEvidence {
      for safe in [true, false] {
        for readsBack in [true, false] {
          add(
            "DiagnosticsPageCopy.readEvidence(\(evidence), \(safe), \(readsBack))",
            DiagnosticsPageCopy.readEvidence(evidence, isSafeMode: safe, readsBackAtStartup: readsBack))
        }
      }
    }
    for safe in [true, false] {
      for readsBack in [true, false] {
        add(
          "DiagnosticsPageCopy.notAttempted(\(safe), \(readsBack))",
          DiagnosticsPageCopy.notAttempted(isSafeMode: safe, readsBackAtStartup: readsBack))
      }
    }
    add("DiagnosticsPageCopy.volumeHelp", DiagnosticsPageCopy.volumeHelp)
    add("DiagnosticsPageCopy.contrastHelp", DiagnosticsPageCopy.contrastHelp)
    add("DiagnosticsPageCopy.muteHelp", DiagnosticsPageCopy.muteHelp)
    add("DiagnosticsPageCopy.hdrTurnedOnOutside", DiagnosticsPageCopy.hdrTurnedOnOutside)
    add("DiagnosticsPageCopy.writeGateLabel(true)", DiagnosticsPageCopy.writeGateLabel(isBuiltIn: true))
    add("DiagnosticsPageCopy.writeGateLabel(false)", DiagnosticsPageCopy.writeGateLabel(isBuiltIn: false))
    add("DiagnosticsPageCopy.safeMode", DiagnosticsPageCopy.safeMode)
    add("DiagnosticsPageCopy.watchedKeys", DiagnosticsPageCopy.watchedKeys)
    for row in DiagnosticsPageCopy.keyWatchRequirements {
      add("DiagnosticsPageCopy.keyWatchRequirements.title", row.title)
      add("DiagnosticsPageCopy.keyWatchRequirements.needs", row.needs)
      add("DiagnosticsPageCopy.keyWatchRequirements.spoken", row.spoken)
    }
    add("DiagnosticsPageCopy.accessibilityMissing", DiagnosticsPageCopy.accessibilityMissing)
    add("DiagnosticsPageCopy.reportScope", DiagnosticsPageCopy.reportScope)
    add("DiagnosticsPageCopy.controlMethodTitle", DiagnosticsPageCopy.controlMethodTitle)
    add("DiagnosticsPageCopy.controlMethodValue", DiagnosticsPageCopy.controlMethodValue)
    add("DiagnosticsPageCopy.copyReport", DiagnosticsPageCopy.copyReport)
    add("DiagnosticsPageCopy.saveReport", DiagnosticsPageCopy.saveReport)
    add("DiagnosticsPageCopy.copied", DiagnosticsPageCopy.copied)
    add("DiagnosticsPageCopy.copiedAccessibly", DiagnosticsPageCopy.copiedAccessibly)
    add("DiagnosticsPageCopy.saveFailed", DiagnosticsPageCopy.saveFailed)
    add("DiagnosticsPageCopy.acknowledge", DiagnosticsPageCopy.acknowledge)
    add("DiagnosticsPageCopy.reportFileName", DiagnosticsPageCopy.reportFileName)

    // DisplayModeCopy
    add("DisplayModeCopy.size(mode)", DisplayModeCopy.size(Self.mode))
    add("DisplayModeCopy.size(descriptor)", DisplayModeCopy.size(Self.descriptor))
    add("DisplayModeCopy.size(w:h:)", DisplayModeCopy.size(width: 1920, height: 1080))
    add("DisplayModeCopy.addedByApp", DisplayModeCopy.addedByApp)
    add("DisplayModeCopy.recommended", DisplayModeCopy.recommended)
    add("DisplayModeCopy.recommendationApply", DisplayModeCopy.recommendationApply)
    add("DisplayModeCopy.recommendationDismiss", DisplayModeCopy.recommendationDismiss)
    for isNative in [true, false] {
      add(
        "DisplayModeCopy.recommendationCallout(isNative: \(isNative))",
        DisplayModeCopy.recommendationCallout(width: 3440, height: 1440, isNative: isNative))
    }
    for hz in [60.0, 59.9, 175.0] { add("DisplayModeCopy.refresh(\(hz))", DisplayModeCopy.refresh(hz)) }
    for seconds in counts {
      add("DisplayModeCopy.countdown(\(seconds))", DisplayModeCopy.countdown(seconds))
      add("DisplayModeCopy.passiveCountdown(\(seconds))", DisplayModeCopy.passiveCountdown(seconds))
      add(
        "DisplayModeCopy.previewAnnouncement(\(seconds))",
        DisplayModeCopy.previewAnnouncement(mode: Self.mode, seconds: seconds))
    }
    add("DisplayModeCopy.startFailure", DisplayModeCopy.startFailure)
    add("DisplayModeCopy.resolveFailure", DisplayModeCopy.resolveFailure)
    add("DisplayModeCopy.expiryAlreadyRan", DisplayModeCopy.expiryAlreadyRan)
    for reason in Self.allStartFailureReasons {
      add("DisplayModeCopy.startFailure(reason)", DisplayModeCopy.startFailure(reason))
      add("DisplayModeCopy.startFailureDiagnostic(reason)", DisplayModeCopy.startFailureDiagnostic(reason))
    }
    for notice in Self.allModeReapplyNotices {
      add(
        "DisplayModeCopy.reapply(\(notice))",
        DisplayModeCopy.reapply(requested: Self.descriptor, notice: notice))
    }
    add(
      "DisplayModeCopy.reapplySubstituted",
      DisplayModeCopy.reapplySubstituted(requested: Self.descriptor, applied: Self.mode))
    add("DisplayModeCopy.reapplyUnavailable", DisplayModeCopy.reapplyUnavailable(requested: Self.descriptor))
    add("DisplayModeCopy.reapplyFailed", DisplayModeCopy.reapplyFailed(requested: Self.descriptor))

    // MirroringCopy
    add("MirroringCopy.sectionTitle", MirroringCopy.sectionTitle)
    add("MirroringCopy.notMirrored", MirroringCopy.notMirrored)
    add("MirroringCopy.notMirroredText", MirroringCopy.notMirroredText)
    add("MirroringCopy.question", MirroringCopy.question)
    add("MirroringCopy.keep", MirroringCopy.keep)
    add("MirroringCopy.stopNow", MirroringCopy.stopNow)
    add("MirroringCopy.startMirroring", MirroringCopy.startMirroring)
    add("MirroringCopy.stopMirroring", MirroringCopy.stopMirroring)
    add("MirroringCopy.reportTitle", MirroringCopy.reportTitle)
    add("MirroringCopy.needsASecondDisplay", MirroringCopy.needsASecondDisplay)
    add("MirroringCopy.noEligibleMaster", MirroringCopy.noEligibleMaster)
    add("MirroringCopy.noSuchDisplay", MirroringCopy.noSuchDisplay)
    add("MirroringCopy.masterIsAlwaysMirrored", MirroringCopy.masterIsAlwaysMirrored)
    add("MirroringCopy.nothingToMirror", MirroringCopy.nothingToMirror)
    add("MirroringCopy.alreadyMirrored", MirroringCopy.alreadyMirrored)
    add("MirroringCopy.cannotBeUnmirrored", MirroringCopy.cannotBeUnmirrored)
    add("MirroringCopy.notInASet", MirroringCopy.notInASet)
    add("MirroringCopy.statusLabel", MirroringCopy.statusLabel)
    add("MirroringCopy.pickMaster", MirroringCopy.pickMaster)
    add("MirroringCopy.startExplanation", MirroringCopy.startExplanation)
    add("MirroringCopy.startExplanationSomeLocked", MirroringCopy.startExplanationSomeLocked)
    add("MirroringCopy.stopExplanation", MirroringCopy.stopExplanation)
    add("MirroringCopy.stopExplanationSomeLocked", MirroringCopy.stopExplanationSomeLocked)
    add("MirroringCopy.applyInProgress", MirroringCopy.applyInProgress)
    add("MirroringCopy.applyFailure", MirroringCopy.applyFailure)
    add("MirroringCopy.resolveFailure", MirroringCopy.resolveFailure)
    for seconds in counts { add("MirroringCopy.countdown(\(seconds))", MirroringCopy.countdown(seconds)) }
    for name in names {
      for refusal in Self.allMirrorRefusals {
        add("MirroringCopy.refusal(\(refusal))", MirroringCopy.refusal(refusal, name: name))
      }
      for members in Self.allDisplayIDLists {
        add(
          "MirroringCopy.setCannotBeBroken(\(members))",
          MirroringCopy.setCannotBeBroken(members: members, name: name))
        add(
          "MirroringCopy.partialBreak(\(members))",
          MirroringCopy.partialBreak(residual: members, name: name))
      }
      for topology in Self.allTopologies {
        for display in [Self.mag, Self.dell, Self.builtIn] {
          add(
            "MirroringCopy.state(\(display))",
            MirroringCopy.state(topology: topology, displayID: display, name: name))
        }
      }
    }

    // OledCareCopy
    for skip in Self.allLockDimSkips {
      let name = String(describing: skip)
      add("OledCareCopy.lockDimStatus(\(name))", OledCareCopy.lockDimStatus(skip))
      add("OledCareCopy.lockDimPreview(\(name))", OledCareCopy.lockDimPreview(skip))
      add("OledCareCopy.lockDimSpokenPreview(\(name))", OledCareCopy.lockDimSpokenPreview(skip))
    }
    for reason in OledCareSuspensionReason.allCases {
      let name = String(describing: reason)
      add("OledCareCopy.suspendedStatus(\(name))", OledCareCopy.suspendedStatus(reason: reason))
      add("OledCareCopy.suspendedPreview(\(name))", OledCareCopy.suspendedPreview(reason: reason))
      add(
        "OledCareCopy.suspendedSpokenPreview(\(name))",
        OledCareCopy.suspendedSpokenPreview(reason: reason))
    }
    add("OledCareCopy.wearFractionScope", OledCareCopy.wearFractionScope)

    // ReconfigurationCopy
    for claimant in ReconfigurationClaimant.allCases {
      add("ReconfigurationCopy.blocked(by: \(claimant))", ReconfigurationCopy.blocked(by: claimant))
    }

    // RotationCopy
    add("RotationCopy.label", RotationCopy.label)
    add("RotationCopy.unavailable", RotationCopy.unavailable)
    add("RotationCopy.question", RotationCopy.question)
    add("RotationCopy.keep", RotationCopy.keep)
    add("RotationCopy.revert", RotationCopy.revert)
    add("RotationCopy.reportTitle", RotationCopy.reportTitle)
    add("RotationCopy.applyFailure", RotationCopy.applyFailure)
    add("RotationCopy.resolveFailure", RotationCopy.resolveFailure)
    for seconds in counts { add("RotationCopy.countdown(\(seconds))", RotationCopy.countdown(seconds)) }
    for rotation in DisplayRotation.allCases {
      add("RotationCopy.angle(\(rotation))", RotationCopy.angle(rotation))
      add(
        "RotationCopy.previewSubtitle(named, \(rotation))",
        RotationCopy.previewSubtitle(name: "DELL U2725QE", to: rotation))
      add(
        "RotationCopy.previewSubtitle(unnamed, \(rotation))",
        RotationCopy.previewSubtitle(name: "", to: rotation))
    }
    for refusal in Self.allRotationRefusals {
      add("RotationCopy.refusal(\(refusal))", RotationCopy.refusal(refusal))
    }

    // SynthesisCopy. Pinned, and scanned for a rate and a sharpness claim, in
    // `SynthesisCopyTests`; listed here too because a builder outside the
    // suite-wide scan is one the house rule is not mechanical for.
    add("SynthesisCopy.reportMode", SynthesisCopy.reportMode(width: 3096, height: 1296, slot: 4))
    add("SynthesisCopy.optInTitle", SynthesisCopy.optInTitle)
    add("SynthesisCopy.optInCaption", SynthesisCopy.optInCaption)
    add("SynthesisCopy.badge", SynthesisCopy.badge)
    add("SynthesisCopy.keepsPanelRefresh", SynthesisCopy.keepsPanelRefresh)
    add("SynthesisCopy.engagedSizeNotListed", SynthesisCopy.engagedSizeNotListed)
    for reason in Self.allSynthesisRefusalReasons {
      add("SynthesisCopy.refusal(\(reason))", SynthesisCopy.refusal(reason))
    }
    for failure in Self.allSynthesisFailures {
      add("SynthesisCopy.engineFailure(\(failure))", SynthesisCopy.engineFailure(failure))
    }
    add(
      "SynthesisCopy.diagnosticsActive",
      SynthesisCopy.diagnosticsActive(width: 3096, height: 1296, slot: 4))
    for count in counts { add("SynthesisCopy.diagnosticsOffered(\(count))", SynthesisCopy.diagnosticsOffered(count)) }

    return out
  }

  // MARK: - Case samples, each pinned by an exhaustiveness guard
  //
  // The guards below FAIL TO COMPILE when a case is added to one of these Kit
  // enums. Each feeds a builder that switches with no `default:` arm, so a new
  // case arriving with no copy is the defect worth catching, and a sample list
  // nothing forces anyone to update would miss it.

  private static let allReportSubjects: [ArrangementReportSubject] =
    [.nothingChanged, .restoreFailed, .diverged]

  private static func guardReportSubject(_ subject: ArrangementReportSubject) -> Int {
    switch subject {
    case .nothingChanged: 0
    case .restoreFailed: 1
    case .diverged: 2
    }
  }

  private static let allReapplyNotices: [ArrangementReapplyNotice] = [
    .ambiguousIdentity(["MAG-0", "MAG-0"]),
    .setDiffers(missing: ["DELL-1"], extra: ["MAG-0"]),
    .layoutNoLongerFits([.overlap(mag, dell)]),
    .savedForDifferentGeometry(["DELL-1"]),
    .failed(DisplayConfigError(cgErrorCode: 1001)),
  ]

  private static func guardReapplyNotice(_ notice: ArrangementReapplyNotice) -> Int {
    switch notice {
    case .ambiguousIdentity: 0
    case .setDiffers: 1
    case .layoutNoLongerFits: 2
    case .savedForDifferentGeometry: 3
    case .failed: 4
    }
  }

  private static let allApplyNotices: [ArrangementApplyNotice] = [
    .adjusted(DisplayArrangement(tiles: [])),
    .mainDisplayUnchanged(dell),
  ]

  private static func guardApplyNotice(_ notice: ArrangementApplyNotice) -> Int {
    switch notice {
    case .adjusted: 0
    case .mainDisplayUnchanged: 1
    }
  }

  /// Both problem kinds, both naming outcomes, and the mixed list whose
  /// precedence the overlap sentence owns.
  private static let allProblemShapes: [[ArrangementProblem]] = [
    [],
    [.overlap(mag, dell)],
    [.overlap(mag, builtIn)],
    [.disconnected(dell)],
    [.disconnected(builtIn)],
    [.disconnected(mag), .disconnected(dell)],
    [.disconnected(mag), .overlap(mag, dell)],
  ]

  private static func guardProblem(_ problem: ArrangementProblem) -> Int {
    switch problem {
    case .overlap: 0
    case .disconnected: 1
    }
  }

  private static let allBrightnessPaths: [BrightnessPath] = [
    .native,
    .hardware,
    .software(.gamma),
    .software(.overlay),
    .combined(switchingValue: 0.4, backend: .gamma),
    .combined(switchingValue: 0, backend: .overlay),
    .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.25),
    .unavailable(.ddcTurnedOffWithNoSoftwareLeg),
    .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.25),
    .unavailable(.ddcUnresponsiveWithNoSoftwareLeg),
  ]

  private static func guardBrightnessPath(_ path: BrightnessPath) -> Int {
    switch path {
    case .native: 0
    case .software: 1
    case .hardware: 2
    case .combined: 3
    case .softwareOnly(_, .ddcTurnedOff, _): 4
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg): 5
    case .softwareOnly(_, .ddcUnresponsive, _): 6
    case .unavailable(.ddcUnresponsiveWithNoSoftwareLeg): 7
    }
  }

  private static let allReadEvidence: [DDCReadEvidence] = [.notAttempted, .answered, .allZeros, .noReply]

  private static func guardReadEvidence(_ evidence: DDCReadEvidence) -> Int {
    switch evidence {
    case .notAttempted: 0
    case .answered: 1
    case .allZeros: 2
    case .noReply: 3
    }
  }

  private static let allMirrorRefusals: [MirrorRefusal] = [
    .onlyOneDisplay,
    .noEligibleMaster,
    .noSuchDisplay,
    .masterIsAlwaysMirrored,
    .nothingToMirror,
    .alreadyMirrored,
    .setCannotBeBroken([mag, dell]),
    .notInASet,
  ]

  private static func guardMirrorRefusal(_ refusal: MirrorRefusal) -> Int {
    switch refusal {
    case .onlyOneDisplay: 0
    case .noEligibleMaster: 1
    case .noSuchDisplay: 2
    case .masterIsAlwaysMirrored: 3
    case .nothingToMirror: 4
    case .alreadyMirrored: 5
    case .setCannotBeBroken: 6
    case .notInASet: 7
    }
  }

  private static let allRotationRefusals: [RotationRefusal] = [
    .unavailable, .displayGone, .unreadable, .unchanged(.ninety),
  ]

  private static func guardRotationRefusal(_ refusal: RotationRefusal) -> Int {
    switch refusal {
    case .unavailable: 0
    case .displayGone: 1
    case .unreadable: 2
    case .unchanged: 3
    }
  }

  private static let allModeReapplyNotices: [ModeReapplyNotice] = [
    .substituted(mode),
    .unavailable,
    .failed(DisplayConfigError(cgErrorCode: 1001)),
  ]

  private static func guardModeReapplyNotice(_ notice: ModeReapplyNotice) -> Int {
    switch notice {
    case .substituted: 0
    case .unavailable: 1
    case .failed: 2
    }
  }

  private static let allStartFailureReasons: [DisplayModeCoordinator.StartFailure.Reason] =
    [.failed(DisplayConfigError(cgErrorCode: 1001))]
      + ReconfigurationClaimant.allCases.map { .blocked(by: $0) }

  private static func guardStartFailureReason(_ reason: DisplayModeCoordinator.StartFailure.Reason) -> Int {
    switch reason {
    case .failed: 0
    case .blocked: 1
    }
  }

  /// nil is a sample too: it is the case both lock-dim builders treat as "the
  /// dim happened", and the one a past defect printed for a refusal.
  private static let allLockDimSkips: [LockDimSkip?] =
    [nil, .nothingDrivesBrightness, .outsideSoftwareBand, .alreadyAtTarget]

  private static func guardLockDimSkip(_ skip: LockDimSkip?) -> Int {
    switch skip {
    case nil: 0
    case .nothingDrivesBrightness: 1
    case .outsideSoftwareBand: 2
    case .alreadyAtTarget: 3
    }
  }

  private static let allSynthesisFailures: [SynthesisFailure] = [
    .unavailable, .noFreeSlot, .createFailed(.classFamilyUnavailable),
    .virtualModeNotAchieved, .mirrorRefused, .engageNotAchieved, .notEngaged,
    .unwindIncomplete,
  ]

  private static func guardSynthesisFailure(_ failure: SynthesisFailure) -> Int {
    switch failure {
    case .unavailable: 0
    case .noFreeSlot: 1
    case .createFailed: 2
    case .virtualModeNotAchieved: 3
    case .mirrorRefused: 4
    case .engageNotAchieved: 5
    case .notEngaged: 6
    case .unwindIncomplete: 7
    }
  }

  private static let allSynthesisRefusalReasons: [SynthesisCoordinator.Refusal.Reason] =
    [
      .builtIn, .hdrEngaged, .alreadyMirrored, .notOffered, .sizeNoLongerOffered,
      .restoreSuperseded, .hdrLeftStanding, .busy,
    ]
      + ReconfigurationClaimant.allCases.map { .blocked(by: $0) }
      + allSynthesisFailures.map { .engine($0) }

  private static func guardSynthesisRefusalReason(
    _ reason: SynthesisCoordinator.Refusal.Reason
  ) -> Int {
    switch reason {
    case .builtIn: 0
    case .hdrEngaged: 1
    case .alreadyMirrored: 2
    case .notOffered: 3
    case .sizeNoLongerOffered: 4
    case .restoreSuperseded: 5
    case .hdrLeftStanding: 6
    case .busy: 7
    case .blocked: 8
    case .engine: 9
    }
  }

  /// Both naming outcomes for the two count-fallback builders: fully named,
  /// partly named (which falls back), and a single member.
  private static let allDisplayIDLists: [[CGDirectDisplayID]] = [
    [mag], [builtIn], [mag, dell], [mag, builtIn], [mag, dell, builtIn],
  ]

  private static let allTopologies: [MirrorTopology] = [
    MirrorTopology([]),
    MirrorTopology([display(mag, name: "MAG 341C")]),
    MirrorTopology([
      display(dell, name: "DELL U2725QE", inSet: true),
      display(mag, name: "MAG 341C", mirrors: dell),
    ]),
    MirrorTopology([
      display(dell, name: "DELL U2725QE", inSet: true),
      display(mag, name: "MAG 341C", mirrors: dell),
      display(builtIn, name: "Built-in", mirrors: dell),
    ]),
  ]

  /// Touches every guard so none is dead code the compiler stops checking.
  @Test func everyGuardedEnumIsStillTheShapeTheSamplesAssume() {
    #expect(Set(Self.allReportSubjects.map(Self.guardReportSubject)).count == 3)
    #expect(Set(Self.allReapplyNotices.map(Self.guardReapplyNotice)).count == 5)
    #expect(Set(Self.allApplyNotices.map(Self.guardApplyNotice)).count == 2)
    #expect(Set(Self.allProblemShapes.flatMap { $0 }.map(Self.guardProblem)).count == 2)
    #expect(Set(Self.allBrightnessPaths.map(Self.guardBrightnessPath)).count == 8)
    #expect(Set(Self.allReadEvidence.map(Self.guardReadEvidence)).count == 4)
    #expect(Set(Self.allMirrorRefusals.map(Self.guardMirrorRefusal)).count == 8)
    #expect(Set(Self.allRotationRefusals.map(Self.guardRotationRefusal)).count == 4)
    #expect(Set(Self.allModeReapplyNotices.map(Self.guardModeReapplyNotice)).count == 3)
    #expect(Set(Self.allStartFailureReasons.map(Self.guardStartFailureReason)).count == 2)
    #expect(Set(Self.allLockDimSkips.map(Self.guardLockDimSkip)).count == 4)
    #expect(Set(Self.allSynthesisFailures.map(Self.guardSynthesisFailure)).count == 8)
    #expect(Set(Self.allSynthesisRefusalReasons.map(Self.guardSynthesisRefusalReason)).count == 10)
  }
}
