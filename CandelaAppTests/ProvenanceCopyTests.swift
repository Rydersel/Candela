import Foundation
import Testing

/// A provenance record gets forwarded to a stranger, so the checkup pane's copy gate
/// runs over this enum too: no verdict on the display, no em dash.
@Suite("Provenance copy")
struct ProvenanceCopyTests {
  @Test func noProvenanceCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for sentence in ProvenanceCopy.allStringsForTest {
      let lowered = sentence.lowercased()
      #expect(!sentence.isEmpty)
      #expect(!sentence.contains("—"), "\(sentence)")
      #expect(!lowered.contains("passed"), "\(sentence)")
      #expect(!lowered.contains("failed"), "\(sentence)")
      #expect(!lowered.contains("grade"), "\(sentence)")
      #expect(!lowered.contains("score"), "\(sentence)")
    }
  }

  /// Both verifier answers are about the FILE only: an altered record says its
  /// contents no longer match, never that the display is at fault.
  @Test func theVerifierAnswersAboutTheRecordRatherThanTheDisplay() {
    #expect(ProvenanceCopy.intact.contains("record"))
    #expect(ProvenanceCopy.altered.contains("record"))
    #expect(!ProvenanceCopy.altered.lowercased().contains("display"))
  }
}
