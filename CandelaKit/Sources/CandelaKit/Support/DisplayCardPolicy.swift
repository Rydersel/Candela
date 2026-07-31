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
  /// Mirrors `BrightnessController.applyPaths`: the software backend choice
  /// only applies once the software leg is in use at all.
  public static func controlMethod(forceSoftware: Bool, avoidGamma: Bool) -> DisplayControlMethod {
    guard forceSoftware else { return .hardwareDDC }
    return avoidGamma ? .softwareOverlay : .softwareGamma
  }

  /// A friendly name is "unset" when it is blank under ANY whitespace,
  /// newlines included — the same rule the panel's title fallback applies.
  public static func normalizedFriendlyName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
