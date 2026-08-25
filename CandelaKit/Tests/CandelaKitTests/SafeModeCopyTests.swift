import Foundation
import Testing

@testable import CandelaKit

/// #147: two of the three safe-mode summaries named three suppressions while the
/// app performed four. Nothing failed, nothing crashed, and the copy stayed
/// wrong for a milestone, because a sentence in an alert has no other reader.
///
/// These tests are the reader. The load-bearing one is
/// `everySummaryNamesEverySuppression`, which fails on the day a fifth case is
/// added and one surface is left behind. The exact-string tests are here for the
/// same reason as the diagnostics ones: the failure mode is a plausible edit
/// that quietly drops a clause, and it passes any test that only greps for a
/// keyword.
@Suite("Safe mode copy (D11)")
struct SafeModeCopyTests {

  private static let app = "Candela"

  /// The count is asserted, not derived, so growing the enum is a deliberate
  /// act with a failing test attached rather than a silent change to three
  /// user-visible sentences.
  @Test func safeModeSuppressesExactlyFourThings() {
    #expect(SafeModeCopy.Suppression.allCases.count == 4)
    #expect(SafeModeCopy.Suppression.allCases == [.restore, .readback, .quitWrite, .oledCare])
  }

  /// The whole point of the type. A new case with a clause but no summary edit
  /// still reaches all three, and a case somehow skipped by the join fails here
  /// rather than in a screenshot.
  @Test func everySummaryNamesEverySuppression() {
    let summaries = [
      SafeModeCopy.launchNotice(app: Self.app),
      SafeModeCopy.diagnosticsRow(app: Self.app),
      SafeModeCopy.generalPaneCaption(app: Self.app),
    ]
    for summary in summaries {
      for suppression in SafeModeCopy.Suppression.allCases {
        #expect(summary.contains(SafeModeCopy.clause(suppression)))
      }
    }
  }

  /// The restore clause covers five saved things, and the two that #147 found
  /// missing from a summary are resolution's sibling and OLED care. Naming the
  /// arrangement matters because `restoreUnattended()` gates it on the same
  /// line as the stored mode: a user whose layout did not come back gets no
  /// answer from a notice that stops at "resolution".
  @Test func theRestoreClauseNamesEverySavedThingTheSessionWillNotRestore() {
    let clause = SafeModeCopy.clause(.restore)
    for value in ["brightness", "volume", "contrast", "resolution", "arrangement"] {
      #expect(clause.contains(value))
    }
    // The launch notice used to omit it while the General pane said it.
    #expect(clause.contains("at startup or wake"))
  }

  /// OLED care is the most VISIBLE thing safe mode turns off, and the pane note
  /// that already disclosed it names three effects, not one. A clause that said
  /// only "dim" would leave a reader waiting on measurements that cannot come.
  @Test func theOledCareClauseNamesAllThreeEffectsNotJustDimming() {
    let clause = SafeModeCopy.clause(.oledCare)
    #expect(clause.contains("dim any display"))
    #expect(clause.contains("count hours of use"))
    #expect(clause.contains("take any measurements"))
  }

  @Test func theSuppressionSentenceReadsAsOneList() {
    #expect(
      SafeModeCopy.suppressions(app: Self.app)
        == "Candela won't restore your saved brightness, volume, contrast, resolution or arrangement at startup or wake, won't read values back from your displays, won't write anything to them when it quits, and won't dim any display, count hours of use, or take any measurements for OLED care.")
  }

  @Test func theLaunchNoticeIsExactly() {
    #expect(
      SafeModeCopy.launchNotice(app: Self.app) == """
      Shift was held during launch. For this session, Candela won't restore your saved brightness, volume, contrast, resolution or arrangement at startup or wake, won't read values back from your displays, won't write anything to them when it quits, and won't dim any display, count hours of use, or take any measurements for OLED care.

      Your sliders and keyboard shortcuts still work, and they still send commands to your displays. Nothing about your settings has changed: relaunch without holding Shift to leave Safe Mode.
      """)
  }

  @Test func theDiagnosticsRowIsExactly() {
    #expect(
      SafeModeCopy.diagnosticsRow(app: Self.app) == "Shift was held at launch. Candela won't restore your saved brightness, volume, contrast, resolution or arrangement at startup or wake, won't read values back from your displays, won't write anything to them when it quits, and won't dim any display, count hours of use, or take any measurements for OLED care. Sliders and keys still work.")
  }

  @Test func theGeneralPaneCaptionIsExactly() {
    #expect(
      SafeModeCopy.generalPaneCaption(app: Self.app) == "Shift was held at launch. Candela won't restore your saved brightness, volume, contrast, resolution or arrangement at startup or wake, won't read values back from your displays, won't write anything to them when it quits, and won't dim any display, count hours of use, or take any measurements for OLED care. The sliders and keys still work, your settings are unchanged, and relaunching without Shift restores normal behavior.")
  }

  /// Every summary must also say what safe mode does NOT stop. The fork shipped
  /// copy claiming more scope than it had, and a user who reads "nothing is
  /// written" as "no DDC leaves the app" reaches for safe mode to stop a wedging
  /// write and gets a live slider.
  @Test func everySummarySaysSlidersAndKeysStillWork() {
    #expect(SafeModeCopy.launchNotice(app: Self.app).contains("sliders and keyboard shortcuts still work"))
    #expect(SafeModeCopy.diagnosticsRow(app: Self.app).contains("Sliders and keys still work"))
    #expect(SafeModeCopy.generalPaneCaption(app: Self.app).contains("sliders and keys still work"))
  }

  /// The brightness-sync paragraph is ADDITIONAL to the four and conditional on
  /// the pref, so it must not be folded into the list or into the notice the
  /// list is part of.
  @Test func theBrightnessSyncParagraphIsNotPartOfTheList() {
    let notice = SafeModeCopy.launchNotice(app: Self.app)
    #expect(!notice.contains("Match other displays"))
    #expect(!SafeModeCopy.suppressions(app: Self.app).contains("Match other displays"))
    #expect(SafeModeCopy.brightnessSyncParagraph.contains("ambient light sensor"))
  }

  /// Same guarantee `DiagnosticsCopy` gives: the product name is provisional and
  /// lives in the app target, so no summary may bake the literal in.
  @Test func theProductNameIsNeverBakedIn() {
    let texts = [
      SafeModeCopy.suppressions(app: "Zed"),
      SafeModeCopy.launchNotice(app: "Zed"),
      SafeModeCopy.diagnosticsRow(app: "Zed"),
      SafeModeCopy.generalPaneCaption(app: "Zed"),
    ]
    for text in texts {
      #expect(text.contains("Zed"))
      #expect(!text.contains("Candela"))
    }
  }

  /// CLAUDE.md section 6: no em dashes in user-visible copy. Checked over the
  /// composed summaries rather than by grepping the source, which is the check
  /// that cannot be fooled by a multi-line literal.
  @Test func noSummaryContainsAnEmDash() {
    let texts = [
      SafeModeCopy.launchNotice(app: Self.app),
      SafeModeCopy.brightnessSyncParagraph,
      SafeModeCopy.diagnosticsRow(app: Self.app),
      SafeModeCopy.generalPaneCaption(app: Self.app),
      SafeModeCopy.careSessionNotice,
    ]
    for text in texts {
      #expect(!text.contains("\u{2014}"))
    }
  }

  /// The one sentence OLED Care and Health both open on during a safe-mode
  /// session, pinned verbatim: its three effects (no dimming, no hours, no
  /// measurements) restate `OledCareCoordinator.start`'s safe-mode return, and
  /// the doc comment on the member says a change there belongs in both. It
  /// takes no app parameter, so the product-name guarantee here is only that
  /// no literal is baked in.
  @Test func theCareSessionNoticeIsPinned() {
    #expect(
      SafeModeCopy.careSessionNotice
        == "Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken.")
    #expect(!SafeModeCopy.careSessionNotice.contains("Candela"))
  }
}
