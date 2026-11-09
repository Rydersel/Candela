import Foundation

/// A follow-up the Finish page offers, each opening the place in Settings it
/// names. Nothing on the list is required; closing setup without touching it is
/// the normal path.
enum OnboardingFineTuneItem: CaseIterable, Hashable, Identifiable {
  // Declaration order is the list's priority order.
  case oledCare, shortcuts, checkup, arrangement

  var id: Self { self }

  var title: String {
    switch self {
    case .oledCare: "Fine-tune OLED care"
    case .shortcuts: "Review your key shortcuts"
    case .checkup: "Run a Checkup"
    case .arrangement: "Check the arrangement"
    }
  }

  /// Only the Checkup line names displays, so only it reads the count.
  func detail(externalDisplays: Int) -> String {
    switch self {
    case .oledCare: "Idle dimming and static-region protection"
    case .shortcuts: "Brightness, volume and contrast"
    case .checkup:
      "Look for defects and wear on your \(externalDisplays >= 2 ? "displays" : "display")"
    case .arrangement: "How your displays sit next to each other"
    }
  }

  var pane: PaneID {
    switch self {
    case .oledCare: .oledCare
    case .shortcuts: .keyboard
    case .checkup: .checkup
    case .arrangement: .arrangement
    }
  }

  var destination: SettingsDestination { .pane(pane) }

  /// The destination pane's own sidebar glyph, so the row and the place it
  /// opens look like the same thing.
  @MainActor var symbol: String { SettingsRegistry.descriptor(for: pane).symbol }

  /// Each item appears only when its fact holds; the list never pads itself.
  ///
  /// `arrangedDisplays` is the Arrangement pane's tile count, built-in
  /// included, so a mirror set or a lone external in clamshell has nothing to
  /// arrange. Shortcuts need the keys on and `grantInPlace`: the grant given,
  /// or not needed because no family watches the media keys.
  static func items(
    enrolledOleds: Int, keysOn: Bool, grantInPlace: Bool,
    externalDisplays: Int, arrangedDisplays: Int
  ) -> [OnboardingFineTuneItem] {
    allCases.filter { item in
      switch item {
      case .oledCare: enrolledOleds > 0
      case .shortcuts: keysOn && grantInPlace
      case .checkup: externalDisplays > 0
      case .arrangement: arrangedDisplays > 1
      }
    }
  }
}

/// The Finish page's words, outside the view so the tests read what it draws.
enum OnboardingFinishCopy {
  struct Line: Equatable {
    var text: String
    /// Drawn with a check. A line that states something not done (keys off,
    /// access still to give) must not wear one.
    var done: Bool
  }

  static let keysReady = "Keyboard keys are ready to use"
  static let keysOff = "Brightness and volume keys are off; turn them on in Settings > Keyboard"
  static let keysAwaitAccess = "Keyboard access can be granted later in Settings"
  static let fineTuneHeading = "Next, in Settings"

  /// Off wins over the grant: with the modes off, access changes nothing the
  /// keys do, and "ready" would be untrue. `grantInPlace` is true for modes
  /// that need no grant, so custom shortcuts read as ready without one.
  static func keysLine(keysOn: Bool, grantInPlace: Bool) -> Line {
    if !keysOn { return Line(text: keysOff, done: false) }
    return grantInPlace
      ? Line(text: keysReady, done: true)
      : Line(text: keysAwaitAccess, done: false)
  }

  static func summary(
    keysOn: Bool, grantInPlace: Bool, externalDisplays: Int, protectedOleds: Int
  ) -> [Line] {
    var lines = [keysLine(keysOn: keysOn, grantInPlace: grantInPlace)]
    if externalDisplays > 0 {
      lines.append(Line(
        text: externalDisplays == 1
          ? "1 display configured" : "\(externalDisplays) displays configured",
        done: true))
    }
    if protectedOleds > 0 {
      lines.append(Line(
        text: protectedOleds == 1
          ? "OLED care is protecting 1 display"
          : "OLED care is protecting \(protectedOleds) displays",
        done: true))
    }
    return lines
  }
}
