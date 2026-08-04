import Foundation

/// Which path is actually driving a display's brightness. Named for what the
/// user sees, not for the prefs behind it (D25) — `forceSw` and `avoidGamma`
/// never reach a label.
public enum DisplayControlMethod: Sendable, Equatable, CaseIterable {
  /// DDC over the data cable. `avoidGamma` is inert on this path.
  case hardwareDDC
  /// Software dimming through the display's color profile (gamma table).
  case softwareGamma
  /// Software dimming through a dark overlay window.
  case softwareOverlay
}

/// The two rules the Displays pane's card needs that are not pure bindings.
/// They live here rather than inline in the view because both have a wrong
/// answer that is invisible without a test (D21, lens-4 H6).
public enum DisplayCardPolicy {
  /// The card's three-way summary, DERIVED from the engine's own path so the
  /// two cannot disagree.
  ///
  /// REPLACES `controlMethod(forceSoftware:avoidGamma:)`, whose own doc admitted
  /// it "mirrors `applyPaths`" while ignoring HDR-native, combined mode and
  /// `unavailableDDC` — so the shipped row was wrong on the built-in panel (no
  /// DDC wire, yet it reported "Hardware (DDC) control") and wrong under live
  /// HDR. Do not re-add a prefs-shaped overload: a second copy of the branch
  /// table is exactly what this projection exists to retire.
  ///
  /// nil for `.native` and `.unavailable`, which the card has no vocabulary for.
  /// The caller renders those two from the path itself; the diagnostics section
  /// states them in full.
  public static func controlMethod(for path: BrightnessPath) -> DisplayControlMethod? {
    switch path {
    case .native, .unavailable:
      nil
    // Combined is the DEFAULT path and DDC carries the top of its range, so the
    // three-way summary calls it hardware. The split point is a sentence, and a
    // sentence does not fit in this row.
    case .hardware, .combined:
      .hardwareDDC
    // `.softwareOnly` is combined mode with its hardware half NOT running
    // (controller ruling R-A). It must never answer `.hardwareDDC`: that would
    // reintroduce, one layer above the type that forbids it, the very untruth
    // the case was carved out to make unrepresentable — a dead DDC wire
    // captioned as hardware control.
    case let .software(backend), let .softwareOnly(backend, _, _):
      backend == .overlay ? .softwareOverlay : .softwareGamma
    }
  }

  /// A friendly name is "unset" when it is blank under ANY whitespace,
  /// newlines included — the same rule the panel's title fallback applies.
  public static func normalizedFriendlyName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
