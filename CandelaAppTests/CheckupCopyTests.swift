import CandelaKit
import Foundation
import Testing

/// Pinned rather than left to a reviewer's eye: every field states its cap, the
/// control is disclosed before it is planted, a miss is framed as resolution,
/// and nothing hands the display a verdict.
@Suite("Checkup copy")
struct CheckupCopyTests {
  @Test func everyFieldHasAnInstructionThatNamesTheDefectAndTheCap() {
    for kind in CheckupFieldKind.allCases {
      let text = CheckupCopy.instruction(for: kind)
      #expect(text.contains("\(kind.capSeconds) seconds"), "\(kind)")
      #expect(!text.contains("—"))
      #expect(text.count > 60, "\(kind)")
    }
    #expect(CheckupCopy.instruction(for: .black).contains("not black"))
    #expect(CheckupCopy.instruction(for: .gray7).contains("band"))
    #expect(CheckupCopy.instruction(for: .ramp).contains("step"))
    #expect(CheckupCopy.instruction(for: .witness).contains("round"))
  }

  @Test func theDisclosureAndTheMissAreFramedAsTheSpecRequires() {
    #expect(CheckupCopy.plantDisclosure.contains("one small mark"))
    #expect(CheckupCopy.plantDisclosure.contains("not reveal"))
    #expect(CheckupCopy.plantMissed(size: 4).contains("would not be visible"))
    #expect(!CheckupCopy.plantMissed(size: 4).lowercased().contains("you missed"))
    #expect(CheckupCopy.showAgainCap.contains("three"))
  }

  /// `CheckupPage.name` reaches the summary and the exported file. Raw values that
  /// are ordinary words ("black") are skipped; storage keys like `gray7` are not.
  @Test func noPageNameCarriesAFieldsStorageKey() {
    var pages: [CheckupPage] = [
      .scenario, .displayPick, .plan, .identity, .capabilities, .nativeMode, .refresh,
      .witness, .plantDisclosure, .hdr, .summary,
    ]
    for kind in CheckupFieldKind.allCases {
      pages += [.fieldInstruction(kind), .fieldShowing(kind), .fieldConfirmSecondDot(kind)]
    }
    for page in pages {
      for kind in CheckupFieldKind.allCases
      where !CheckupCopy.fieldName(kind).contains(kind.rawValue) {
        #expect(!page.name.contains(kind.rawValue), "\(page.name) carries \(kind.rawValue)")
      }
    }
    #expect(CheckupPage.fieldShowing(.gray7).name == "the near-black gray field")
    #expect(CheckupPage.fieldInstruction(.gray50).name == "the mid gray field")
    #expect(CheckupPage.fieldConfirmSecondDot(.black).name == "the black field")
  }

  /// The document and its file name must agree on the day, the one field a
  /// person would check them by.
  @Test func theSubjectLineNamesTheDisplayTheScenarioAndTheExportsOwnDay() {
    let report = CheckupReport(
      scenario: .usedPurchase,
      identity: CheckupDisplayIdentity(
        identityKey: "k", vendorID: 1, modelID: 2, serial: nil, manufactureWeek: nil,
        manufactureYear: nil, nativePixelWidth: 3840, nativePixelHeight: 2160,
        maxRefreshHz: nil, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
        productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "b", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil,
      completion: .complete, claims: [], plant: nil, showings: [:], exposureBookingID: nil)
    let subject = CheckupCopy.subjectLine(for: report)
    #expect(subject.hasPrefix("DELL U2725QE, a used purchase, "))
    let day = CheckupStore.day(report.startedAt)
    #expect(subject.hasSuffix(day))
    #expect(CheckupStore.exportFileName(for: report).contains(day))
  }

  /// The occlusion note names the fields in prose and says nothing at all
  /// when no field was occluded.
  @Test func theOcclusionLineNamesFieldsInProseAndIsAbsentWhenThereAreNone() throws {
    #expect(CheckupCopy.occlusionLine(fieldIDs: []) == nil)
    let line = try #require(
      CheckupCopy.occlusionLine(
        fieldIDs: [CheckupCheckID.field(.black), CheckupCheckID.field(.gray7)]))
    #expect(line.contains("black, near-black gray"))
    #expect(!line.contains("gray7"))
    #expect(!line.contains("field.black"))
  }

  /// The window found no `NSScreen`, which mirroring is the usual but not the
  /// only cause of. The line says what was observed and offers the cause.
  @Test func theUnshownFieldStatesTheObservationRatherThanAssertingMirroring() {
    #expect(CheckupCopy.fieldNotShown.contains(CheckupCopy.noScreenReason))
    #expect(CheckupCopy.fieldNotShown.contains("usual cause"))
    #expect(!CheckupCopy.noScreenReason.lowercased().contains("mirror"))
  }

  /// The mode legs blank the panel once per rate. Unwarned, that reads as the
  /// app breaking the display.
  @Test func thePlanSaysTheDisplayWillGoDarkDuringTheModeLegs() {
    #expect(CheckupCopy.planModeSweep.contains("go dark"))
    #expect(CheckupCopy.planModeSweep.contains("refresh rate"))
    #expect(CheckupCopy.planModeSweep.contains("put back"))
  }

  @Test func noCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for s in CheckupCopy.allStringsForTest {
      #expect(!s.contains("—"))
      #expect(!s.lowercased().contains("passed") && !s.lowercased().contains("failed the checkup"))
    }
  }
}
