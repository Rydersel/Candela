import Foundation

/// Why no DDC command reaches a display, which is what makes the per-command
/// tuning grid inert. Per-command reasons are deliberately absent: brightness
/// being off leaves the volume and contrast rows live, so greying the whole grid
/// on it would remove two working controls.
public enum DDCTrafficBlock: Sendable, Equatable {
  /// macOS drives this display's brightness and the DDC wire is unused. Always
  /// true of the built-in panel (no wire); on an external it means HDR is live,
  /// and DDC stops working entirely in HDR mode [MEASURED, MAG 341C].
  case macOSDrivesBrightness
  /// Hardware control is off for this display (`forceSoftware`), which silences
  /// DDC for EVERY command: `DDCValueController.isAvailable` reads it for volume
  /// and contrast too, not only brightness.
  case hardwareControlOff
}

/// The Displays pane rules that are not pure bindings. Here rather than in the
/// view because each has a wrong answer no test could catch in the app.
public enum DisplayCardPolicy {
  /// Whether any DDC command can reach this display, and if not, why. Derived from
  /// the same `BrightnessPath` the diagnostics section renders, so one settings page
  /// cannot give two answers about one display. Do not gate on `prefs.forceSoftware`
  /// alone: that misses live HDR, where the grid looks live while every DDC write
  /// goes nowhere.
  ///
  /// nil (the grid is live) for `.hardware`, `.combined`, and both brightness-only
  /// blocks. `.softwareOnly` and `.unavailable` say nothing about volume or
  /// contrast, which still write over the same wire.
  ///
  /// `isWireUnresponsive` is the fact the path cannot carry: a wire that
  /// stopped answering routes `.software`, the same path force-software selects, so
  /// blocking on it would caption a control nobody touched "hardware control is
  /// off".
  public static func ddcTrafficBlock(
    for path: BrightnessPath, isWireUnresponsive: Bool = false
  ) -> DDCTrafficBlock? {
    switch path {
    case .native:
      .macOSDrivesBrightness
    // Reached from `forceSoftware`, and from the wire's demotion, which is not an
    // opt-out at all.
    case .software:
      isWireUnresponsive ? nil : .hardwareControlOff
    case .hardware, .combined, .softwareOnly, .unavailable:
      nil
    }
  }

  /// Blank under any whitespace, newlines included, counts as unset. Same rule as
  /// the panel's title fallback.
  public static func normalizedFriendlyName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
