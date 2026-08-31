import Foundation
import Testing
@testable import CandelaKit

@Suite("Min/max DDC override validation")
struct DDCOverrideValidationTests {
  @Test func anEmptyFieldClearsTheOverride() {
    #expect(DDCOverrideValidation.classify("") == .cleared)
    #expect(DDCOverrideValidation.classify("   ") == .cleared)
    // A newline-only field is blank too: `.whitespacesAndNewlines`, not `.whitespaces`.
    #expect(DDCOverrideValidation.classify("\n") == .cleared)
    // 0 IS the unset value in the engine, so typing it means the same thing.
    #expect(DDCOverrideValidation.classify("0") == .cleared)
  }

  @Test func inRangeIntegersAreAccepted() {
    #expect(DDCOverrideValidation.classify("1") == .value(1))
    #expect(DDCOverrideValidation.classify(" 100 ") == .value(100))
    #expect(DDCOverrideValidation.classify("65535") == .value(65535))
    // `Int("+5")` parses; decided and pinned rather than left to chance.
    #expect(DDCOverrideValidation.classify("+5") == .value(5))
  }

  @Test func garbageAndOutOfRangeAreRejectedNeverCoerced() {
    // Fork parity for Min: the field snaps back and nothing is written. Candela applies
    // the same bound to Max, which the fork left unbounded (QUIRK 9).
    #expect(DDCOverrideValidation.classify("abc") == .rejected)
    #expect(DDCOverrideValidation.classify("12x") == .rejected)
    #expect(DDCOverrideValidation.classify("-1") == .rejected)
    #expect(DDCOverrideValidation.classify("65536") == .rejected)
    #expect(DDCOverrideValidation.classify("1.5") == .rejected)
    #expect(DDCOverrideValidation.classify("0x10") == .rejected) // no hex input
    #expect(DDCOverrideValidation.classify("1 2") == .rejected) // embedded space
  }

  @Test func storedValuesRoundTripThroughFieldText() {
    // Unset renders as an empty field, so "never touched" and "explicitly
    // zero" look the same — which is exactly what the engine means by 0.
    #expect(DDCOverrideValidation.text(for: DDCOverrideValidation.unset) == "")
    #expect(DDCOverrideValidation.text(for: 90) == "90")
    #expect(DDCOverrideValidation.classify(DDCOverrideValidation.text(for: 90)) == .value(90))
    #expect(DDCOverrideValidation.classify(DDCOverrideValidation.text(for: 0)) == .cleared)
  }

  @Test func aMaxOverrideIsInertUnlessItExceedsTheMin() {
    #expect(DDCOverrideValidation.warning(min: 0, max: 0) == nil) // no override at all
    #expect(DDCOverrideValidation.warning(min: 0, max: 90) == nil)
    #expect(DDCOverrideValidation.warning(min: 90, max: 80) == .maxNotAboveMin)
    #expect(DDCOverrideValidation.warning(min: 80, max: 80) == .maxNotAboveMin)
  }

  /// The warning has to describe what the ENGINE actually does, so pin it
  /// against `CommandTuning.effectiveMaxDDC` — the two can never drift apart.
  @Test func theWarningAgreesWithTheEngineRule() {
    // readMax 60 is deliberately not one of the max values below, so
    // "effective == max" can only mean the override won.
    for (minimum, maximum) in [(0, 0), (0, 90), (90, 80), (80, 80), (10, 11)] {
      let tuning = CommandTuning(
        unavailableDDC: false, minDDCOverride: minimum, maxDDCOverride: maximum,
        curveIndex: 0, invert: false, remapCodes: []
      )
      let overrideWon = tuning.effectiveMaxDDC(readMax: 60) == maximum
      let warned = DDCOverrideValidation.warning(min: minimum, max: maximum) != nil
      #expect(overrideWon == (!warned && maximum != DDCOverrideValidation.unset),
              "min \(minimum), max \(maximum)")
    }
  }
}

/// Anti-QUIRK-7: the mistake to catch is a `commit` that loops over `DDCCommand.allCases`
/// and writes the edited tuning into all three commands, which is what the fork did.
@Suite("Applying one override to one command")
struct DDCOverrideApplicationTests {
  private var base: CommandTuning {
    CommandTuning(
      unavailableDDC: true, minDDCOverride: 7, maxDDCOverride: 90,
      curveIndex: 3, invert: true, remapCodes: [0xE1]
    )
  }

  @Test func committingOneFieldChangesOnlyThatField() throws {
    let after = try #require(DDCOverrideValidation.applied(.value(12), to: base, field: .minimum))
    #expect(after.minDDCOverride == 12)
    #expect(after.maxDDCOverride == base.maxDDCOverride) // the sibling override is untouched
    // The D26-cut prefs survive an edit made through the grid. The fork rewrote them on
    // every widget touch (QUIRK 7/8), turning unset into an explicit value.
    #expect(after.curveIndex == base.curveIndex)
    #expect(after.remapCodes == base.remapCodes)
    #expect(after.invert == base.invert)
    #expect(after.unavailableDDC == base.unavailableDDC)
  }

  @Test func theMaximumFieldTouchesOnlyTheMaximum() throws {
    let after = try #require(DDCOverrideValidation.applied(.value(200), to: base, field: .maximum))
    #expect(after.maxDDCOverride == 200)
    #expect(after.minDDCOverride == base.minDDCOverride)
  }

  @Test func clearingWritesTheUnsetSentinelRatherThanRemovingTheOverride() throws {
    let after = try #require(DDCOverrideValidation.applied(.cleared, to: base, field: .maximum))
    #expect(after.maxDDCOverride == DDCOverrideValidation.unset)
    // Same state as never having typed anything: the read/assumed max wins.
    #expect(after.effectiveMaxDDC(readMax: 60) == 60)
  }

  @Test func rejectedInputWritesNothingAtAll() {
    // `nil` tells the grid to snap the field back and skip the write, rather than
    // writing the old value again, which would fan out and re-apply dimming for a typo.
    #expect(DDCOverrideValidation.applied(.rejected, to: base, field: .minimum) == nil)
    #expect(DDCOverrideValidation.applied(.rejected, to: base, field: .maximum) == nil)
  }

  /// The per-display reset writes `CommandTuning.unset`, so `unset` has to be exactly what
  /// an untouched display reports. Pinned against a real empty store: the fork wrote curve
  /// 5 on first touch (QUIRK 8), and a second hand-typed copy of the literal brings it back.
  @Test func theFactoryTuningIsWhatAnUntouchedDisplayReports() {
    let fresh = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "FRESH")
    for command in DDCCommand.allCases {
      #expect(fresh.tuning(for: command) == CommandTuning.unset, "\(command.rawValue)")
    }
    #expect(CommandTuning.unset.curveIndex == 0) // linear, NOT the fork's 5
    #expect(CommandTuning.unset.minDDCOverride == DDCOverrideValidation.unset)
    #expect(CommandTuning.unset.maxDDCOverride == DDCOverrideValidation.unset)
    #expect(CommandTuning.unset.remapCodes.isEmpty)
    #expect(!CommandTuning.unset.unavailableDDC)
    #expect(!CommandTuning.unset.invert)
  }
}

/// What a field commit decides, shared by both routes into it: a settings field applies
/// its text on Return and when focus leaves. Two routes into one write is how a second,
/// looser validation gets added by accident, and the fork accepted `abc`, `70000` and `-1`
/// in these boxes.
@Suite("Committing a field's text")
struct DDCOverrideCommitTests {
  private var tuned: CommandTuning {
    CommandTuning(
      unavailableDDC: true, minDDCOverride: 20, maxDDCOverride: 80,
      curveIndex: 3, invert: true, remapCodes: [0xE1]
    )
  }

  @Test func typedTextChangesOnlyTheEditedField() throws {
    let after = try #require(DDCOverrideValidation.committed("30", to: tuned, field: .minimum))
    #expect(after.minDDCOverride == 30)
    #expect(after.maxDDCOverride == 80)
    #expect(after.curveIndex == 3)
    #expect(after.remapCodes == [0xE1])

    let maxed = try #require(DDCOverrideValidation.committed("90", to: tuned, field: .maximum))
    #expect(maxed.maxDDCOverride == 90)
    #expect(maxed.minDDCOverride == 20)
  }

  /// Emptying a box is a real decision, not an abandoned edit: it stores 0 and gives the
  /// display its range back, or clearing a box and clicking away keeps the old override.
  @Test func emptyingAFieldStoresTheUnsetSentinel() throws {
    for text in ["", "   ", "\n", "0"] {
      let after = try #require(
        DDCOverrideValidation.committed(text, to: tuned, field: .minimum),
        "\(String(reflecting: text))"
      )
      #expect(after.minDDCOverride == DDCOverrideValidation.unset)
      #expect(after.maxDDCOverride == 80) // and only that field
    }
  }

  @Test func garbageAndOutOfRangeTextIsRefusedOnBothFields() {
    for text in ["abc", "70000", "-1", "65536", "1.5", "12x", "0x10"] {
      #expect(DDCOverrideValidation.committed(text, to: tuned, field: .minimum) == nil, "\(text)")
      #expect(DDCOverrideValidation.committed(text, to: tuned, field: .maximum) == nil, "\(text)")
    }
  }

  /// nil means nothing to do, not only refused: a field left alone renders text that
  /// resolves to the stored value, and writing there re-applies dimming on every focus
  /// change (D4).
  @Test func textThatMeansTheStoredValueWritesNothing() {
    #expect(DDCOverrideValidation.committed("20", to: tuned, field: .minimum) == nil)
    #expect(DDCOverrideValidation.committed(" 80 ", to: tuned, field: .maximum) == nil)

    let untouched = CommandTuning.unset
    #expect(DDCOverrideValidation.committed("", to: untouched, field: .minimum) == nil)
    #expect(DDCOverrideValidation.committed("0", to: untouched, field: .maximum) == nil)
  }

  /// The field renders `text(for:)` and commits whatever it holds, so rendered text must
  /// always be a no-op commit; otherwise focus passing through a box writes a pref.
  @Test func theRenderedTextOfEveryStoredValueIsANoOpCommit() {
    for stored in [0, 1, 20, 255, 65535] {
      let tuning = CommandTuning(
        unavailableDDC: false, minDDCOverride: stored, maxDDCOverride: stored,
        curveIndex: 0, invert: false, remapCodes: []
      )
      let text = DDCOverrideValidation.text(for: stored)
      #expect(DDCOverrideValidation.committed(text, to: tuning, field: .minimum) == nil, "\(stored)")
      #expect(DDCOverrideValidation.committed(text, to: tuning, field: .maximum) == nil, "\(stored)")
    }
  }

  /// One command's tuning in, the same command's tuning out. The fork wrote all three
  /// commands on any single edit (QUIRK 7); no other command's tuning is in scope here.
  @Test func committingIsPureAndTouchesNoOtherCommand() throws {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "PK")
    let before = prefs.tuning(for: .contrast)
    let after = try #require(DDCOverrideValidation.committed("60", to: before, field: .minimum))
    prefs.setTuning(after, for: .contrast)

    #expect(defaults.object(forKey: "minDDCOverride.contrast.PK") as? Int == 60)
    #expect(defaults.object(forKey: "minDDCOverride.brightness.PK") == nil)
    #expect(defaults.object(forKey: "minDDCOverride.volume.PK") == nil)
  }
}

/// A regression pin on key composition: this exercises `DisplayPrefs`, not the
/// validation above.
@Suite("DisplayPrefs per-command key materialization")
struct PerCommandKeyMaterializationTests {
  @Test func writingOneCommandNeverMaterializesTheOthers() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "PK")
    var tuning = prefs.tuning(for: .contrast)
    tuning.minDDCOverride = 12
    prefs.setTuning(tuning, for: .contrast)

    #expect(defaults.object(forKey: "minDDCOverride.contrast.PK") as? Int == 12)
    // The other two commands still have no keys at all.
    #expect(defaults.object(forKey: "minDDCOverride.brightness.PK") == nil)
    #expect(defaults.object(forKey: "invertDDC.brightness.PK") == nil)
    #expect(defaults.object(forKey: "unavailableDDC.volume.PK") == nil)
    // And the edited command's other fields keep their unset values — in
    // particular the curve stays 0 (linear).
    #expect(defaults.object(forKey: "curveDDC.contrast.PK") as? Int == 0)
    #expect(defaults.object(forKey: "invertDDC.contrast.PK") as? Bool == false)
    #expect(defaults.string(forKey: "remapDDC.contrast.PK") == "")
  }

  @Test func clearingAnOverrideReturnsTheEngineToItsFallback() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "PK")
    var tuning = prefs.tuning(for: .volume)
    tuning.maxDDCOverride = 90
    prefs.setTuning(tuning, for: .volume)
    #expect(prefs.tuning(for: .volume).effectiveMaxDDC(readMax: 60) == 90)

    tuning.maxDDCOverride = DDCOverrideValidation.unset
    prefs.setTuning(tuning, for: .volume)
    #expect(prefs.tuning(for: .volume).effectiveMaxDDC(readMax: 60) == 60)
  }
}
