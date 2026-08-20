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
    suggestion: OnboardingSizeSuggestion? = nil
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
      enrolledInCare: false
    )
  }

  private func environment(_ displays: [OnboardingDisplayEntry]) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: true,
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
