import Foundation
import Testing
@testable import CandelaKit

/// The decay guard for the identifier sweep: a new `PrefName` with a control
/// and no identifier is what silently drops a setting out of the rig's reach,
/// and nothing else in the suite would notice. This asserts a call site
/// EXISTS, not that the composed string is right: composition has its own
/// tests, and the hardware pass reads the live attribute back.
@Suite("Every pref-writing control carries its identifier")
struct PrefIdentifierCoverageTests {
  /// Cases with no direct settings control, each with the writer that owns it.
  static let noControl: Set<PrefName> = [
    .storedDisplayMode,     // DisplayModeCoordinator, via the size pickers
    .storedSyntheticSize,   // SynthesisCoordinator (SS11 ordering)
    .savedArrangements,     // ArrangementCoordinator, via the canvas
    .virtualSlotUUID,       // minted programmatically on Create
    .virtualSlotRefreshHz,  // no writer anywhere today
  ]

  /// Cases whose only controls are ACTION buttons in `VirtualDisplaysPane`.
  /// Neither name is ever written by a control of its own: both come out of an
  /// action button's batch. Add writes `defined` and `configured` together,
  /// Remove clears both together, and Create/Apply write `configured` alone
  /// (plus `virtualSlotUUID` on the first configure). The buttons carry
  /// `action.slotAdd.<slot>` / `action.slotApply.<slot>` /
  /// `action.slotRemove.<slot>`, which name the act rather than one of its
  /// writes. Separate from `noControl` because the reason is different: these
  /// are reachable, just not by pref name.
  static let actionButtonOwned: Set<PrefName> = [
    .virtualSlotDefined,
    .virtualSlotConfigured,
  ]

  @Test func everyOtherCaseAppearsAtAPrefIdentifierCallSite() throws {
    let lines = try Self.settingsSourceLines()
    var missing: [String] = []
    for name in PrefName.allCases
    where !Self.noControl.contains(name) && !Self.actionButtonOwned.contains(name) {
      // Every call site in the app is a single-line `.prefIdentifier(...)`, or
      // a single line passing the case to a shared row builder under that
      // label, so one line carries both halves. Keep it that way: a call split
      // across lines would pass this scan only by accident.
      if !lines.contains(where: { $0.contains("prefIdentifier") && Self.mentions(name, in: $0) }) {
        missing.append(name.rawValue)
      }
    }
    #expect(missing.isEmpty, "no identifier call site for: \(missing.joined(separator: ", "))")
  }

  /// The exclusion sets stay honest: a name excluded here must not also have a
  /// call site, which would mean the comment explaining its absence is wrong.
  @Test func theExcludedCasesReallyHaveNoCallSite() throws {
    let lines = try Self.settingsSourceLines()
    let excluded = Self.noControl.union(Self.actionButtonOwned)
    let carried = excluded
      .filter { name in
        lines.contains { $0.contains("prefIdentifier") && Self.mentions(name, in: $0) }
      }
      .map(\.rawValue).sorted()
    #expect(carried.isEmpty, "excluded but carried after all: \(carried.joined(separator: ", "))")
  }

  private static func settingsSourceLines() throws -> [Substring] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Candela/Settings")
    let sources = try FileManager.default
      .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      // The composer's own file declares the modifier; its declaration line
      // mentions no case, but excluding it keeps the scan looking only at
      // call sites.
      .filter { $0.lastPathComponent != "PrefIdentifiers.swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }
    #expect(!sources.isEmpty, "no settings sources found at \(root.path)")
    return sources.joined(separator: "\n").split(separator: "\n")
  }

  /// `.name` anchored on the leading dot AND on a word boundary after it, so a
  /// case name that is a prefix of another cannot be satisfied by the longer
  /// one's call site. No such pair exists today; the guard is for the one
  /// somebody adds later.
  private static func mentions(_ name: PrefName, in line: Substring) -> Bool {
    let token = ".\(name.rawValue)"
    var rest = line
    while let found = rest.range(of: token) {
      let after = found.upperBound
      if after == line.endIndex || !(line[after].isLetter || line[after].isNumber
        || line[after] == "_")
      {
        return true
      }
      rest = line[after...]
    }
    return false
  }
}
