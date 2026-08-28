import CandelaKit
import Foundation
import Testing

/// A host-free bundle cannot read an accessibility action list, so these pin the
/// switch copy and the shape instead. Without them, a revert to the old
/// empty-label-plus-annotation shape only shows up on the rig.
@Suite("Command tuning switches")
struct CommandTuningSwitchTests {
  @Test func bothSwitchesAreNamedForTheirCommand() {
    #expect(DDCCommandCopy.enabledSwitchLabel(.brightness) == "brightness enabled")
    #expect(DDCCommandCopy.enabledSwitchLabel(.volume) == "volume enabled")
    #expect(DDCCommandCopy.enabledSwitchLabel(.contrast) == "contrast enabled")
    #expect(DDCCommandCopy.invertSwitchLabel(.brightness) == "Invert brightness")
    #expect(DDCCommandCopy.invertSwitchLabel(.volume) == "Invert volume")
    #expect(DDCCommandCopy.invertSwitchLabel(.contrast) == "Invert contrast")
  }

  /// VoiceOver reads these aloud, so two switches under one name is as bad as
  /// no name.
  @Test func theSixNamesAreDistinctAndNoneIsEmpty() {
    let names = DDCCommand.allCases.flatMap {
      [DDCCommandCopy.enabledSwitchLabel($0), DDCCommandCopy.invertSwitchLabel($0)]
    }
    #expect(names.count == 6)
    #expect(!names.contains(""))
    #expect(Set(names).count == names.count)
  }

  @Test func noSettingsToggleCarriesAnEmptyLabel() throws {
    let offenders = try Self.settingsSources()
      .filter { Self.hasEmptyLabelledToggle(in: $0.value) }
      .map(\.key)
      .sorted()
    #expect(offenders.isEmpty, """
      unlabeled toggles in: \(offenders.joined(separator: ", ")). \
      A switch that needs its label drawn somewhere else keeps a real label \
      under .labelsHidden(); it does not trade the label for an annotation.
      """)
  }

  /// Positive control: a scan that only ever finds nothing proves nothing.
  @Test func theScanCanSeeAnEmptyLabelledToggle() {
    #expect(Self.hasEmptyLabelledToggle(in: #"Toggle("", isOn: $flag)"#))
    #expect(Self.hasEmptyLabelledToggle(in: #"  Toggle( "" , isOn: $flag)"#))
    // A ToggleStyle's inner switch takes the outer toggle's label, so it is legal.
    #expect(!Self.hasEmptyLabelledToggle(in: "Toggle(isOn: configuration.$isOn) { EmptyView() }"))
    #expect(!Self.hasEmptyLabelledToggle(in: #"Toggle("Dim past the minimum", isOn: $flag)"#))
    // Comment lines are skipped, so a comment may name the shape it warns about.
    #expect(!Self.hasEmptyLabelledToggle(in: #"/// `Toggle("", isOn:)` is an unlabeled control."#))
  }

  /// Comment lines are skipped whole. Trimming a trailing comment would mean
  /// reasoning about `//` inside string literals.
  private static func hasEmptyLabelledToggle(in source: String) -> Bool {
    source.split(separator: "\n")
      .filter { !$0.drop(while: \.isWhitespace).hasPrefix("//") }
      .contains { line in
        var rest = line
        while let opening = rest.range(of: "Toggle(") {
          if rest[opening.upperBound...].drop(while: \.isWhitespace).hasPrefix("\"\"") {
            return true
          }
          rest = rest[opening.upperBound...]
        }
        return false
      }
  }

  private static func settingsSources() throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Candela/Settings")
    let files = try FileManager.default
      .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty, "no settings sources found at \(root.path)")
    return try files.reduce(into: [:]) { found, url in
      found[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
    }
  }
}
