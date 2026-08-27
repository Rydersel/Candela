import Foundation

/// Which path is actually driving a display's brightness. Named for what the
/// user sees, not for the prefs behind it (D25) — `forceSw` and `avoidGamma`
/// never reach a label.
public enum DisplayControlMethod: Sendable, Equatable {
  /// DDC over the data cable. `avoidGamma` is inert on this path.
  case hardwareDDC
  /// Software dimming through the display's color profile (gamma table).
  case softwareGamma
  /// Software dimming through a dark overlay window.
  case softwareOverlay
}

/// Why NO DDC command reaches a display — the fact that makes the per-command
/// tuning grid inert.
///
/// Per-COMMAND reasons are deliberately absent. Turning brightness off leaves
/// the volume and contrast rows perfectly live, so greying the whole grid on
/// that would remove two working controls; only a display-level silence
/// belongs here.
public enum DDCTrafficBlock: Sendable, Equatable {
  /// macOS is setting this display's brightness itself and the DDC wire is not
  /// being used at all. Constitutive for the built-in panel (no wire); for an
  /// external it means HDR is live, and DDC stops working entirely while a
  /// display is in HDR mode [MEASURED, MAG 341C].
  case macOSDrivesBrightness
  /// Hardware control is turned off for this display (`forceSoftware`), which
  /// silences DDC for EVERY command — `DDCValueController.isAvailable` reads it
  /// for volume and contrast too, not only for brightness.
  case hardwareControlOff
}

/// The rules the Displays pane's card and its tuning grid need that are not
/// pure bindings. They live here rather than inline in the view because each
/// has a wrong answer that is invisible without a test (D21, lens-4 H6).
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

  /// Whether any DDC command can reach this display, and if not, why —
  /// derived from the SAME `BrightnessPath` the diagnostics section renders,
  /// so one settings page cannot give two answers about one display.
  ///
  /// The defect this retires: `CommandTuningGrid` gated itself on
  /// `prefs.forceSoftware` alone. That is wrong in both directions. It missed
  /// live HDR, where the grid presented itself as live while every DDC write
  /// was going nowhere; and its sibling caption fired on
  /// `tuning(for: .brightness).unavailableDDC`, so a display whose diagnostics
  /// row read "Nothing is moving this display's brightness" was told three
  /// sections below that it "dims in software only".
  ///
  /// nil — the grid is live — for `.hardware`, `.combined`, and BOTH
  /// brightness-only blocks. `.softwareOnly` and `.unavailable` say nothing
  /// about volume or contrast: they are reached from the brightness command's
  /// own `unavailableDDC`, and that display's volume slider still writes over
  /// the same wire.
  ///
  /// `isWireUnresponsive` is the one fact the path cannot carry (WD2). In
  /// pure-DDC configuration a display whose wire stopped answering routes
  /// `.software`, the same path force-software selects, and the two are opposite
  /// stories: one is a switch a person flipped, the other is a display that went
  /// quiet. Blocking on it would grey the whole grid and caption it "hardware
  /// control is off" about a control nobody touched, so it answers nil for the
  /// reason `.softwareOnly` does: the brightness command is not landing, and
  /// volume and contrast still write over the same wire.
  ///
  /// Defaulted to false, so a caller with no controller in hand keeps the
  /// pre-WD2 reading. Every call site that HAS one passes it.
  public static func ddcTrafficBlock(
    for path: BrightnessPath, isWireUnresponsive: Bool = false
  ) -> DDCTrafficBlock? {
    switch path {
    case .native:
      .macOSDrivesBrightness
    // Reachable from `forceSoftware`, which is the display-level opt-out
    // `DDCValueController.isAvailable` also reads, and from the wire's own
    // demotion, which is not an opt-out at all.
    case .software:
      isWireUnresponsive ? nil : .hardwareControlOff
    case .hardware, .combined, .softwareOnly, .unavailable:
      nil
    }
  }

  /// A friendly name is "unset" when it is blank under ANY whitespace,
  /// newlines included — the same rule the panel's title fallback applies.
  public static func normalizedFriendlyName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
