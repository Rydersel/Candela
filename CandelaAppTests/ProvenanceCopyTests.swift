import Foundation
import Testing

/// A provenance record is written to be forwarded to a stranger, so the same
/// gate the checkup pane's copy carries runs over this enum: it is the one
/// place a verdict on the display, or an em dash, could reach a document
/// somebody else reads.
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

  /// The verifier's two answers are about the FILE, and only about the file:
  /// an altered record says its contents no longer match, never that the
  /// display is at fault.
  @Test func theVerifierAnswersAboutTheRecordRatherThanTheDisplay() {
    #expect(ProvenanceCopy.intact.contains("record"))
    #expect(ProvenanceCopy.altered.contains("record"))
    #expect(!ProvenanceCopy.altered.lowercased().contains("display"))
  }
}
