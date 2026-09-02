import SwiftUI

/// The settings window's visual vocabulary.
///
/// Colors alias `OnboardingStyle`'s rather than copying them, so the two
/// surfaces cannot drift apart one hex value at a time. Geometry and motion are
/// this window's own, tighter than a staged onboarding page.
enum SettingsTheme {
  /// Content column width. Wider pages read as a web page, not an app.
  static let pageWidth: CGFloat = 620
  static let cardRadius: CGFloat = 9

  /// Half of the visual redesign's stated 0.25: at 0.25 the swap was still
  /// finishing when the next click arrived. `canvasRelight` is halved with it,
  /// since the ratio is what the visual redesign is really asking for.
  static let selectionMotion: Animation = .easeInOut(duration: 0.125)
  /// Slower than the selection, so the light lags the click.
  static let canvasRelight: Animation = .easeInOut(duration: 0.35)
  /// Hover reveals, which `Motion` leaves to their own sites.
  static let hoverMotion: Animation = .easeOut(duration: 0.15)

  static let titleColor = OnboardingStyle.titleColor
  static let bodyColor = OnboardingStyle.bodyColor
  static let faintColor = OnboardingStyle.faintColor
  static let cardFill = OnboardingStyle.cardFill
  static let cardStroke = OnboardingStyle.cardStroke

  /// Destructive actions never borrow the destination accent, which everywhere
  /// else in this window means "this is on".
  static let dangerTint = Color(red: 0.84, green: 0.42, blue: 0.40)

  /// Half the gap between rows on a card. With no `Form` container to pad
  /// them, the components have to agree, so whichever one supplies a row's
  /// rhythm supplies exactly this, once.
  static let rowVerticalPadding: CGFloat = 6
  /// Named because `SettingsActionRow` restates it under a divider-following
  /// row, and the two must not drift.
  static let cardVerticalPadding: CGFloat = 10

  /// What `.disabled(true)` looks like on anything this theme paints itself.
  /// Native controls dim themselves and must never be given this on top.
  static let disabledOpacity = 0.45

  static func dimmed(_ color: Color, isEnabled: Bool) -> Color {
    isEnabled ? color : color.opacity(disabledOpacity)
  }
}

private struct SettingsTextModifier: ViewModifier {
  let color: Color
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.foregroundStyle(SettingsTheme.dimmed(color, isEnabled: isEnabled))
  }
}

extension View {
  /// For labels a page paints itself, which nothing else dims. A bare
  /// `foregroundStyle` beside themed controls leaves the card half-dimmed,
  /// which reads worse than not dimming at all.
  ///
  /// Reads `\.isEnabled` rather than the page's own predicate, so a section
  /// disabled from an enclosing view dims with it.
  func settingsText(_ color: Color) -> some View {
    modifier(SettingsTextModifier(color: color))
  }
}

/// Set by whichever wrapper already supplied a row's vertical rhythm, so a
/// nested row component does not add a second helping. Without it a pop-up row
/// is 12 pt bare and 24 pt wrapped, and one card shows both.
private struct SettingsRowIsPaddedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var settingsRowIsPadded: Bool {
    get { self[SettingsRowIsPaddedKey.self] }
    set { self[SettingsRowIsPaddedKey.self] = newValue }
  }
}

/// The hue a destination's canvas, kickers, controls and glyphs all read from.
///
/// A pair because the canvas needs two blobs. A value type rather than a view
/// modifier because pages hand it to AppKit islands and glyph parameters as
/// well as into the environment.
struct SettingsAccent: Equatable, Sendable {
  var accent: Color
  var secondary: Color

  /// White-forward, so a themed component rendered outside an injected
  /// destination reads as chrome rather than borrowing a hue nobody gave it.
  /// The secondary is the displays' own, the one hue that belongs to no
  /// section.
  static let neutral = SettingsAccent(
    accent: .white, secondary: Color(red: 0.30, green: 0.41, blue: 0.84))

  /// The built-in has a fixed cool hue; externals cycle by sidebar position,
  /// so two panels attached at once never light the window the same way.
  static func display(isBuiltIn: Bool, ordinal: Int) -> SettingsAccent {
    guard !isBuiltIn else {
      return SettingsAccent(
        accent: Color(red: 0.69, green: 0.76, blue: 0.90), secondary: neutral.secondary)
    }
    // Both cool on purpose: warm light means CARE, and a display page is
    // somewhere you adjust a display rather than a care pillar.
    let hues = [
      Color(red: 0.36, green: 0.57, blue: 0.90),
      Color(red: 0.38, green: 0.72, blue: 0.68),
    ]
    let index = ((ordinal % hues.count) + hues.count) % hues.count
    return SettingsAccent(accent: hues[index], secondary: neutral.secondary)
  }
}

private struct SettingsAccentKey: EnvironmentKey {
  static let defaultValue = SettingsAccent.neutral
}

extension EnvironmentValues {
  /// Read by every themed component, so a page tints its subtree once instead
  /// of threading an accent through every call site.
  var settingsAccent: SettingsAccent {
    get { self[SettingsAccentKey.self] }
    set { self[SettingsAccentKey.self] = newValue }
  }
}
