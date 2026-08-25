import CandelaKit
import Foundation
import Testing

/// The flow's copy is the surface an anxious buyer reads while a field is on
/// their panel, so it is pinned rather than left to a reviewer's eye: every
/// field states its own cap, the planted control is disclosed before it is
/// planted, a miss is framed as a fact about resolution, and nothing anywhere
/// hands the display a verdict.
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

  /// `CheckupPage.name` is read back on the summary, in the copied text and in
  /// the exported file, so a storage key there is a key a person reads. The
  /// guard skips a raw value that is also an ordinary word of the field's prose
  /// name ("black" in "black field"): what it catches is `gray7` and `gray50`,
  /// the two that read as keys and nothing else.
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

  /// The document that names a run and the file it is exported into must agree
  /// on which day it was, or two artifacts of the same run disagree in the one
  /// field a person would check them by.
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

  /// CK16's occlusion note names the fields in prose and says nothing at all
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

  @Test func noCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for s in CheckupCopy.allStringsForTest {
      #expect(!s.contains("—"))
      #expect(!s.lowercased().contains("passed") && !s.lowercased().contains("failed the checkup"))
    }
  }
}
