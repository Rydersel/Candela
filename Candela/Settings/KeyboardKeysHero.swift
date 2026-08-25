import CandelaKit
import SwiftUI

/// Pure derivation for the keycap hero (KMR3): every word and every lit key
/// comes from these functions, computed from the same `KeyModePolicy` rules
/// and prefs the engine reads, so the strip cannot disagree with what a key
/// press actually does. Nameable rather than inline in `body` for the
/// row-model tests (AT10).
enum KeyboardHeroModel {
  // MARK: - Cluster annotations (KMR2: the space under the keys IS the information)

  // Sentences with a verb, not noun phrases: "The brightness keys · the
  // display under the pointer" read as a caption describing the feature, and
  // the line's whole job is to state what the keys are doing RIGHT NOW
  // (Ryder, 2026-08-17).
  static func brightnessLine(mode: KeyMode, target: MultiKeyboardBrightness) -> String {
    switch mode {
    case .media: "Media keys act on \(phrase(for: target))"
    case .custom: "Custom shortcuts only; the keys go to macOS"
    case .both: "Media keys and shortcuts act on \(phrase(for: target))"
    case .disabled: "Off; the keys go to macOS"
    }
  }

  static func volumeLine(mode: KeyMode, target: MultiKeyboardVolume) -> String {
    switch mode {
    case .media: "Media keys \(verbPhrase(for: target))"
    case .custom: "Custom shortcuts only; the keys go to macOS"
    case .both: "Media keys and shortcuts \(verbPhrase(for: target))"
    case .disabled: "Off; the keys go to macOS"
    }
  }

  /// F14/F15 light only while a brightness mode watches media keys AND the
  /// alternate-keys pref accepts them; `AppModel.tapConfig` applies the same
  /// conjunction, which is the point.
  static func alternateLine(brightnessMode: KeyMode, accepted: Bool) -> String {
    alternateLit(brightnessMode: brightnessMode, accepted: accepted)
      ? "Treated as brightness keys"
      : "Left to macOS"
  }

  static func brightnessLit(mode: KeyMode) -> Bool { KeyModePolicy.watchesMediaKeys(mode) }
  static func volumeLit(mode: KeyMode) -> Bool { KeyModePolicy.watchesMediaKeys(mode) }
  static func alternateLit(brightnessMode: KeyMode, accepted: Bool) -> Bool {
    KeyModePolicy.watchesMediaKeys(brightnessMode) && accepted
  }

  /// The good-news line (KMR3). Shown only when it is true AND relevant: the
  /// grant is held and some lit key actually goes through the tap it names.
  /// When the grant is missing and warranted, the pane's warning section is
  /// the one voice and this stays nil rather than saying the same thing twice.
  static func showsAccessibilityLine(
    granted: Bool, brightnessMode: KeyMode, volumeMode: KeyMode
  ) -> Bool {
    granted && KeyModePolicy.requiresAccessibility(brightness: brightnessMode, volume: volumeMode)
  }

  // MARK: - Chevron previews (KMR4)

  /// Static on purpose: the page enumerates a fixed legend, so the row states
  /// its size, not a value that could go stale.
  static let modifiersPreview = "5 combinations"

  static func targetingPreview(
    brightnessMode: KeyMode, target: MultiKeyboardBrightness,
    fineBrightness: Bool, fineVolume: Bool
  ) -> String {
    guard brightnessMode != .disabled else { return "Keys off" }
    let steps =
      if fineBrightness, fineVolume {
        "fine steps"
      } else if !fineBrightness, !fineVolume {
        "normal steps"
      } else {
        "mixed step sizes"
      }
    return "\(shortPhrase(for: target)) · \(steps)"
  }

  // MARK: - Target phrases

  private static func phrase(for target: MultiKeyboardBrightness) -> String {
    switch target {
    case .mouse: "the display under the pointer"
    case .allScreens: "every display"
    case .focusInsteadOfMouse: "the display with the active window"
    }
  }

  /// Verb included, because the audio-matching case needs its own verb:
  /// "follow the audio output device", never "act on" it.
  private static func verbPhrase(for target: MultiKeyboardVolume) -> String {
    switch target {
    case .mouse: "act on the display under the pointer"
    case .allScreens: "act on every display"
    case .audioDeviceNameMatching: "follow the audio output device"
    }
  }

  private static func shortPhrase(for target: MultiKeyboardBrightness) -> String {
    switch target {
    case .mouse: "Under the pointer"
    case .allScreens: "Every display"
    case .focusInsteadOfMouse: "Active window"
    }
  }
}

/// The Keyboard pane's hero (KMR2): three key clusters, each annotated
/// directly beneath itself with family, mode and target on a bracket. Lit
/// keys are handled by Candela and grey ones pass to macOS, and the lighting
/// is never the only signal: the cluster's own line says the same thing, and
/// each cluster is ONE accessibility element whose label is that sentence.
struct KeyboardKeysHero: View {
  let brightnessMode: KeyMode
  let volumeMode: KeyMode
  let brightnessTarget: MultiKeyboardBrightness
  let volumeTarget: MultiKeyboardVolume
  let alternateAccepted: Bool
  let accessibilityGranted: Bool

  @Environment(\.settingsAccent) private var lighting
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 12) {
      // Wraps rather than clips when the window is narrow; each cluster
      // stays intact because it is its own unit.
      HStack(alignment: .top, spacing: 18) {
        cluster(
          heading: "Brightness & contrast",
          line: KeyboardHeroModel.brightnessLine(mode: brightnessMode, target: brightnessTarget),
          lit: KeyboardHeroModel.brightnessLit(mode: brightnessMode),
          keys: [("sun.min", "F1"), ("sun.max", "F2")]
        )
        cluster(
          heading: "Volume & mute",
          line: KeyboardHeroModel.volumeLine(mode: volumeMode, target: volumeTarget),
          lit: KeyboardHeroModel.volumeLit(mode: volumeMode),
          keys: [("speaker.slash", "F10"), ("speaker.wave.1", "F11"), ("speaker.wave.3", "F12")]
        )
        cluster(
          heading: "F14 & F15",
          line: KeyboardHeroModel.alternateLine(
            brightnessMode: brightnessMode, accepted: alternateAccepted),
          lit: KeyboardHeroModel.alternateLit(
            brightnessMode: brightnessMode, accepted: alternateAccepted),
          keys: [("sun.min", "F14"), ("sun.max", "F15")]
        )
      }
      .frame(maxWidth: .infinity)
      // A crossfade between two renderings of the same data, which `Motion`
      // leaves to its own site with its own Reduce Motion guard. Keys relight
      // under a mode change rather than snapping, so the eye follows what the
      // control below just did.
      .animation(relight, value: brightnessMode)
      .animation(relight, value: volumeMode)
      .animation(relight, value: alternateAccepted)

      if KeyboardHeroModel.showsAccessibilityLine(
        granted: accessibilityGranted, brightnessMode: brightnessMode, volumeMode: volumeMode
      ) {
        HStack(spacing: 7) {
          // Decoration beside the words, never instead of them.
          Circle()
            .fill(Color.green.opacity(0.7))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text("Accessibility granted, so the lit keys reach \(AppInfo.productName)")
            .font(.caption)
            .foregroundStyle(SettingsTheme.faintColor)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 4)
  }

  private var relight: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.25)
  }

  private func cluster(
    heading: String, line: String, lit: Bool, keys: [(glyph: String, label: String)]
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        ForEach(keys, id: \.label) { key in
          keycap(glyph: key.glyph, label: key.label, lit: lit)
        }
      }
      ClusterBracket()
        .stroke(lit ? lighting.accent.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
        .frame(height: 8)
        .padding(.horizontal, 6)
        .padding(.top, 7)
        .padding(.bottom, 6)
      VStack(spacing: 3) {
        Text(verbatim: heading)
          .font(.caption.weight(.semibold))
          .foregroundStyle(lit ? SettingsTheme.titleColor : SettingsTheme.bodyColor)
        Text(verbatim: line)
          .font(.caption2)
          .foregroundStyle(lit ? SettingsTheme.bodyColor : SettingsTheme.faintColor)
          .multilineTextAlignment(.center)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(heading) keys: \(spoken(line))"))
  }

  /// The middle dot is a visual separator, not a word; spoken as a pause.
  private func spoken(_ line: String) -> String {
    line.replacingOccurrences(of: " · ", with: ", ")
  }

  /// A drawn key: flat face, hairline edge. Watched keys read as lit through a
  /// brighter face and an accent edge, never through a glow.
  private func keycap(glyph: String, label: String, lit: Bool) -> some View {
    VStack(spacing: 3) {
      Image(systemName: glyph)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(lit ? lighting.accent : Color.white.opacity(0.38))
      Text(verbatim: label)
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(SettingsTheme.faintColor)
    }
    .frame(width: 46, height: 46)
    .background(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(Color.white.opacity(lit ? 0.11 : 0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(
          lit ? lighting.accent.opacity(0.4) : Color.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    .accessibilityHidden(true)
  }
}

/// The under-cluster bracket: an open-topped outline with rounded bottom
/// corners, the diagram idiom that ties a label to the keys above it.
private struct ClusterBracket: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let radius = min(6, rect.height)
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.maxY),
      control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
      control: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    return path
  }
}
