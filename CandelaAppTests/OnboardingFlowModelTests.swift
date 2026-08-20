import Testing

// The flow model's apply seam and its state machine (PD9): an apply opens a
// keep and revert countdown, expiry REVERTS and the page stays, only an
// explicit keep records the choice and advances, and the `.applySize` commit
// is a record of a kept apply, never a trigger. Everything runs over the
// fixture applier or hand-driven seam reports; no display, no coordinator.
@Suite("Onboarding flow model")
@MainActor
struct OnboardingFlowModelTests {
  private func entry(
    key: String,
    productName: String = "Generic Display",
    suggestion: OnboardingSizeSuggestion? = nil,
    enrolled: Bool = false,
    measuredTelemetry: Bool = false
  ) -> OnboardingDisplayEntry {
    OnboardingDisplayEntry(
      persistenceKey: key,
      name: productName,
      productName: productName,
      nativePixelWidth: 3840,
      nativePixelHeight: 2160,
      rotationDegrees: 0,
      diagonalInches: 27,
      currentLooksLikeWidth: 3840,
      currentLooksLikeHeight: 2160,
      refreshHz: 60,
      volume: .unknown,
      sizeSuggestion: suggestion,
      enrolledInCare: enrolled,
      measuredTelemetry: measuredTelemetry
    )
  }

  private func environment(
    _ displays: [OnboardingDisplayEntry], firstRun: Bool = true
  ) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: firstRun,
      displays: displays)
  }

  private let suggestion = OnboardingSizeSuggestion(
    looksLikeWidth: 2560, looksLikeHeight: 1440,
    alternatives: [
      .init(looksLikeWidth: 2560, looksLikeHeight: 1440, isHiDPI: true),
      .init(looksLikeWidth: 3008, looksLikeHeight: 1692, isHiDPI: true),
    ])

  /// The rig: an OLED with no suggestion and a dell with one, advanced to
  /// the dell's size page (welcome, detection, size).
  private func modelOnSizePage() -> OnboardingFlowModel {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell", suggestion: suggestion),
    ]))
    for _ in 0..<10 where model.currentPage != .size(displayKey: "dell") {
      model.advance()
    }
    #expect(model.currentPage == .size(displayKey: "dell"))
    return model
  }

  // MARK: - The state walk

  @Test func applyStartsACountdownWithoutRecordingAChoice() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    #expect(model.applyState == .counting(secondsRemaining: 15))
    #expect(model.applyCountdownSecondsRemaining(forKey: "dell") == 15)
    #expect(model.applyCountdownSecondsRemaining(forKey: "mag") == nil)
    let pending = model.pendingAppliedSize(forKey: "dell")
    #expect(pending?.width == 2560)
    #expect(pending?.height == 1440)
    // No decision exists until the countdown is answered.
    #expect(model.sizeChoices["dell"] == nil)
    #expect(model.committed.isEmpty)
  }

  @Test func keepRecordsTheChoiceEmitsTheRecordAndAdvances() {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.applySize(displayKey: "dell", choice: .recommended)
    model.keepSize()
    #expect(model.sizeChoices["dell"] == .recommended)
    #expect(model.committed == [
      .applySize(displayKey: "dell", looksLikeWidth: 2560, looksLikeHeight: 1440)
    ])
    #expect(model.index == pageIndex + 1)
    // The per-apply state resets on navigation so the next page starts clean.
    #expect(model.applyState == .idle)
    #expect(model.pendingAppliedSize(forKey: "dell") == nil)
  }

  @Test func aKeptCustomSizeEmitsItsOwnDimensions() {
    let model = modelOnSizePage()
    model.applySize(
      displayKey: "dell", choice: .custom(looksLikeWidth: 3008, looksLikeHeight: 1692))
    model.keepSize()
    #expect(model.sizeChoices["dell"]
      == .custom(looksLikeWidth: 3008, looksLikeHeight: 1692))
    #expect(model.committed == [
      .applySize(displayKey: "dell", looksLikeWidth: 3008, looksLikeHeight: 1692)
    ])
  }

  @Test func revertClickStaysOnThePageAndRecordsKeepCurrent() {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.applySize(displayKey: "dell", choice: .recommended)
    model.revertSize()
    #expect(model.applyState == .reverted)
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    #expect(model.index == pageIndex)
    #expect(model.currentPage == .size(displayKey: "dell"))
    // Advancing afterwards emits nothing: no kept apply, no record.
    model.advance()
    #expect(model.committed.isEmpty)
  }

  @Test func revertThenReapplyThenKeepWalksAsOneSequence() {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.applySize(displayKey: "dell", choice: .recommended)
    model.revertSize()
    #expect(model.applyState == .reverted)
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    #expect(model.index == pageIndex)
    // A second apply on the same page overwrites the reverted decision.
    model.applySize(
      displayKey: "dell", choice: .custom(looksLikeWidth: 3008, looksLikeHeight: 1692))
    #expect(model.applyState == .counting(secondsRemaining: 15))
    model.keepSize()
    #expect(model.sizeChoices["dell"]
      == .custom(looksLikeWidth: 3008, looksLikeHeight: 1692))
    #expect(model.index == pageIndex + 1)
    #expect(model.committed == [
      .applySize(displayKey: "dell", looksLikeWidth: 3008, looksLikeHeight: 1692)
    ])
  }

  @Test func countdownSeedFollowsTheInstalledApplierSeconds() {
    let model = modelOnSizePage()
    // Install with the applier's seconds so the seed var is set, then
    // silence the seam: the fixture applier's synchronous first tick would
    // also report 7 and mask a hardcoded seed. With `onApplySize` a no-op,
    // the state below can only be the model's own synchronous seed.
    model.installFixtureSizeApplier(seconds: 7, tick: .seconds(60))
    model.onApplySize = { _, _, _ in }
    model.applySize(displayKey: "dell", choice: .recommended)
    #expect(model.applyState == .counting(secondsRemaining: 7))
    #expect(model.applyCountdownSecondsRemaining(forKey: "dell") == 7)
  }

  @Test func fixtureExpiryRevertsAndThePageStays() async throws {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.installFixtureSizeApplier(seconds: 3, tick: .milliseconds(1))
    model.applySize(displayKey: "dell", choice: .recommended)
    // Bounded wait for the fixture ticker; 2 s ceiling against a 3 ms walk.
    for _ in 0..<400 where model.applyState != .reverted {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.applyState == .reverted)
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    // The Stage 1 mock advanced here; expiry must leave the page in place.
    #expect(model.index == pageIndex)
    #expect(model.committed.isEmpty)
  }

  // MARK: - The seam contract the live wiring implements

  @Test func seamReportsDriveTheObservableState() {
    let model = modelOnSizePage()
    var applies: [(key: String, width: Int, height: Int)] = []
    var keeps = 0
    var reverts = 0
    model.onApplySize = { applies.append(($0, $1, $2)) }
    model.onKeepSize = { keeps += 1 }
    model.onRevertSize = { reverts += 1 }

    model.applySize(displayKey: "dell", choice: .recommended)
    #expect(applies.count == 1)
    #expect(applies.first?.key == "dell")
    #expect(applies.first?.width == 2560)
    #expect(applies.first?.height == 1440)

    model.applyCountdownTicked(secondsRemaining: 9)
    #expect(model.applyState == .counting(secondsRemaining: 9))

    // The answer routes forward and resolve nothing themselves; the state
    // moves only on the implementation's report.
    model.keepSize()
    #expect(keeps == 1)
    #expect(reverts == 0)
    #expect(model.applyState == .counting(secondsRemaining: 9))

    model.applyKept()
    #expect(model.sizeChoices["dell"] == .recommended)
    #expect(model.applyState == .idle)
    #expect(model.committed == [
      .applySize(displayKey: "dell", looksLikeWidth: 2560, looksLikeHeight: 1440)
    ])
  }

  @Test func answersOutsideACountdownRouteAndReportNothing() {
    let model = modelOnSizePage()
    var keeps = 0
    var reverts = 0
    model.onKeepSize = { keeps += 1 }
    model.onRevertSize = { reverts += 1 }
    model.keepSize()
    model.revertSize()
    #expect(keeps == 0)
    #expect(reverts == 0)
    // Reports with nothing pending change nothing either.
    model.applyCountdownTicked(secondsRemaining: 5)
    model.applyKept()
    model.applyReverted()
    model.applyFailed()
    #expect(model.applyState == .idle)
    #expect(model.sizeChoices.isEmpty)
    #expect(model.committed.isEmpty)
  }

  @Test func aFailedApplyRecordsNothingAndReturnsToChoices() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.applyFailed()
    #expect(model.applyState == .failed)
    #expect(model.sizeChoices["dell"] == nil)
    #expect(model.applyCountdownSecondsRemaining(forKey: "dell") == nil)
    // A retry opens a fresh countdown.
    model.applySize(displayKey: "dell", choice: .recommended)
    #expect(model.applyState == .counting(secondsRemaining: 15))
  }

  // MARK: - The flow's edges (OB7)

  @Test func skipMidCountdownRevertsBeforeClosing() {
    let model = modelOnSizePage()
    var events: [String] = []
    model.onRevertSize = { [weak model] in
      events.append("revert")
      model?.applyReverted()
    }
    model.onClose = { events.append("close") }
    model.applySize(displayKey: "dell", choice: .recommended)
    model.skip()
    #expect(events == ["revert", "close"])
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    // Skip commits nothing; only what was already applied stays.
    #expect(model.committed.isEmpty)
  }

  @Test func pageDisappearanceRevertsAnOpenCountdownOnce() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.sizePageDisappeared()
    #expect(model.applyState == .reverted)
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    // Idempotent: a second disappearance answers nothing.
    model.sizePageDisappeared()
    #expect(model.applyState == .reverted)
  }

  @Test func backMidCountdownRevertsAndResets() {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.applySize(displayKey: "dell", choice: .recommended)
    model.back()
    #expect(model.index == pageIndex - 1)
    #expect(model.sizeChoices["dell"] == .keepCurrent)
    #expect(model.applyState == .idle)
  }

  @Test func aMidCountdownReharvestWithoutTheSuggestionKeepsThePage() {
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.applySize(displayKey: "dell", choice: .recommended)
    // The live apply changes the display's mode, which fires a re-harvest
    // that sees the previewed size as current: the fresh entry arrives with
    // no suggestion while the display itself is still present. The page must
    // survive, or its disappearance reverts the apply the user asked for.
    model.update(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]))
    #expect(model.currentPage == .size(displayKey: "dell"))
    #expect(model.index == pageIndex)
    // The countdown lives on, and keep still resolves and advances with the
    // kept size's record.
    #expect(model.applyCountdownSecondsRemaining(forKey: "dell") != nil)
    model.keepSize()
    #expect(model.sizeChoices["dell"] == .recommended)
    #expect(model.index == pageIndex + 1)
    #expect(model.committed == [
      .applySize(displayKey: "dell", looksLikeWidth: 2560, looksLikeHeight: 1440)
    ])
  }

  @Test func afterAKeptApplyAReharvestWithoutTheSuggestionDropsThePage() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.keepSize()
    // Resolved: the carry-over must not outlive the apply, so a later
    // harvest with no suggestion drops the page normally.
    model.update(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]))
    #expect(!model.pages.contains(.size(displayKey: "dell")))
    #expect(model.index < model.pages.count)
  }

  @Test func afterARevertedApplyAReharvestWithoutTheSuggestionDropsThePage() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.revertSize()
    #expect(model.applyState == .reverted)
    model.update(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]))
    #expect(!model.pages.contains(.size(displayKey: "dell")))
    #expect(model.index < model.pages.count)
  }

  @Test func aMidCountdownUnplugForgetsTheCountdown() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.update(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED")
    ]))
    // The shipped path clears its preview on departure; the flow forgets its
    // countdown and records no decision for a display that is gone.
    #expect(model.applyState == .idle)
    #expect(model.sizeChoices["dell"] == nil)
    #expect(!model.pages.contains { if case .size = $0 { true } else { false } })
    #expect(model.index < model.pages.count)
  }

  // MARK: - Screen Recording achieved state

  @Test func screenRecordingGrantTracksThePreflightNeverTheClick() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", suggestion: suggestion)
    ]))
    var granted = false
    model.onPreflightScreenRecording = { granted }
    #expect(!model.screenRecordingGranted)
    // The ask alone proves nothing; the preflight still says no.
    model.requestScreenRecording()
    #expect(model.screenRecordingRequested)
    #expect(!model.screenRecordingGranted)
    // The grant lands outside the app; a refresh picks it up.
    granted = true
    model.refreshScreenRecordingGranted()
    #expect(model.screenRecordingGranted)
  }

  @Test func fixturePreflightSimulatesGrantedAfterRequest() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", suggestion: suggestion)
    ]))
    #expect(!model.screenRecordingGranted)
    model.requestScreenRecording()
    #expect(model.screenRecordingGranted)
  }

  // MARK: - Telemetry prefill (OB3 on a first run, the stored pref after)

  @Test func aReRunSeedsTheMeasurementChoiceFromTheEnrolledDisplaysPref() {
    // A returning user who chose Estimated arrives with the pref false on
    // their enrolled display; the flow must not silently re-recommend
    // measured over that decision.
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)],
      firstRun: false))
    #expect(!model.measuredTelemetry)
  }

  @Test func aReRunSeedsTrueFromAMeasuredEnrolledDisplay() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(
        key: "mag", productName: "MAG 341CQPX QD-OLED",
        enrolled: true, measuredTelemetry: true)],
      firstRun: false))
    #expect(model.measuredTelemetry)
  }

  @Test func aFirstRunKeepsTheRecommendedMeasuredDefault() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)],
      firstRun: true))
    #expect(model.measuredTelemetry)
  }

  @Test func aReRunWithNoEnrolledDisplayKeepsTheMeasuredDefault() {
    // An unenrolled display's pref is the unwritten default and encodes no
    // decision, so it never flips the recommendation.
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")],
      firstRun: false))
    #expect(model.measuredTelemetry)
  }

  // MARK: - The off paths a re-run needs

  private func walk(_ model: OnboardingFlowModel, to page: OnboardingPage) {
    for _ in 0..<10 where model.currentPage != page { model.advance() }
    #expect(model.currentPage == page)
  }

  /// The designation page owns this write precisely because the deselect can
  /// take the care page out of the plan: if the care arm owned it, the
  /// un-enrollment would have no page left to ride.
  @Test func deselectingTheOnlyEnrolledDisplayEmitsOneUnenroll() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)],
      firstRun: false))
    walk(model, to: .oledSelect)
    model.designatedOleds.remove("mag")
    model.careEnabled.remove("mag")
    #expect(!model.pages.contains(.oledCare))
    model.advance()
    #expect(model.committed == [.unenrollFromCare(displayKey: "mag")])
  }

  /// Nothing to undo, so nothing is written: an unenrolled display's pref is
  /// the unwritten default and a deselect must not start writing it.
  @Test func deselectingADisplayThatWasNeverEnrolledEmitsNothing() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledSelect)
    model.designatedOleds.remove("mag")
    model.careEnabled.remove("mag")
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// The other half of the split: still designated, so the designation arm
  /// leaves it alone and the care page's toggle carries the un-enrollment.
  @Test func aStillDesignatedDisplayWithProtectionOffEmitsUnenroll() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)],
      firstRun: false))
    walk(model, to: .oledCare)
    #expect(model.committed.isEmpty)
    model.careEnabled.remove("mag")
    model.advance()
    #expect(model.committed == [.unenrollFromCare(displayKey: "mag")])
  }

  /// The care arm's guard, from the other side: a display designated by the
  /// name guess alone was never enrolled, so turning its toggle off is a
  /// decision not to enroll rather than an un-enrollment.
  @Test func aNeverEnrolledDisplayWithProtectionOffEmitsNothing() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.careEnabled.remove("mag")
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// The two arms are disjoint by construction; this walks a rig where both
  /// fire on the same run and pins one write per display.
  @Test func aDeselectAndAToggleOffEachCommitOnce() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED", enrolled: true),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      ],
      firstRun: false))
    walk(model, to: .oledSelect)
    model.designatedOleds.remove("dell")
    model.careEnabled.remove("dell")
    model.advance()
    #expect(model.currentPage == .oledCare)
    model.careEnabled.remove("mag")
    model.advance()
    #expect(model.committed == [
      .unenrollFromCare(displayKey: "dell"),
      .unenrollFromCare(displayKey: "mag"),
    ])
  }

  /// A first run has no stored measurement decision, so choosing estimated
  /// leaves the key absent rather than writing a false the app cannot tell
  /// from a decision.
  @Test func estimatedOnAFirstRunWritesNoMeasurementDecision() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.measuredTelemetry = false
    model.advance()
    #expect(model.committed == [.enrollInCare(displayKey: "mag")])
  }

  @Test func estimatedOnAReRunTurnsOffEachMeasuredDisplay() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED", enrolled: true, measuredTelemetry: true),
        entry(
          key: "mag", productName: "MAG 341CQPX QD-OLED",
          enrolled: true, measuredTelemetry: true),
      ],
      firstRun: false))
    #expect(model.measuredTelemetry)
    walk(model, to: .oledCare)
    model.measuredTelemetry = false
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "dell"),
      .disableMeasuredTelemetry(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
      .disableMeasuredTelemetry(displayKey: "mag"),
    ])
  }

  /// Mixed harvest: only the display whose stored pref says measured has
  /// anything to turn off.
  @Test func estimatedOnlyTurnsOffTheDisplayThatWasMeasuring() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED", enrolled: true, measuredTelemetry: true),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      ],
      firstRun: false))
    walk(model, to: .oledCare)
    model.measuredTelemetry = false
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "dell"),
      .disableMeasuredTelemetry(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
    ])
  }

  /// The measurement choice is one switch for the whole flow, so a mixed
  /// harvest has to pick a side. It must not pick the destructive one: seeding
  /// from the first enrolled display would let an untouched flow turn the
  /// OTHER display's measurement off on the way past.
  @Test func aMixedHarvestReAffirmsMeasuredInsteadOfTurningItOff() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED", enrolled: true),
        entry(
          key: "mag", productName: "MAG 341CQPX QD-OLED",
          enrolled: true, measuredTelemetry: true),
      ],
      firstRun: false))
    #expect(model.measuredTelemetry)
    walk(model, to: .oledCare)
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "dell"),
      .enableMeasuredTelemetry(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
      .enableMeasuredTelemetry(displayKey: "mag"),
    ])
  }

  /// The topology loop calls `update` on every reconfiguration while Setup is
  /// open, so an enrolled display really can arrive mid-flow. It must arrive
  /// designated: absent from the set, the designation arm would read it as a
  /// deselect and un-enroll a display the user never saw.
  @Test func anEnrolledDisplayArrivingMidFlowIsNotUnenrolled() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)],
      firstRun: false))
    walk(model, to: .oledSelect)
    model.update(environment: environment(
      [
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
        entry(key: "dell", productName: "DELL OLED", enrolled: true),
      ],
      firstRun: false))
    #expect(model.designatedOleds == ["mag", "dell"])
    #expect(model.careEnabled.contains("dell"))
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// A departure is not a decision: the prune that drops a departed display
  /// must not be remembered as a deselect, or the replug would un-enroll it.
  @Test func unpluggingAndRepluggingAnEnrolledDisplayIsNotADeselect() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      entry(key: "dell", productName: "DELL OLED", enrolled: true),
    ]
    let model = OnboardingFlowModel(environment: environment(both, firstRun: false))
    walk(model, to: .oledSelect)
    model.update(environment: environment([both[0]], firstRun: false))
    #expect(model.designatedOleds == ["mag"])
    model.update(environment: environment(both, firstRun: false))
    #expect(model.designatedOleds == ["mag", "dell"])
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// The other side of the same rule: a deliberate deselect IS a decision, and
  /// a replug must not resurrect the designation and swallow it.
  @Test func aDeselectSurvivesTheDisplayBeingReplugged() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      entry(key: "dell", productName: "DELL OLED", enrolled: true),
    ]
    let model = OnboardingFlowModel(environment: environment(both, firstRun: false))
    walk(model, to: .oledSelect)
    model.designatedOleds.remove("dell")
    model.careEnabled.remove("dell")
    model.update(environment: environment([both[0]], firstRun: false))
    model.update(environment: environment(both, firstRun: false))
    #expect(model.designatedOleds == ["mag"])
    model.advance()
    #expect(model.committed == [.unenrollFromCare(displayKey: "dell")])
  }

  /// The enrollment-family commit leads the telemetry-family commit for a
  /// display, whichever direction each is going.
  @Test func enrollmentPrecedesTheMeasurementCommitPerDisplay() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "dell"),
      .enableMeasuredTelemetry(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
      .enableMeasuredTelemetry(displayKey: "mag"),
    ])
  }

  // MARK: - Display names

  @Test func aRenameThatTrimsToEmptyFallsBackToTheEnvironmentName() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", suggestion: suggestion)
    ]))
    model.renames["dell"] = ""
    #expect(model.displayName(forKey: "dell") == "Generic Display")
    model.renames["dell"] = "   "
    #expect(model.displayName(forKey: "dell") == "Generic Display")
    model.renames["dell"] = "Desk Display"
    #expect(model.displayName(forKey: "dell") == "Desk Display")
  }

  // MARK: - Stage 1 behaviours that must not regress

  @Test func commitsArriveInPageOrderOnAdvance() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", suggestion: suggestion)
    ]))
    #expect(model.currentPage == .welcome)
    model.advance()
    #expect(model.currentPage == .detection)
    model.renames["dell"] = "Desk Display"
    model.advance()
    #expect(model.currentPage == .size(displayKey: "dell"))
    model.applySize(displayKey: "dell", choice: .recommended)
    model.keepSize()
    #expect(model.committed == [
      .rename(displayKey: "dell", name: "Desk Display"),
      .applySize(displayKey: "dell", looksLikeWidth: 2560, looksLikeHeight: 1440),
    ])
  }

  @Test func skipKeepsAlreadyCommittedWork() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", suggestion: suggestion)
    ]))
    model.advance()
    model.renames["dell"] = "Desk Display"
    model.advance()
    var closed = false
    model.onClose = { closed = true }
    model.skip()
    #expect(closed)
    #expect(model.committed == [.rename(displayKey: "dell", name: "Desk Display")])
  }

  @Test func advancingASizePageWithNoChoiceEmitsNothing() {
    // The vanished-subject advance rides this: the page's fallback calls
    // plain advance(), which must record nothing for an unanswered page.
    let model = modelOnSizePage()
    let pageIndex = model.index
    model.advance()
    #expect(model.committed.isEmpty)
    #expect(model.index == pageIndex + 1)
  }

  @Test func replanKeepsThePositionOnAStillValidPage() {
    // A rig with no name-guessed OLED, so the designation below is a real
    // insertion rather than a no-op reassignment.
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "plain", productName: "Plain Monitor"),
      entry(key: "dell", suggestion: suggestion),
    ]))
    for _ in 0..<10 where model.currentPage != .size(displayKey: "dell") {
      model.advance()
    }
    #expect(!model.pages.contains(.oledCare))
    // Designating mid-flow inserts the care page without moving the user off
    // the size page they are on.
    model.designatedOleds = ["plain"]
    #expect(model.currentPage == .size(displayKey: "dell"))
    #expect(model.pages.contains(.oledCare))
  }
}
