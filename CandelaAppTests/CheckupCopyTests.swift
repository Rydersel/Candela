import CandelaKit
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

  @Test func noCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for s in CheckupCopy.allStringsForTest {
      #expect(!s.contains("—"))
      #expect(!s.lowercased().contains("passed") && !s.lowercased().contains("failed the checkup"))
    }
  }
}
