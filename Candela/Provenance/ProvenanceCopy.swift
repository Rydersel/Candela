import Foundation

enum ProvenanceCopy {
  static let export = "Export provenance…"
  static let copySummary = "Copy summary"
  static let copied = "Copied"
  static let exportFailed = "The provenance record could not be saved."
  static let acknowledge = "OK"
  static let note =
    "A provenance record bundles this display's hours, exposure history and checkup runs into one file "
    + "with a hash of its own contents. It goes with the display when you sell or return it. "
    + "The record states that its data is self-reported: it corroborates, it does not certify. "
    + "Nothing is sent anywhere."

  static let check = "Check a provenance file"
  static let checkNote =
    "An exported provenance record carries a hash of its own contents. Open one here to check that the two still agree."
  static let intact = "This record is intact: its contents are unchanged since export."
  static let altered = "This record has been altered: its contents no longer match its hash."
  static let unreadable = "That file could not be read as a Candela provenance record."

  static var allStringsForTest: [String] {
    [export, copySummary, copied, exportFailed, acknowledge, note, check, checkNote, intact, altered, unreadable]
  }
}
