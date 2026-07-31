import Foundation

/// Validation for the Displays pane's per-command min/max DDC overrides — the
/// one part of the tuning grid with real logic, so it lives here under test
/// rather than inline in the view (D21).
///
/// Two fork behaviors are deliberately not reproduced:
///
/// * The fork range-checks Min (0…65535) but accepts any `UInt` for Max
///   (chapter 2 QUIRK 9). Candela bounds both with the same range.
/// * The fork silently discards a Max override that is not greater than Min
///   — `CommandTuning.effectiveMaxDDC` just ignores it. Candela keeps the
///   rule (it is shipped engine behavior) but SAYS SO, via `warning(min:max:)`.
public enum DDCOverrideValidation {
  /// Stored `0` means "no override" for both fields, and that is the engine's
  /// own meaning: `minDDCOverride` 0 is the natural low end, and a
  /// `maxDDCOverride` of 0 can never exceed a min, so it is never effective.
  public static let unset = 0

  /// Accepted range, applied symmetrically to both fields. 65535 is the fork's
  /// Min bound — the widest a 16-bit DDC value can be.
  public static let range = 0...65535

  /// Which of a command's two override fields is being edited.
  public enum Field: Sendable, Equatable, CaseIterable {
    case minimum, maximum
  }

  /// What the contents of an override field mean.
  public enum Input: Sendable, Equatable {
    /// Empty field: clear the override (store `unset`).
    case cleared
    /// A valid, in-range override.
    case value(Int)
    /// Unparseable or out of range: keep the stored value and put it back in
    /// the field. Nothing is written (fork parity — the field snaps back).
    case rejected
  }

  public static func classify(_ text: String) -> Input {
    // `.whitespacesAndNewlines`, not `.whitespaces`: a field holding only a
    // newline is blank, and the narrower set classified it as garbage.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .cleared }
    guard let value = Int(trimmed), range.contains(value) else { return .rejected }
    return value == unset ? .cleared : .value(value)
  }

  /// Field text for a stored value. `unset` renders empty, so "never touched"
  /// and "explicitly zero" look the same — which is what the engine means by 0
  /// (the presence-semantics question the M4 triage deferred to M5).
  public static func text(for stored: Int) -> String {
    stored == unset ? "" : String(stored)
  }

  /// The grid's ENTIRE read-modify-write, as a pure function: one command's
  /// tuning in, the same tuning with exactly one field changed out. `nil` means
  /// the input was rejected and the caller must write nothing at all.
  ///
  /// This lives here rather than in the view because the mistake it prevents is
  /// invisible from the app target: a `commit` that loops over
  /// `DDCCommand.allCases` (the fork's QUIRK 7, and an easy slip next to the
  /// grid's own `ForEach(DDCCommand.allCases)`) reproduces the exact defect
  /// this task exists to avoid, and no test in the milestone could see it while
  /// the logic stayed inline (lens-4 C3).
  public static func applied(
    _ input: Input, to tuning: CommandTuning, field: Field
  ) -> CommandTuning? {
    let resolved: Int
    switch input {
    case .rejected: return nil
    case .cleared: resolved = unset
    case .value(let value): resolved = value
    }
    var updated = tuning
    switch field {
    case .minimum: updated.minDDCOverride = resolved
    case .maximum: updated.maxDDCOverride = resolved
    }
    return updated
  }

  /// Why a stored override pair does not do what it looks like it does.
  public enum Warning: Sendable, Equatable {
    /// `CommandTuning.effectiveMaxDDC` honors the max override only when it is
    /// strictly greater than the min override; otherwise the engine falls back
    /// to the read (or assumed) maximum and the typed number does nothing.
    case maxNotAboveMin
  }

  public static func warning(min: Int, max: Int) -> Warning? {
    guard max != unset else { return nil }
    return max > min ? nil : .maxNotAboveMin
  }
}

public extension CommandTuning {
  /// The tuning an untouched display reports, as ONE definition. The
  /// per-display reset writes this; it never hand-types a second copy in the
  /// app target, which is how `curveIndex: 5` (the fork's "linear", QUIRK 8)
  /// would otherwise slip back in with a green suite.
  static let unset = CommandTuning(
    unavailableDDC: false,
    minDDCOverride: DDCOverrideValidation.unset,
    maxDDCOverride: DDCOverrideValidation.unset,
    curveIndex: 0,
    invert: false,
    remapCodes: []
  )
}
