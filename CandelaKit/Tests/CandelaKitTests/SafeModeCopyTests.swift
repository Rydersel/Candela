import Foundation
import Testing

@testable import CandelaKit

/// A sentence in an alert has no other reader, so summaries once named fewer
/// suppressions than the app performed and nothing failed. These tests are the
/// reader: the failure mode is a plausible edit that drops a clause, which
/// passes anything that only greps for a keyword.
@Suite("Safe mode copy")
struct SafeModeCopyTests {

  private static let app = "Candela"

  /// Asserted rather than derived, so growing the enum is a deliberate act with
  /// a failing test attached rather than a silent change to visible copy.
  @Test func safeModeSuppressesExactlyFourThings() {
    #expect(SafeModeCopy.Suppression.allCases.count == 4)
    #expect(SafeModeCopy.Suppression.allCases == [.restore, .readback, .quitWrite, .oledCare])
  }

  /// A new case with a clause but no summary edit still reaches every summary,
  /// and one skipped by the join fails here rather than in a screenshot.
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

  /// `restoreUnattended()` gates the arrangement on the same line as the stored
  /// mode, so a user whose layout did not come back gets no answer from a
  /// notice that stops at "resolution".
  @Test func theRestoreClauseNamesEverySavedThingTheSessionWillNotRestore() {
    let clause = SafeModeCopy.clause(.restore)
    for value in ["brightness", "volume", "contrast", "resolution", "arrangement"] {
      #expect(clause.contains(value))
    }
    // The launch notice used to omit it while the General pane said it.
    #expect(clause.contains("at startup or wake"))
  }

  /// OLED care is the most visible thing safe mode turns off. A clause saying
  /// only "dim" leaves a reader waiting on measurements that cannot come.
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

  /// Every summary must say what safe mode does NOT stop. A user who reads
  /// "nothing is written" as "no DDC leaves the app" reaches for safe mode to
  /// stop a wedging write and gets a live slider.
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

  /// The product name is provisional and lives in the app target, so no summary
  /// may bake the literal in.
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

  /// No em dashes in user-visible copy. Checked over the composed summaries,
  /// which a grep of the source cannot do across a multi-line literal.
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

  /// The sentence OLED Care and Health both open on in a safe-mode session,
  /// pinned verbatim: its effects restate `OledCareCoordinator.start`'s
  /// safe-mode return, so a change there belongs in both.
  @Test func theCareSessionNoticeIsPinned() {
    #expect(
      SafeModeCopy.careSessionNotice
        == "Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken.")
    #expect(!SafeModeCopy.careSessionNotice.contains("Candela"))
  }
}
