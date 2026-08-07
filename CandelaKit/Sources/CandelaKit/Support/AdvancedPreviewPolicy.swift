/// What a display's Advanced settings currently amount to, reduced to the four
/// facts the hub's chevron row can summarise.
///
/// The caller composes this from live `DisplayPrefs` reads rather than caching
/// it, so the preview cannot outlive the values it describes.
public struct AdvancedSnapshot: Equatable, Sendable {
  /// `forceSw` — DDC is off, so every control on the display is software-only.
  public let ddcOff: Bool
  /// `avoidGamma` — dimming runs through the shade overlay instead of gamma.
  public let overlayOn: Bool
  /// `hideOsd` — the display's own volume OSD is suppressed.
  public let osdHidden: Bool
  /// Non-default tuning fields plus curve/remap/crossover/polling. Excludes
  /// `osdHidden`, which the label folds in itself.
  public let overrideCount: Int

  public init(ddcOff: Bool, overlayOn: Bool, osdHidden: Bool, overrideCount: Int) {
    self.ddcOff = ddcOff
    self.overlayOn = overlayOn
    self.osdHidden = osdHidden
    self.overrideCount = overrideCount
  }
}

/// The one-line summary shown beside the Advanced chevron (SO3).
public enum AdvancedPreviewPolicy {
  /// Ranked, not additive: the two settings that change what every other
  /// control *means* name themselves, and only below them does the row fall
  /// back to counting.
  public static func label(for s: AdvancedSnapshot) -> String {
    if s.ddcOff { return "Hardware control off" }
    if s.overlayOn { return "Screen overlay" }
    let count = s.overrideCount + (s.osdHidden ? 1 : 0)
    if count == 0 { return "Default" }
    return count == 1 ? "1 override" : "\(count) overrides"
  }
}
