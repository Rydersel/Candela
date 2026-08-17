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

  var body: some View {
    VStack(spacing: 12) {
      // Wraps rather than clips when the window is narrow; each cluster
      // stays intact because it is its own unit.
      HStack(alignment: .top, spacing: 22) {
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

      if KeyboardHeroModel.showsAccessibilityLine(
        granted: accessibilityGranted, brightnessMode: brightnessMode, volumeMode: volumeMode
      ) {
        HStack(spacing: 5) {
          // Decoration beside the words, never instead of them.
          Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text("Accessibility granted, so the lit keys reach \(AppInfo.productName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 6)
  }

  private func cluster(
    heading: String, line: String, lit: Bool, keys: [(glyph: String, label: String)]
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        ForEach(keys, id: \.label) { key in
          keycap(glyph: key.glyph, label: key.label, lit: lit)
        }
      }
      ClusterBracket()
        .stroke(lit ? AnyShapeStyle(Color.accentColor.opacity(0.45)) : AnyShapeStyle(.quaternary), lineWidth: 1)
        .frame(height: 7)
        .padding(.horizontal, 5)
        .padding(.top, 8)
        .padding(.bottom, 7)
      VStack(spacing: 1) {
        Text(verbatim: heading)
          .font(.caption.weight(.semibold))
          .foregroundStyle(lit ? .primary : .secondary)
        Text(verbatim: line)
          .font(.caption2)
          .foregroundStyle(lit ? .secondary : .tertiary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 185)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(heading) keys: \(spoken(line))"))
  }

  /// The middle dot is a visual separator, not a word; spoken as a pause.
  private func spoken(_ line: String) -> String {
    line.replacingOccurrences(of: " · ", with: ", ")
  }

  private func keycap(glyph: String, label: String, lit: Bool) -> some View {
    VStack(spacing: 2) {
      Image(systemName: glyph)
        .font(.system(size: 13))
        .foregroundStyle(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
      Text(verbatim: label)
        .font(.system(size: 7.5, weight: .medium))
        .foregroundStyle(.tertiary)
    }
    .frame(width: 38, height: 38)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(.quaternary.opacity(0.4))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .stroke(
          lit ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.quaternary),
          lineWidth: 1)
    )
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
