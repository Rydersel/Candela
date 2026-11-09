import Testing

// The flow model's apply seam and its state machine: an apply opens a
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
    _ displays: [OnboardingDisplayEntry], firstRun: Bool = true,
    accessibilityGranted: Bool = false, keyModesRequireGrant: Bool = true,
    keyModesOff: Bool = false
  ) -> OnboardingEnvironment {
    OnboardingEnvironment(
      accessibilityGranted: accessibilityGranted, loginItemEnabled: false,
      isFirstRun: firstRun, keyModesRequireGrant: keyModesRequireGrant,
      keyModesOff: keyModesOff,
      arrangedDisplayCount: displays.count + 1,
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

  // MARK: - What the display is actually showing

  /// The unhonoured commit reaches the page. Without it the setup window asks
  /// "keep it?" over a glyph naming a size the display is not showing, and the
  /// person answering has no way to see the difference.
  @Test func anAchievedSizeReportedWithATickReachesThePage() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    // The ordinary case reports nothing, so no caption is drawn.
    #expect(model.pendingAchievedSize(forKey: "dell") == nil)

    model.applyCountdownTicked(
      secondsRemaining: 12, achieved: .size(width: 1920, height: 1080, refreshHz: 30))
    #expect(model.applyState == .counting(secondsRemaining: 12))
    #expect(model.pendingAchievedSize(forKey: "dell")
      == .size(width: 1920, height: 1080, refreshHz: 30))
    // The glyph still identifies the requested size, while recovery explains
    // that it did not arrive.
    #expect(model.pendingAppliedSize(forKey: "dell")?.width == 2560)
    // One display's divergence never captions another display's page.
    #expect(model.pendingAchievedSize(forKey: "mag") == nil)
  }

  @Test func recoveryCountdownNeverOffersKeepAndSpentCountdownOffersRetry() {
    #expect(!OnboardingSizePage.countdownCaption(seconds: 12, canKeep: false).contains("keep"))
    #expect(OnboardingSizePage.countdownCaption(seconds: 12, canKeep: false).contains("12s"))
    #expect(OnboardingSizePage.countdownCaption(seconds: 0, canKeep: false).contains("Choose Revert"))
    #expect(!OnboardingSizePage.countdownCaption(seconds: 0, canKeep: false).contains("0s"))
    #expect(OnboardingSizePage.countdownCaption(seconds: 12, canKeep: true).contains("unless you keep it"))
  }

  @Test func anUnverifiedSizeAllowsOnlyRevert() {
    let model = modelOnSizePage()
    var keeps = 0
    var reverts = 0
    model.onKeepSize = { keeps += 1 }
    model.onRevertSize = { reverts += 1 }
    model.applySize(displayKey: "dell", choice: .recommended)
    model.applyCountdownTicked(secondsRemaining: 12, achieved: .unreadable)
    model.keepSize()
    model.revertSize()
    #expect(keeps == 0)
    #expect(reverts == 1)
    #expect(model.sizeChoices["dell"] == nil)
  }

  /// A commit that went through and could not be read back is its own case: a
  /// failed readback is not evidence the size arrived, so it must not report as
  /// the ordinary nothing-to-say.
  @Test func anUnreadableAchievedSizeIsCarriedRatherThanDropped() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.applyCountdownTicked(secondsRemaining: 12, achieved: .unreadable)
    #expect(model.pendingAchievedSize(forKey: "dell") == .unreadable)
  }

  /// Reported per tick, so a later tick with nothing to say retires the caption
  /// rather than leaving a sentence about a resolution no longer on the glass.
  @Test func aLaterTickWithNothingToSayRetiresTheAchievedSize() {
    let model = modelOnSizePage()
    model.applySize(displayKey: "dell", choice: .recommended)
    model.applyCountdownTicked(
      secondsRemaining: 12, achieved: .size(width: 1920, height: 1080, refreshHz: 30))
    model.applyCountdownTicked(secondsRemaining: 11)
    #expect(model.pendingAchievedSize(forKey: "dell") == nil)
  }

  /// Every way an apply ends drops it, so the next question starts clean.
  @Test func endingAnApplyDropsTheAchievedSize() {
    for end in ["keep", "revert", "fail", "pick again"] {
      let model = modelOnSizePage()
      model.applySize(displayKey: "dell", choice: .recommended)
      model.applyCountdownTicked(
        secondsRemaining: 12, achieved: .size(width: 1920, height: 1080, refreshHz: 30))
      switch end {
      // A keep advances, and the per-apply state resets on navigation.
      case "keep": model.applyKept()
      case "revert": model.applyReverted()
      case "fail": model.applyFailed()
      default: model.applySize(displayKey: "dell", choice: .recommended)
      }
      #expect(model.pendingAchievedSize(forKey: "dell") == nil, "ended by \(end)")
    }
  }

  /// The page's own mapping, so the setup window cannot word this differently
  /// from the settings banner, the floating card and the menu bar. In this
  /// page's dialect: it writes every size with an x and calls it a size, and a
  /// caption arriving in the app windows' spelling reads as a line from
  /// somewhere else.
  @Test func theSizePageSpeaksTheSharedAchievedSentenceInItsOwnDialect() {
    let named = OnboardingSizePage.achievedCaption(
      .size(width: 1920, height: 1080, refreshHz: 30))
    #expect(named == DisplayModeCopy.achievedGeometry(
      width: 1920, height: 1080, refreshHz: 30, dialect: .size))
    #expect(named.contains("1920 x 1080"))
    #expect(!named.contains("×"))

    let unreadable = OnboardingSizePage.achievedCaption(.unreadable)
    #expect(unreadable == DisplayModeCopy.unreadableAchievedGeometry(dialect: .size))
    #expect(unreadable.contains("size"))
    #expect(!unreadable.contains("resolution"))
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
    // Expiry reverts in place; it never advances.
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

  // MARK: - The flow's edges

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

  // MARK: - The keys page's presence

  private func modelOnKeysPage() -> OnboardingFlowModel {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED")
    ]))
    #expect(model.includesKeysPage)
    for _ in 0..<10 where model.currentPage != .accessibility {
      model.advance()
    }
    #expect(model.currentPage == .accessibility)
    return model
  }

  /// The grant lands while the page is up. A re-derived plan would say the
  /// page is no longer wanted; the page has to stay and show its granted
  /// state instead of vanishing under the pointer.
  @Test func grantMidPageKeepsTheKeysPage() {
    let model = modelOnKeysPage()
    model.update(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")],
      accessibilityGranted: true))
    #expect(model.currentPage == .accessibility)
    #expect(model.pages.contains(.accessibility))
  }

  /// Turning the keys off writes key modes that no longer want the grant, and
  /// the next harvest carries that. The page the person just answered stays.
  @Test func keysTurnedOffMidPageKeepsTheKeysPage() {
    let model = modelOnKeysPage()
    model.update(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")],
      keyModesRequireGrant: false))
    #expect(model.currentPage == .accessibility)
    #expect(model.pages.contains(.accessibility))
  }

  /// The designation set replans too, and must read the same latched answer:
  /// after a granted harvest, a designation change cannot drop the page.
  @Test func aDesignationChangeAfterTheGrantKeepsTheKeysPage() {
    let model = modelOnKeysPage()
    model.update(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")],
      accessibilityGranted: true))
    model.designatedOleds = []
    #expect(model.pages.contains(.accessibility))
    model.designatedOleds = ["mag"]
    #expect(model.pages.contains(.accessibility))
    #expect(model.currentPage == .accessibility)
  }

  /// Presence is decided once, when the flow opens, so the page list does not
  /// shift under the person as the grant and the key modes move during setup.
  @Test func aFlowThatOpenedWithoutTheKeysPageNeverGainsIt() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag")], accessibilityGranted: true))
    #expect(!model.includesKeysPage)
    #expect(!model.pages.contains(.accessibility))
    // The grant is revoked mid-flow; the plan still has no keys page.
    model.update(environment: environment([entry(key: "mag")]))
    #expect(!model.pages.contains(.accessibility))
    model.designatedOleds = ["mag"]
    #expect(!model.pages.contains(.accessibility))
  }

  // MARK: - The keys page's answers

  /// The consequence-labeled skip is a decision: it turns keyboard control off,
  /// so the stored modes stop wanting a grant the person just declined.
  @Test func skipKeysCommitsKeyboardOffAndAdvances() {
    let model = modelOnKeysPage()
    let keysIndex = model.index
    model.skipKeys()
    #expect(model.committed == [.disableKeyboardControl])
    #expect(model.index == keysIndex + 1)
    #expect(model.keysDeclined)
  }

  @Test func grantedPageCommitsNothing() {
    let model = modelOnKeysPage()
    model.accessibilityGranted = true
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// Skip Setup ends the flow without answering the page it is on, so it must
  /// not read as the keys page's own skip.
  @Test func skipSetupOnKeysPageWritesNothing() {
    let model = modelOnKeysPage()
    var closed = false
    model.onClose = { closed = true }
    model.skip()
    #expect(closed)
    #expect(model.committed.isEmpty)
  }

  /// A grant that lands after a skip and a step back: the skip already turned
  /// the keys off, so the grant's arrival turns them back on, before any
  /// advance, and Continue adds nothing.
  @Test func aGrantAfterGoingBackRestoresTheKeys() {
    let model = modelOnKeysPage()
    model.skipKeys()
    model.back()
    #expect(model.currentPage == .accessibility)
    model.accessibilityGranted = true
    #expect(model.committed == [.disableKeyboardControl, .restoreKeyboardControl])
    #expect(!model.keysDeclined)
    model.advance()
    #expect(model.committed == [.disableKeyboardControl, .restoreKeyboardControl])
  }

  /// The grant can land after the person has moved on (the guide was still up).
  @Test func aGrantOnALaterPageAfterASkipRestoresTheKeys() {
    let model = modelOnKeysPage()
    model.skipKeys()
    #expect(model.currentPage != .accessibility)
    model.accessibilityGranted = true
    #expect(model.committed == [.disableKeyboardControl, .restoreKeyboardControl])
  }

  /// Skip Setup commits nothing of its own, so the restore must already have
  /// happened by the time the granted page offers it.
  @Test func skipSetupAfterAGrantedSkipLeavesTheKeysRestored() {
    let model = modelOnKeysPage()
    var closed = false
    model.onClose = { closed = true }
    model.skipKeys()
    model.back()
    model.accessibilityGranted = true
    model.skip()
    #expect(closed)
    #expect(model.committed == [.disableKeyboardControl, .restoreKeyboardControl])
  }

  /// Revoked and granted again, then advanced through the granted page: one
  /// restore for one disable.
  @Test func theRestoreIsCommittedOnce() {
    let model = modelOnKeysPage()
    model.skipKeys()
    model.accessibilityGranted = true
    model.accessibilityGranted = false
    model.accessibilityGranted = true
    model.back()
    model.advance()
    #expect(model.committed == [.disableKeyboardControl, .restoreKeyboardControl])
  }

  /// A grant with no skip behind it has nothing to restore.
  @Test func aGrantWithoutASkipRestoresNothing() {
    let model = modelOnKeysPage()
    model.accessibilityGranted = true
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// Skip, Back, skip again is one decision. A second disable would also
  /// re-snapshot already-disabled modes in the live leg.
  @Test func skipBackSkipCommitsTheDisableOnce() {
    let model = modelOnKeysPage()
    model.skipKeys()
    model.back()
    model.skipKeys()
    #expect(model.committed == [.disableKeyboardControl])
    #expect(model.keysDeclined)
  }

  /// A restore closes the decision, so a skip after it is a new one.
  @Test func aSkipAfterARestoreDisablesAgain() {
    let model = modelOnKeysPage()
    model.skipKeys()
    model.back()
    model.accessibilityGranted = true
    model.advance()
    model.back()
    model.accessibilityGranted = false
    model.skipKeys()
    #expect(model.committed
      == [.disableKeyboardControl, .restoreKeyboardControl, .disableKeyboardControl])
  }

  @Test func theGrantedBodyPluralizesLikeTheSkip() {
    #expect(OnboardingKeysCopy.grantedBody(externalDisplayCount: 0)
      == "Your keyboard's brightness and volume keys now control your external display.")
    #expect(OnboardingKeysCopy.grantedBody(externalDisplayCount: 1)
      == "Your keyboard's brightness and volume keys now control your external display.")
    #expect(OnboardingKeysCopy.grantedBody(externalDisplayCount: 2)
      == "Your keyboard's brightness and volume keys now control your external displays.")
  }

  /// The page's presence is latched, so it outlives the last external display
  /// unplugging mid-flow. It must still read correctly and still answer.
  @Test func theKeysPageSurvivesTheLastDisplayLeavingAndStillSkips() {
    let model = modelOnKeysPage()
    model.update(environment: environment([]))
    #expect(model.currentPage == .accessibility)
    let count = model.environment.displays.count
    #expect(count == 0)
    #expect(OnboardingKeysCopy.skipLabel(externalDisplayCount: count)
      == "Skip: my keys won't control my monitor")
    #expect(!OnboardingKeysCopy.body(externalDisplayCount: count).contains("MAG"))
    model.skipKeys()
    #expect(model.committed == [.disableKeyboardControl])
  }

  @Test func theSkipLabelPluralizesFromTwoExternalDisplays() {
    #expect(OnboardingKeysCopy.skipLabel(externalDisplayCount: 0)
      == "Skip: my keys won't control my monitor")
    #expect(OnboardingKeysCopy.skipLabel(externalDisplayCount: 1)
      == "Skip: my keys won't control my monitor")
    #expect(OnboardingKeysCopy.skipLabel(externalDisplayCount: 2)
      == "Skip: my keys won't control my monitors")
    #expect(OnboardingKeysCopy.skipLabel(externalDisplayCount: 3)
      == "Skip: my keys won't control my monitors")
  }

  /// The drop adds Candela already switched on (measured on 27.2), so the
  /// caption asks for the drag alone and names the pane per macOS version.
  @Test func theWaitingCaptionNamesThePaneAndAsksOnlyForTheDrag() {
    let renamed = OnboardingKeysCopy.waitingCaption(macOSMajor: 27)
    #expect(renamed == "Drag \(AppInfo.productName) into the list in "
      + "System Settings > Privacy & Security > Device Control and Data Access. "
      + "This page updates on its own.")
    #expect(OnboardingKeysCopy.waitingCaption(macOSMajor: 15)
      .contains("System Settings > Privacy & Security > Accessibility."))
    #expect(!renamed.contains("switch it on"))
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

  // MARK: - Telemetry prefill (default first run, stored pref after)

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
    // Untouched by the user, so it returns protected as well as designated.
    #expect(model.careEnabled.contains("dell"))
    model.advance()
    #expect(model.committed.isEmpty)
  }

  /// The care page's toggle leaves the display designated, so absence from
  /// `careEnabled` is the only trace of the decision. A reconfiguration while
  /// the window is up must not reseed the toggle and enroll a display the user
  /// has just declined.
  @Test func aProtectionOffSurvivesATopologyTick() {
    let displays = [entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true)]
    let model = OnboardingFlowModel(environment: environment(displays, firstRun: false))
    walk(model, to: .oledCare)
    model.careEnabled.remove("mag")
    model.update(environment: environment(displays, firstRun: false))
    #expect(!model.careEnabled.contains("mag"))
    #expect(model.designatedOleds == ["mag"])
    model.advance()
    #expect(model.committed == [.unenrollFromCare(displayKey: "mag")])
  }

  /// An explicit protection-off survives a departure round trip, the same way
  /// a designation deselect does. Only a toggle the user never touched is
  /// reseeded on return.
  @Test func aProtectionOffSurvivesADepartureAndReturn() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      entry(key: "dell", productName: "DELL OLED", enrolled: true),
    ]
    let model = OnboardingFlowModel(environment: environment(both, firstRun: false))
    walk(model, to: .oledCare)
    model.careEnabled.remove("dell")
    model.update(environment: environment([both[0]], firstRun: false))
    model.update(environment: environment(both, firstRun: false))
    // Designated again, so the user can still change their mind on the page,
    // but protection stays off and the advance un-enrolls it.
    #expect(model.designatedOleds == ["mag", "dell"])
    #expect(!model.careEnabled.contains("dell"))
    model.advance()
    #expect(model.committed == [
      .unenrollFromCare(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
    ])
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

  /// A guess-only designation has nothing on disk to restore it, so the
  /// re-harvest re-runs the guess for displays new to the snapshot.
  @Test func aNameGuessDesignationSurvivesADepartureAndReturn() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]
    let model = OnboardingFlowModel(environment: environment(both))
    walk(model, to: .oledSelect)
    #expect(model.designatedOleds == ["mag"])
    model.update(environment: environment([both[1]]))
    #expect(model.designatedOleds.isEmpty)
    model.update(environment: environment(both))
    #expect(model.designatedOleds == ["mag"])
    // Untouched by the user, so protection comes back on with it.
    #expect(model.careEnabled.contains("mag"))
    #expect(model.pages.contains(.oledCare))
    // Nothing was enrolled on disk, so the round trip writes nothing.
    model.advance()
    #expect(model.committed.isEmpty)
  }

  @Test func aDeselectedNameGuessStaysDeselectedAcrossAReplug() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]
    let model = OnboardingFlowModel(environment: environment(both))
    walk(model, to: .oledSelect)
    model.designatedOleds.remove("mag")
    model.careEnabled.remove("mag")
    model.update(environment: environment([both[1]]))
    model.update(environment: environment(both))
    #expect(model.designatedOleds.isEmpty)
    #expect(!model.careEnabled.contains("mag"))
    #expect(!model.pages.contains(.oledCare))
    model.advance()
    #expect(model.committed.isEmpty)
  }

  @Test func aReplugNeverDesignatesANonOledUnenrolledDisplay() {
    let both = [
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]
    let model = OnboardingFlowModel(environment: environment(both))
    walk(model, to: .oledSelect)
    model.update(environment: environment([both[0]]))
    model.update(environment: environment(both))
    #expect(model.designatedOleds == ["mag"])
    #expect(!model.careEnabled.contains("dell"))
  }

  /// A first-time arrival lands preselected, same as if it had been attached
  /// when the window opened.
  @Test func anOledNamedDisplayArrivingMidFlowIsDesignated() {
    let model = OnboardingFlowModel(environment: environment([entry(key: "dell")]))
    walk(model, to: .oledSelect)
    #expect(model.designatedOleds.isEmpty)
    model.update(environment: environment([
      entry(key: "dell"),
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
    ]))
    #expect(model.designatedOleds == ["mag"])
    #expect(model.careEnabled.contains("mag"))
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

  // MARK: - Enrollment ahead of the Screen Recording request

  /// Granting Screen Recording can relaunch the app before the care page is
  /// advanced past, so the page's choices must already be on disk when the
  /// request goes out.
  @Test func requestCommitsEnrollmentFirst() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    var log: [String] = []
    model.onCommit = { log.append("\($0)") }
    model.onRequestScreenRecording = { log.append("request") }
    model.requestScreenRecording()
    #expect(log == [
      "\(OnboardingCommit.enrollInCare(displayKey: "dell"))",
      "\(OnboardingCommit.enableMeasuredTelemetry(displayKey: "dell"))",
      "\(OnboardingCommit.enrollInCare(displayKey: "mag"))",
      "\(OnboardingCommit.enableMeasuredTelemetry(displayKey: "mag"))",
      "request",
    ])
  }

  /// The care page's Continue requests and advances in one click, so an
  /// unchanged page must not write everything a second time.
  @Test func advanceAfterRequestDoesNotRepeat() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "dell"),
      .enableMeasuredTelemetry(displayKey: "dell"),
      .enrollInCare(displayKey: "mag"),
      .enableMeasuredTelemetry(displayKey: "mag"),
    ])
  }

  /// A first run's harvest says the display was never enrolled, but the
  /// request enrolled it, so turning it off afterwards is an un-enrollment.
  @Test func changeAfterRequestStillCommits() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.careEnabled.remove("mag")
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .unenrollFromCare(displayKey: "mag")
    ])
  }

  /// Same baseline for the measurement choice: the request wrote measured, so
  /// estimated afterwards turns it back off even on a first run.
  @Test func estimatedAfterRequestTurnsMeasurementBackOff() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.measuredTelemetry = false
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .disableMeasuredTelemetry(displayKey: "mag")
    ])
  }

  /// The deselect takes the care page out of the plan, so the designation
  /// page's arm is the only one left to undo what the request enrolled.
  @Test func aDeselectAfterTheRequestUnenrolls() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.back()
    #expect(model.currentPage == .oledSelect)
    model.designatedOleds.remove("mag")
    #expect(!model.pages.contains(.oledCare))
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .unenrollFromCare(displayKey: "mag")
    ])
  }

  /// Turning protection back on after the request had it off re-enrolls.
  @Test func reenablingAfterTheRequestEnrollsAgain() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.careEnabled.remove("mag")
    model.requestScreenRecording()
    #expect(model.committed.isEmpty)
    model.careEnabled.insert("mag")
    model.advance()
    #expect(model.committed == [
      .enrollInCare(displayKey: "mag"),
      .enableMeasuredTelemetry(displayKey: "mag"),
    ])
  }

  /// A re-run's harvest already says enrolled and measured, so the request's
  /// re-affirming writes must not turn the later off path into two writes.
  @Test func aReRunRequestThenEstimatedWritesOneDisable() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(
        key: "mag", productName: "MAG 341CQPX QD-OLED",
        enrolled: true, measuredTelemetry: true)],
      firstRun: false))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.measuredTelemetry = false
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .disableMeasuredTelemetry(displayKey: "mag")
    ])
  }

  @Test func aReRunRequestThenToggleOffWritesOneUnenroll() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(
        key: "mag", productName: "MAG 341CQPX QD-OLED",
        enrolled: true, measuredTelemetry: true)],
      firstRun: false))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.careEnabled.remove("mag")
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .unenrollFromCare(displayKey: "mag")
    ])
  }

  /// The live topology loop can re-harvest between the request and the
  /// advance, and that harvest reads the prefs the request just wrote.
  @Test func aReharvestBetweenRequestAndAdvanceRepeatsNothing() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.update(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED", enrolled: true, measuredTelemetry: true),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true, measuredTelemetry: true),
      ]))
    #expect(model.currentPage == .oledCare)
    model.advance()
    #expect(model.committed.count == afterRequest)
  }

  /// A harvest that has not caught up with the request's writes must not make
  /// a later toggle-off look like a display that was never enrolled.
  @Test func aStaleReharvestBetweenRequestAndAdvanceLosesNothing() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.update(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    model.careEnabled.remove("mag")
    model.advance()
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .unenrollFromCare(displayKey: "mag")
    ])
  }

  @Test func aRequestOffTheCarePageCommitsNothing() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledSelect)
    model.requestScreenRecording()
    #expect(model.committed.isEmpty)
  }

  // MARK: - Resuming after the Screen Recording relaunch

  /// The relaunch can land the instant the grant is switched on, so the marker
  /// has to be on disk before the ask goes out, and after the care page's
  /// choices it promises are already written.
  @Test func requestWritesTheResumeMarkerBetweenTheCareCommitAndTheAsk() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    var log: [String] = []
    model.onCommit = { log.append("\($0)") }
    model.onSetResumeAfterCare = { log.append("resume \($0)") }
    model.onRequestScreenRecording = { log.append("request") }
    model.requestScreenRecording()
    #expect(log == [
      "\(OnboardingCommit.enrollInCare(displayKey: "mag"))",
      "\(OnboardingCommit.enableMeasuredTelemetry(displayKey: "mag"))",
      "resume true",
      "request",
    ])
  }

  /// Off the care page nothing was committed early, so a resume would skip
  /// pages whose choices were never written.
  @Test func aRequestOffTheCarePageWritesNoResumeMarker() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledSelect)
    var marks: [Bool] = []
    model.onSetResumeAfterCare = { marks.append($0) }
    model.requestScreenRecording()
    #expect(marks.isEmpty)
  }

  @Test func closingClearsTheResumeMarker() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    var marks: [Bool] = []
    model.onSetResumeAfterCare = { marks.append($0) }
    model.requestScreenRecording()
    model.didClose()
    #expect(marks == [true, false])
  }

  /// A marker left by an earlier process is this flow's to clear as well, so
  /// the clear does not depend on this flow having made the request.
  @Test func closingClearsTheResumeMarkerWithoutARequest() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    var marks: [Bool] = []
    model.onSetResumeAfterCare = { marks.append($0) }
    model.didClose()
    #expect(marks == [false])
  }

  /// The relaunched app re-harvests: the request enrolled the display, so the
  /// fresh plan still has a care page, and the flow opens on the page after it.
  @Test func resumeStartsAfterCare() throws {
    let model = OnboardingFlowModel(environment: environment(
      [entry(
        key: "mag", productName: "MAG 341CQPX QD-OLED",
        enrolled: true, measuredTelemetry: true)]))
    model.resumeAfterCare()
    let care = try #require(model.pages.firstIndex(of: .oledCare))
    #expect(model.index == care + 1)
    #expect(model.currentPage == .finish)
    #expect(model.committed.isEmpty)
  }

  /// The OLED was unplugged across the relaunch (or the care page was turned
  /// off for a display nothing guesses is an OLED): no care page to follow.
  @Test func resumeWithNoCarePageStartsAtFinish() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "dell", suggestion: suggestion)]))
    #expect(!model.pages.contains(.oledCare))
    model.resumeAfterCare()
    #expect(model.currentPage == .finish)
    #expect(model.committed.isEmpty)
  }

  /// Back from the resumed page shows the care page again. It must show what
  /// was written before the relaunch, not the fresh-flow seeds, or Continue
  /// would re-enroll a declined display and turn measurement back on.
  @Test func aResumedFlowShowsTheCareChoicesAlreadyWritten() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(
          key: "mag", productName: "MAG 341CQPX QD-OLED",
          enrolled: true, measuredTelemetry: false),
      ]))
    model.resumeAfterCare()
    #expect(model.careEnabled == ["mag"])
    #expect(!model.measuredTelemetry)
    model.back()
    #expect(model.currentPage == .oledCare)
    model.advance()
    #expect(!model.committed.contains(.enrollInCare(displayKey: "dell")))
    #expect(!model.committed.contains(.enableMeasuredTelemetry(displayKey: "mag")))
  }

  /// A relaunch can land before Continue, so an edit after the request is
  /// written as it is made, through the same record, once.
  @Test func anEditAfterTheRequestIsCommittedWithoutContinue() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell", productName: "DELL OLED"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      ]))
    walk(model, to: .oledCare)
    model.requestScreenRecording()
    let afterRequest = model.committed.count
    model.careEnabled.remove("dell")
    model.measuredTelemetry = false
    // Re-asserting a choice already written writes nothing.
    model.measuredTelemetry = false
    model.careEnabled.remove("dell")
    #expect(Array(model.committed.dropFirst(afterRequest)) == [
      .unenrollFromCare(displayKey: "dell"),
      .disableMeasuredTelemetry(displayKey: "mag"),
    ])
    model.advance()
    #expect(model.committed.count == afterRequest + 2)
  }

  /// Without an outstanding request the care page keeps commit-on-advance:
  /// nothing can relaunch the app under it.
  @Test func anEditBeforeTheRequestWaitsForContinue() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")]))
    walk(model, to: .oledCare)
    model.measuredTelemetry = false
    model.careEnabled.remove("mag")
    model.careEnabled.insert("mag")
    #expect(model.committed.isEmpty)
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

  // MARK: - Behaviours that must not regress

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

  // MARK: - Finish: what to fine-tune

  /// Opening an item is Finish's own advance plus a destination: launch at
  /// login is committed, the window closes, and only then does Settings open,
  /// so Settings never comes up behind a Setup window still on screen.
  @Test func openingAnItemCommitsFinishFirst() {
    let model = OnboardingFlowModel(environment: environment([entry(key: "dell")]))
    var log: [String] = []
    model.onCommit = { log.append("commit \($0)") }
    // The window's close handling reads this to skip the first-run callout,
    // so it must already be set when the close arrives.
    model.onClose = { log.append("close into settings \(model.closesIntoSettings)") }
    model.onOpenSettings = { log.append("open \($0)") }
    walk(model, to: .finish)
    log.removeAll()
    model.finish(opening: .checkup)
    #expect(log == [
      "commit \(OnboardingCommit.setLaunchAtLogin(true))",
      "close into settings true",
      "open \(SettingsDestination.pane(.checkup))",
    ])
  }

  /// Start Using closes into nothing, so the first-run callout still shows.
  @Test func finishingWithoutAnItemDoesNotCloseIntoSettings() {
    let model = OnboardingFlowModel(environment: environment([entry(key: "dell")]))
    var closedIntoSettings: Bool?
    model.onClose = { closedIntoSettings = model.closesIntoSettings }
    walk(model, to: .finish)
    model.advance()
    #expect(closedIntoSettings == false)
  }

  /// Off Finish there is nothing to open from, and an item must not ride a
  /// page's advance as though it were Continue.
  @Test func openingAnItemOffFinishDoesNothing() {
    let model = OnboardingFlowModel(environment: environment([entry(key: "dell")]))
    var opened: [SettingsDestination] = []
    model.onOpenSettings = { opened.append($0) }
    let start = model.index
    model.finish(opening: .checkup)
    #expect(opened.isEmpty)
    #expect(model.committed.isEmpty)
    #expect(model.index == start)
  }

  /// The rig walked straight through: the guessed OLED protected, the grant
  /// given on the keys page, two externals plus the built-in.
  @Test func aGrantedRigIsOfferedEveryItem() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED"),
      entry(key: "dell"),
    ]))
    walk(model, to: .accessibility)
    model.accessibilityGranted = true
    walk(model, to: .finish)
    #expect(model.keyboardControlOn)
    #expect(model.fineTuneItems == [.oledCare, .shortcuts, .checkup, .arrangement])
  }

  /// The keys page's skip turns the keys off, and Finish follows it: no
  /// shortcuts to review, and the summary says the keys are off.
  @Test func aKeysSkipDropsTheShortcutsItem() {
    let model = modelOnKeysPage()
    model.skipKeys()
    walk(model, to: .finish)
    #expect(!model.keyboardControlOn)
    #expect(!model.fineTuneItems.contains(.shortcuts))
    #expect(model.fineTuneItems.contains(.checkup))
  }

  @Test func skippingAccessKeepsTheCustomShortcutsThatNeedNoGrant() {
    var snapshot = environment([entry(key: "dell")])
    snapshot.keyModesHaveCustomShortcuts = true
    let model = OnboardingFlowModel(environment: snapshot)
    walk(model, to: .accessibility)
    model.skipKeys()
    // The skip removed the media-key half, leaving custom shortcuts enabled.
    snapshot.keyModesRequireGrant = false
    model.update(environment: snapshot)
    walk(model, to: .finish)
    #expect(model.keyboardControlOn)
    #expect(model.keysGrantInPlace)
    #expect(model.fineTuneItems.contains(.shortcuts))
  }

  @Test func grantingAfterASkipRestoresTheOriginalMixedModes() {
    var snapshot = environment([entry(key: "dell")])
    snapshot.keyModesHaveCustomShortcuts = true
    let model = OnboardingFlowModel(environment: snapshot)
    walk(model, to: .accessibility)
    model.skipKeys()
    model.accessibilityGranted = true
    #expect(!model.keysDeclined)
    #expect(model.keyboardControlOn)
    #expect(model.keysGrantInPlace)
    #expect(model.committed.contains(.restoreKeyboardControl))
  }

  /// A skip undone by a later grant puts the keys back, so the item returns.
  @Test func aGrantAfterASkipBringsTheShortcutsItemBack() {
    let model = modelOnKeysPage()
    model.skipKeys()
    model.accessibilityGranted = true
    walk(model, to: .finish)
    #expect(model.keyboardControlOn)
    #expect(model.fineTuneItems.contains(.shortcuts))
  }

  /// After the skip, a re-harvest reads the disable this flow wrote. It must
  /// not outlive the restore: once the grant has put the modes back, the keys
  /// are on even though that harvest said otherwise.
  @Test func aReharvestOfTheSkipsOwnWriteDoesNotOutliveTheRestore() {
    let model = modelOnKeysPage()
    model.skipKeys()
    // What the default all-media modes read as after the skip: both disabled.
    model.update(environment: environment(
      [entry(key: "mag", productName: "MAG 341CQPX QD-OLED")],
      keyModesRequireGrant: false, keyModesOff: true))
    #expect(!model.keyboardControlOn)
    model.accessibilityGranted = true
    #expect(model.keyboardControlOn)
    #expect(model.keysGrantInPlace)
  }

  /// With no skip of this flow's outstanding, the harvest is the stored
  /// modes' own answer: both families set to nothing in Settings mid-flow read
  /// as off.
  @Test func aReharvestWithBothModesDisabledElsewhereReadsOff() {
    let model = OnboardingFlowModel(environment: environment(
      [entry(key: "dell")], accessibilityGranted: true))
    #expect(model.keyboardControlOn)
    model.update(environment: environment(
      [entry(key: "dell")], accessibilityGranted: true,
      keyModesRequireGrant: false, keyModesOff: true))
    #expect(!model.keyboardControlOn)
    walk(model, to: .finish)
    #expect(!model.fineTuneItems.contains(.shortcuts))
  }

  /// Switching to custom shortcuts mid-flow is not turning the keys off: they
  /// need no grant, so they read as ready with or without one.
  @Test func aReharvestToAllCustomReadsOn() {
    let model = OnboardingFlowModel(environment: environment([entry(key: "dell")]))
    model.update(environment: environment([entry(key: "dell")], keyModesRequireGrant: false))
    #expect(model.keyboardControlOn)
    #expect(model.keysGrantInPlace)
  }

  /// All custom shortcuts, granted or not: Carbon hotkeys need no grant, so the
  /// keys are ready and the shortcuts are worth reviewing. The control is the
  /// default all-media rig skipping the keys page, which reads off.
  @Test func anAllCustomRigIsReadyAndOffersItsShortcuts() {
    for granted in [false, true] {
      let model = OnboardingFlowModel(environment: environment(
        [entry(key: "dell")], accessibilityGranted: granted, keyModesRequireGrant: false))
      walk(model, to: .finish)
      #expect(model.fineTuneItems.contains(.shortcuts), "granted \(granted)")
      #expect(
        OnboardingFinishCopy.keysLine(
          keysOn: model.keyboardControlOn, grantInPlace: model.keysGrantInPlace
        ).text == OnboardingFinishCopy.keysReady, "granted \(granted)")
    }
    let skipped = modelOnKeysPage()
    skipped.skipKeys()
    walk(skipped, to: .finish)
    #expect(!skipped.fineTuneItems.contains(.shortcuts))
    #expect(
      OnboardingFinishCopy.keysLine(
        keysOn: skipped.keyboardControlOn, grantInPlace: skipped.keysGrantInPlace
      ).text == OnboardingFinishCopy.keysOff)
  }

  /// The whole table, one row per stored-mode case, read where Finish reads it.
  @Test func theKeysLineAndShortcutsItemFollowTheStoredModes() {
    struct Row {
      var granted: Bool, needsGrant: Bool, off: Bool
      var line: String, offersShortcuts: Bool
    }
    let rows = [
      // Media keys on, no grant.
      Row(granted: false, needsGrant: true, off: false,
          line: OnboardingFinishCopy.keysAwaitAccess, offersShortcuts: false),
      // Media keys on, granted.
      Row(granted: true, needsGrant: true, off: false,
          line: OnboardingFinishCopy.keysReady, offersShortcuts: true),
      // Both modes disabled (a resumed default skip, or set so in Settings).
      Row(granted: false, needsGrant: false, off: true,
          line: OnboardingFinishCopy.keysOff, offersShortcuts: false),
      Row(granted: true, needsGrant: false, off: true,
          line: OnboardingFinishCopy.keysOff, offersShortcuts: false),
    ]
    for row in rows {
      // No external, so no keys page: the rows read the stored modes alone,
      // and the skip's own rows are the tests above.
      let model = OnboardingFlowModel(environment: environment(
        [], accessibilityGranted: row.granted,
        keyModesRequireGrant: row.needsGrant, keyModesOff: row.off))
      walk(model, to: .finish)
      #expect(
        OnboardingFinishCopy.keysLine(
          keysOn: model.keyboardControlOn, grantInPlace: model.keysGrantInPlace
        ).text == row.line, "\(row.granted) \(row.needsGrant) \(row.off)")
      #expect(
        model.fineTuneItems.contains(.shortcuts) == row.offersShortcuts,
        "\(row.granted) \(row.needsGrant) \(row.off)")
    }
  }

  /// A flow resumed after the relaunch lands on Finish without passing the
  /// keys or care pages in this process. The list comes from the harvest: the
  /// enrolled OLED, and keys a previous skip left off in the stored modes.
  @Test func aResumedFlowDerivesItsItemsFromCurrentState() {
    let model = OnboardingFlowModel(environment: environment(
      [
        entry(key: "dell"),
        entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
      ],
      // The default all-media modes after the previous process's skip.
      accessibilityGranted: false, keyModesRequireGrant: false, keyModesOff: true))
    model.resumeAfterCare()
    #expect(model.currentPage == .finish)
    #expect(model.fineTuneItems == [.oledCare, .checkup, .arrangement])
    #expect(
      OnboardingFinishCopy.keysLine(
        keysOn: model.keyboardControlOn, grantInPlace: model.keysGrantInPlace
      ).text == OnboardingFinishCopy.keysOff)
  }

  /// The resumed flow's protection count is what the previous process wrote:
  /// a guessed OLED the person turned off is not counted as protected.
  @Test func aResumedFlowCountsOnlyTheEnrolledOled() {
    let model = OnboardingFlowModel(environment: environment([
      entry(key: "dell", productName: "DELL OLED"),
      entry(key: "mag", productName: "MAG 341CQPX QD-OLED", enrolled: true),
    ]))
    model.resumeAfterCare()
    #expect(model.protectedOledCount == 1)
  }

  /// Built-in only: nothing about displays to tune, and with the grant live
  /// the shortcuts are all that is left.
  @Test func aBuiltInOnlyFlowOffersOnlyTheShortcuts() {
    let model = OnboardingFlowModel(environment: OnboardingEnvironment(
      accessibilityGranted: true, loginItemEnabled: false, isFirstRun: true,
      keyModesRequireGrant: true, arrangedDisplayCount: 1, displays: []))
    walk(model, to: .finish)
    #expect(model.fineTuneItems == [.shortcuts])
  }

  /// The list can go from empty to not while Finish is up: built-in only with
  /// the grant still out offers nothing, and the grant landing there adds the
  /// shortcuts. The page's reveal has to let that show.
  @Test func theListCanGainAnItemWhileFinishShows() {
    let model = OnboardingFlowModel(environment: OnboardingEnvironment(
      accessibilityGranted: false, loginItemEnabled: false, isFirstRun: true,
      keyModesRequireGrant: true, arrangedDisplayCount: 1, displays: []))
    walk(model, to: .finish)
    #expect(model.fineTuneItems.isEmpty)
    model.accessibilityGranted = true
    #expect(model.fineTuneItems == [.shortcuts])
  }
}
