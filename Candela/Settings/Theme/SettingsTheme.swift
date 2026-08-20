import SwiftUI

/// The settings window's visual vocabulary: the guided setup flow's palette at
/// settings density (SV1, SV5).
///
/// Colors are aliases of `OnboardingStyle`'s rather than copies, so the two
/// surfaces cannot drift apart one hex value at a time. Geometry and motion are
/// this window's own: a settings page is a working surface, tighter than a
/// staged onboarding page.
enum SettingsTheme {
  /// Content column width. Wider pages read as a web page, not an app.
  static let pageWidth: CGFloat = 620
  static let cardRadius: CGFloat = 9

  /// A destination changing, in the sidebar and in the detail column.
  static let selectionMotion: Animation = .easeInOut(duration: 0.25)
  /// The canvas re-tinting under a new destination: slower than the selection
  /// itself, so the light lags the click the way stage light does.
  static let canvasRelight: Animation = .easeInOut(duration: 0.7)
  /// Hover reveals, which `Motion` deliberately leaves to their own sites.
  static let hoverMotion: Animation = .easeOut(duration: 0.15)

  static let titleColor = OnboardingStyle.titleColor
  static let bodyColor = OnboardingStyle.bodyColor
  static let faintColor = OnboardingStyle.faintColor
  static let cardFill = OnboardingStyle.cardFill
  static let cardStroke = OnboardingStyle.cardStroke

  /// Destructive actions never borrow the destination accent, which everywhere
  /// else in this window means "this is on".
  static let dangerTint = Color(red: 0.84, green: 0.42, blue: 0.40)
}

/// The stage lighting one destination provides: the hue its canvas, kickers,
/// controls and glyphs all read from.
///
/// A pair rather than a single color because the canvas needs two blobs; a
/// value type rather than a view modifier because pages hand it to AppKit
/// islands and to glyph parameters as well as into the environment.
struct SettingsAccent: Equatable, Sendable {
  var accent: Color
  var secondary: Color

  /// The environment default: white-forward, so a themed component rendered
  /// outside an injected destination reads as chrome instead of borrowing a hue
  /// nobody gave it. The secondary is the displays' own, which is the one hue
  /// in the palette that belongs to no section.
  static let neutral = SettingsAccent(
    accent: .white, secondary: Color(red: 0.30, green: 0.41, blue: 0.84))

  /// A display destination's lighting. The built-in has a fixed cool hue; the
  /// externals cycle a short list by their position in the sidebar, so two
  /// panels attached at once never light the window the same way.
  static func display(isBuiltIn: Bool, ordinal: Int) -> SettingsAccent {
    guard !isBuiltIn else {
      return SettingsAccent(
        accent: Color(red: 0.69, green: 0.76, blue: 0.90), secondary: neutral.secondary)
    }
    let hues = [
      Color(red: 0.36, green: 0.57, blue: 0.90),
      Color(red: 0.91, green: 0.60, blue: 0.31),
    ]
    let index = ((ordinal % hues.count) + hues.count) % hues.count
    return SettingsAccent(accent: hues[index], secondary: neutral.secondary)
  }
}

private struct SettingsAccentKey: EnvironmentKey {
  static let defaultValue = SettingsAccent.neutral
}

extension EnvironmentValues {
  /// Read by every themed component, so a page tints its whole subtree once
  /// instead of threading an accent through every call site.
  var settingsAccent: SettingsAccent {
    get { self[SettingsAccentKey.self] }
    set { self[SettingsAccentKey.self] = newValue }
  }
}
