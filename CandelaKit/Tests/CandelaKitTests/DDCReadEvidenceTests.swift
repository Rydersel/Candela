import Foundation
import Testing
@testable import CandelaKit

@Suite("DDC read evidence (B3)")
struct DDCReadEvidenceTests {
  /// Worst evidence wins WITHIN a display: one `allZeros` is not cancelled by
  /// a later `notAttempted`. Without this a display that answered zeros on
  /// brightness and was never asked about contrast would report "not
  /// attempted" and the write-only line would never appear.
  @Test func worseNeverForgetsABadOutcome() {
    #expect(DDCReadEvidence.worse(.allZeros, .notAttempted) == .allZeros)
    #expect(DDCReadEvidence.worse(.notAttempted, .allZeros) == .allZeros)
    #expect(DDCReadEvidence.worse(.answered, .allZeros) == .allZeros)
    #expect(DDCReadEvidence.worse(.answered, .noReply) == .noReply)
    #expect(DDCReadEvidence.worse(.noReply, .allZeros) == .allZeros)
  }

  /// `notAttempted` is the FLOOR, not a bad outcome: a display that answered
  /// once and was then not asked again has still answered.
  @Test func notAttemptedNeverOverridesARealAnswer() {
    #expect(DDCReadEvidence.worse(.answered, .notAttempted) == .answered)
    #expect(DDCReadEvidence.worse(.notAttempted, .answered) == .answered)
    #expect(DDCReadEvidence.worse(.notAttempted, .notAttempted) == .notAttempted)
  }

  @Test func worstFoldsAWholeDisplaysControllers() {
    #expect(DDCReadEvidence.worst([]) == .notAttempted)
    #expect(DDCReadEvidence.worst([.answered, .notAttempted, .answered]) == .answered)
    // The MAG 341C: brightness answers zeros, volume and contrast are never
    // attempted because startupAction is not `.read`.
    #expect(DDCReadEvidence.worst([.allZeros, .notAttempted, .notAttempted]) == .allZeros)
  }

  /// A three-state collapse is the defect this enum exists to prevent: "no
  /// reply" and "answered with zeros" are DIFFERENT facts about a panel, and
  /// only the second is the write-only signature.
  @Test func noReplyAndAllZerosAreNotTheSameFact() {
    #expect(DDCReadEvidence.noReply != DDCReadEvidence.allZeros)
  }
}
