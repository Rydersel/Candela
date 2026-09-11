import CandelaKit
import Foundation
import Testing

/// The testable surface of a VoiceOver announcement is the DECISION, never the
/// utterance: what text, on which transition, at which threshold. Nothing here
/// can assert that a posted announcement was spoken, so that stays a person's
/// check with VoiceOver on.
@MainActor
@Suite("Guided flow announcements")
struct GuidedFlowAnnouncementTests {

  /// Associated values rule out `CaseIterable`, so this list is hand-maintained
  /// and a new page has to be added here too. What it proves is that each arm of
  /// `pageAnnouncement` produces something a person can hear.
  private static let checkupPages: [CheckupPage] = {
    var pages: [CheckupPage] = [
      .scenario, .displayPick, .plan, .identity, .capabilities, .nativeMode, .refresh,
      .witness, .plantDisclosure, .hdr, .summary,
    ]
    for kind in CheckupFieldKind.allCases {
      pages += [.fieldInstruction(kind), .fieldShowing(kind), .fieldConfirmSecondDot(kind)]
    }
    return pages
  }()

  private static let setupPages: [OnboardingPage] = [
    .welcome, .accessibility, .detection, .noDisplays, .size(displayKey: sizePageKey),
    .oledSelect, .oledCare, .finish,
  ]
  /// Shaped like a real persistence key, so an announcement that leaked one
  /// would be caught by the same assertion that catches a bare display id.
  private static let sizePageKey = "DIS-3669-3dd0-0"

  @Test func everyCheckupPageHasAnAnnouncementAndNoneOfThemSpeaksAStorageKey() {
    for page in Self.checkupPages {
      let text = CheckupCopy.pageAnnouncement(page)
      #expect(!text.isEmpty, "\(page)")
      #expect(!text.contains("—"), "\(page)")
      // Raw values that are ordinary words ("black") are skipped, the same
      // exemption `CheckupPage.name` is tested under; `gray7` is not one.
      for kind in CheckupFieldKind.allCases
      where !CheckupCopy.fieldName(kind).contains(kind.rawValue) {
        #expect(!text.contains(kind.rawValue), "\(page) speaks \(kind.rawValue)")
      }
    }
  }

  /// A field passes through three pages and a person has to hear which one they
  /// landed on. `CheckupPage.name` gives all three the same words.
  @Test func theThreeStagesOfAFieldDoNotShareOneAnnouncement() {
    for kind in CheckupFieldKind.allCases {
      let stages = [
        CheckupCopy.pageAnnouncement(.fieldInstruction(kind)),
        CheckupCopy.pageAnnouncement(.fieldShowing(kind)),
        CheckupCopy.pageAnnouncement(.fieldConfirmSecondDot(kind)),
      ]
      #expect(Set(stages).count == 3, "\(kind)")
      // The control: the three DO all name the field, so distinctness above
      // cannot be met by dropping the subject.
      for stage in stages {
        #expect(stage.contains(CheckupCopy.shortFieldName(kind)), "\(kind)")
      }
    }
  }

  @Test func everySetupPageHasAnAnnouncementCarryingItsStepPosition() {
    let total = Self.setupPages.count
    for (offset, page) in Self.setupPages.enumerated() {
      let text = OnboardingAnnouncements.pageAnnouncement(page, step: offset + 1, of: total)
      #expect(!text.isEmpty, "\(page)")
      #expect(!text.contains("—"), "\(page)")
      #expect(text.contains("Step \(offset + 1) of \(total)"), "\(page)")
      #expect(!text.contains(Self.sizePageKey), "\(page) speaks a persistence key")
      // `OnboardingPage.id` is storage, and the camel-cased ones are unmistakable
      // as keys: nothing written for a person spells "oledSelect".
      if page.id.rangeOfCharacter(from: .uppercaseLetters) != nil {
        #expect(!text.contains(page.id), "\(page) speaks its id")
      }
    }
    #expect(
      OnboardingAnnouncements.pageAnnouncement(.oledSelect, step: 3, of: 7)
        .contains("Step 3 of 7"))
  }

  /// A size page names the display it is about, because several of them can
  /// follow each other and "this display" would not tell them apart.
  @Test func aSizePageSpeaksTheDisplaysNameWhenItHasOne() {
    let named = OnboardingAnnouncements.pageAnnouncement(
      .size(displayKey: Self.sizePageKey), step: 3, of: 8, displayName: "MAG 341C OLED")
    #expect(named.contains("MAG 341C OLED"))
    #expect(!named.contains(Self.sizePageKey))
    let unnamed = OnboardingAnnouncements.pageAnnouncement(
      .size(displayKey: Self.sizePageKey), step: 3, of: 8)
    #expect(!unnamed.isEmpty)
    #expect(!unnamed.contains(Self.sizePageKey))
  }

  @Test func theCountdownSpeaksAtTenAndThreeAndNowhereElse() {
    #expect((0...30).filter { AnnouncementThresholds.speaks(at: $0, cap: 30) } == [3, 10])
  }

  @Test func theWhiteFieldDoesNotAnnounceItsOwnStartingValue() {
    let whiteCap = CheckupFieldKind.white.capSeconds
    #expect(whiteCap == 10, "the trap this guard exists for has moved")
    #expect(AnnouncementThresholds.speaks(at: whiteCap, cap: whiteCap) == false)
    #expect(AnnouncementThresholds.speaks(at: 3, cap: whiteCap))
    // The control: every other field opens at 20, so 10 is a real threshold
    // there and the guard must not swallow it.
    #expect(AnnouncementThresholds.speaks(at: 10, cap: CheckupFieldKind.black.capSeconds))
    // Same for the setup countdown, whose cap is the model's own.
    #expect(AnnouncementThresholds.speaks(at: 10, cap: OnboardingFlowModel.applyCountdownSeconds))
  }

  /// The spoken countdown IS the drawn countdown. Two spellings of one number
  /// would be two things to keep true.
  @Test func theSpokenCountdownIsTheDrawnCountdown() {
    #expect(
      OnboardingSizePage.countdownAnnouncement(seconds: 3, canKeep: true, cap: 15)
        == OnboardingSizePage.countdownCaption(seconds: 3, canKeep: true))
    #expect(
      OnboardingSizePage.countdownAnnouncement(seconds: 10, canKeep: false, cap: 15)
        == OnboardingSizePage.countdownCaption(seconds: 10, canKeep: false))
    #expect(OnboardingSizePage.countdownAnnouncement(seconds: 9, canKeep: true, cap: 15) == nil)
    #expect(OnboardingSizePage.countdownAnnouncement(seconds: 10, canKeep: true, cap: 10) == nil)

    #expect(CheckupCopy.secondsLeftAnnouncement(seconds: 3, cap: 20) == CheckupCopy.secondsLeft(3))
    #expect(CheckupCopy.secondsLeftAnnouncement(seconds: 10, cap: 20) == CheckupCopy.secondsLeft(10))
    #expect(CheckupCopy.secondsLeftAnnouncement(seconds: 9, cap: 20) == nil)
    #expect(CheckupCopy.secondsLeftAnnouncement(seconds: 10, cap: 10) == nil)
  }

  /// The keep and revert bar is the one place in either flow where the cursor
  /// lands on a button instead of a heading, so everything it draws has to be
  /// spoken or a listener gets "Keep, button" and no deadline. Which transition
  /// calls which of these is the view's own arms, and only a person with
  /// VoiceOver can confirm that wiring.
  @Test func theBarSpeaksItsCountdownWhenItArrives() {
    #expect(
      OnboardingSizePage.barAnnouncement(seconds: 15, achieved: nil)
        == OnboardingSizePage.countdownCaption(seconds: 15, canKeep: true))
    #expect(!OnboardingSizePage.barAnnouncement(seconds: 15, achieved: nil).contains("\u{2014}"))
  }

  /// A diverged commit takes Keep away, and the recovery instruction and the
  /// achieved size are the only route out. Neither reaches a cursor on Revert.
  @Test func aDivergedCommitSpeaksTheRecoveryTextAndTheAchievedSize() {
    let achieved = OnboardingAchievedSize.size(width: 2560, height: 1440, refreshHz: 60)
    let text = OnboardingSizePage.divergenceAnnouncement(achieved)
    #expect(text.contains(DisplayModeCopy.recoveryInstruction(dialect: .size)))
    #expect(text.contains(ModeSpeech.spoken(logicalWidth: 2560, logicalHeight: 1440, refreshHz: 60)))
    // The drawn caption's times sign and "Hz" are read inconsistently, which is
    // why the spoken sentence is not the drawn one here.
    #expect(!text.contains("2560 x 1440"))
    #expect(!text.contains("\u{2014}"))
    #expect(
      OnboardingSizePage.divergenceAnnouncement(.unreadable)
        .contains(DisplayModeCopy.unreadableAchievedGeometry(dialect: .size)))

    // Divergence can also be there before the bar is, and then one announcement
    // carries both the recovery text and the deadline.
    let arriving = OnboardingSizePage.barAnnouncement(seconds: 12, achieved: achieved)
    #expect(arriving.contains(OnboardingSizePage.divergenceAnnouncement(achieved)))
    #expect(arriving.contains(OnboardingSizePage.countdownCaption(seconds: 12, canKeep: false)))
  }

  /// The cursor lands on the page heading a moment after the announcement, so an
  /// announcement made of the heading's words says the transition twice and the
  /// page's purpose once. Every page, not a sample: most arms opened with their
  /// own heading.
  @Test func noCheckupAnnouncementIsBuiltFromItsPagesHeading() {
    for page in Self.checkupPages {
      let text = CheckupCopy.pageAnnouncement(page)
      let heading = Self.checkupHeading(page)
      #expect(!text.hasPrefix(heading), "\(page) opens with its heading")
      #expect(!text.contains(heading), "\(page) speaks its heading")
      // The control: a sentence, not a stub. Dropping the heading is easy to
      // satisfy by saying almost nothing.
      #expect(text.count > 20, "\(page)")
    }
  }

  /// The title each page hands `CheckupPageScaffold`. Written out because the
  /// pairing lives in the views and a host-free test cannot ask one what it
  /// drew; the page list above keeps this exhaustive.
  private static func checkupHeading(_ page: CheckupPage) -> String {
    switch page {
    case .scenario: CheckupCopy.scenarioTitle
    case .displayPick: CheckupCopy.pickTitle
    case .plan: CheckupCopy.planTitle
    case .identity: CheckupCopy.identityTitle
    case .capabilities: CheckupCopy.capabilitiesTitle
    case .nativeMode: CheckupCopy.nativeModeTitle
    case .refresh: CheckupCopy.refreshTitle
    // The witness card's instruction page, which is `.witness` rather than
    // `.fieldInstruction(.witness)`, draws the same heading as one.
    case .witness: CheckupCopy.fieldTitle(.witness)
    case .plantDisclosure: CheckupCopy.plantDisclosureTitle
    case .fieldInstruction(let kind), .fieldShowing(let kind): CheckupCopy.fieldTitle(kind)
    case .fieldConfirmSecondDot: CheckupCopy.secondDotTitle
    case .hdr: CheckupCopy.hdrTitle
    case .summary: CheckupCopy.summaryTitle
    }
  }

  /// The same rule on the setup side, where the welcome and size pages opened
  /// with their headings.
  @Test func noSetupAnnouncementIsBuiltFromItsPagesHeading() {
    let total = Self.setupPages.count
    for (offset, page) in Self.setupPages.enumerated() {
      let text = OnboardingAnnouncements.pageAnnouncement(
        page, step: offset + 1, of: total, displayName: Self.sizePageDisplayName)
      for heading in Self.setupHeadings(page) {
        #expect(!text.hasPrefix(heading), "\(page) opens with \(heading)")
        #expect(!text.contains(heading), "\(page) speaks \(heading)")
      }
      #expect(text.count > 20, "\(page)")
    }
  }

  /// Every title a setup page can draw. The pages draw these same constants, so
  /// a retitled page moves its heading here rather than leaving this list stale.
  private static func setupHeadings(_ page: OnboardingPage) -> [String] {
    switch page {
    case .welcome: [OnboardingTitles.welcome]
    case .accessibility: [OnboardingTitles.accessibility]
    // One page, three headings: the scan's, then the count it flips to once the
    // cards resolve, in both its singular and plural shapes.
    case .detection:
      [OnboardingTitles.detectionScanning, OnboardingTitles.detectionFound(count: 1),
       OnboardingTitles.detectionFound(count: 2)]
    case .noDisplays: [OnboardingTitles.noDisplays]
    case .size: [OnboardingTitles.size(displayName: sizePageDisplayName)]
    case .oledSelect: [OnboardingTitles.oledSelect]
    case .oledCare: [OnboardingTitles.oledCare]
    case .finish: [OnboardingTitles.finish]
    }
  }

  private static let sizePageDisplayName = "MAG 341C OLED"

  /// A divergence and the seconds arrive in one update, so a commit diverging
  /// exactly at 10 or 3 would post both. The deadline interrupts and the
  /// recovery text is the only route out, so that tick says nothing.
  @Test func aTickThatTakesKeepAwayDoesNotSpeakOverTheRecoveryText() {
    for seconds in [10, 3] {
      #expect(
        OnboardingSizePage.countdownAnnouncement(
          seconds: seconds, canKeep: false, cap: 15, divergedThisTick: true) == nil)
      // The control: the same tick over a divergence that was already standing
      // still speaks its deadline, so the suppression is about the arrival.
      #expect(
        OnboardingSizePage.countdownAnnouncement(
          seconds: seconds, canKeep: false, cap: 15, divergedThisTick: false)
          == OnboardingSizePage.countdownCaption(seconds: seconds, canKeep: false))
    }
  }

  /// The detection page announces on arrival, while the scan still runs, and
  /// nothing re-announces when the heading flips to a count. The sentence has to
  /// hold on both sides: no past tense, no number.
  @Test func theDetectionAnnouncementHoldsBeforeTheScanResolves() {
    let text = OnboardingAnnouncements.pageAnnouncement(.detection, step: 2, of: 5)
    let purpose = text.replacingOccurrences(of: " Step 2 of 5.", with: "")
    #expect(purpose != text, "the step position is spelled the way this test strips it")
    #expect(purpose.rangeOfCharacter(from: .decimalDigits) == nil)
    #expect(!purpose.lowercased().contains("were found"))
    #expect(!purpose.lowercased().contains("was found"))
  }

  /// The welcome heading gives up the focus landing only on the flow's opening
  /// frame, where the window becoming key is already speaking its own title.
  /// Coming BACK to welcome lands on the heading like every other page.
  @Test func theWelcomeHeadingKeepsItsFocusLandingOnceTheFlowHasMoved() {
    let model = OnboardingFlowModel(environment: OnboardingFixtures.rig)
    #expect(model.currentPage == .welcome)
    #expect(model.hasNavigated == false)
    model.advance()
    #expect(model.hasNavigated)
    model.back()
    #expect(model.currentPage == .welcome)
    #expect(model.hasNavigated)
  }

  /// The em-dash and no-verdict sweep reads `allStringsForTest`, so an
  /// announcement left out of it is an announcement nothing checks.
  @Test func theCheckupAnnouncementsAreCoveredByTheCopySweep() {
    let sweep = Set(CheckupCopy.allStringsForTest)
    for page in Self.checkupPages {
      #expect(sweep.contains(CheckupCopy.pageAnnouncement(page)), "\(page)")
    }
  }
}
