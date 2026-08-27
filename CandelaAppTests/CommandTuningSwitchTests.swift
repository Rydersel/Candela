import CandelaKit
import Foundation
import Testing

/// The tuning grid's two switch columns: their names, and the shape they are
/// written in.
///
/// A host-free bundle cannot read an accessibility action list, so only the
/// copy and the shape are pinned here. Without them, a revert to the old
/// empty-label-plus-annotation shape stays invisible until someone next runs
/// the rig. `CommandTuningGrid` carries the reasoning behind the shape.
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
    // A ToggleStyle's inner switch takes its label from the outer toggle, so
    // it stays legal.
    #expect(!Self.hasEmptyLabelledToggle(in: "Toggle(isOn: configuration.$isOn) { EmptyView() }"))
    #expect(!Self.hasEmptyLabelledToggle(in: #"Toggle("Dim past the minimum", isOn: $flag)"#))
    // Comment lines are skipped, so a comment may name the shape it warns about.
    #expect(!Self.hasEmptyLabelledToggle(in: #"/// `Toggle("", isOn:)` is an unlabeled control."#))
  }

  /// Comment lines are skipped whole, not stripped from the tail: trimming a
  /// tail would mean reasoning about `//` inside string literals.
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
