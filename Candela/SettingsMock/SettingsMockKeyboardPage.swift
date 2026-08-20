#if DEBUG
  import SwiftUI

  /// Keyboard in the guided setup flow's language: a row of lit keycaps answers
  /// "what do my keys do right now", and the mode choices under it relight the
  /// keys as they change. Every line is derived from this page's own state, so
  /// the strip and the controls can never disagree inside the mock.
  struct SettingsMockKeyboardPage: View {
    var accent: Color

    /// 0 the keys, 1 custom shortcuts, 2 both, 3 nothing.
    @State private var brightnessMode = 0
    @State private var volumeMode = 0
    @State private var acceptAlternate = true

    private static let modeOptions = ["The keys", "Shortcuts", "Both", "Nothing"]

    private func watchesKeys(_ mode: Int) -> Bool { mode == 0 || mode == 2 }
    private func firesShortcuts(_ mode: Int) -> Bool { mode == 1 || mode == 2 }

    private var alternateLit: Bool { watchesKeys(brightnessMode) && acceptAlternate }

    /// A sentence with a verb, not a noun phrase: the line's whole job is to
    /// say what those keys are doing right now.
    private func modeLine(_ mode: Int) -> String {
      switch mode {
      case 0: "The keys act on the display under the pointer"
      case 1: "Custom shortcuts only; the keys go to macOS"
      case 2: "Keys and shortcuts act on the display under the pointer"
      default: "Off; the keys go to macOS"
      }
    }

    private var targetingPreview: String {
      if brightnessMode == 3, volumeMode == 3 { return "Keys off" }
      return "Under the pointer, normal steps"
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "Keyboard",
          subtitle:
            "Which keys Candela handles, and which display they reach. Lit keys are handled here; grey ones go straight to macOS.",
          accent: accent)

        hero

        MockSection(title: "Brightness and Contrast Keys", accent: accent) {
          KeyChoiceRow(
            label: "Control brightness with",
            caption: "Contrast rides the same keys, held with Control, Option and Command.",
            symbol: "sun.max.fill",
            options: Self.modeOptions,
            selection: $brightnessMode,
            accent: accent)

          if firesShortcuts(brightnessMode) {
            MockDivider()
            MockRow(
              label: "Brightness down",
              caption: "A shortcut has to include a modifier, or it would be captured in every app.",
              symbol: "sun.min", accent: accent
            ) {
              ShortcutChip(glyphs: ["⌃", "⌥"], key: "F1", accent: accent)
            }
            MockDivider()
            MockRow(label: "Brightness up", symbol: "sun.max", accent: accent) {
              ShortcutChip(glyphs: ["⌃", "⌥"], key: "F2", accent: accent)
            }
          }

          if watchesKeys(brightnessMode) {
            MockDivider()
            MockRow(
              label: "Also accept F14 and F15",
              caption: "The brightness keys on some third-party keyboards, and Scroll Lock and Pause on others.",
              symbol: "keyboard", accent: accent
            ) {
              MockToggle(isOn: $acceptAlternate, accent: accent)
            }
          }
        }

        MockSection(title: "Volume Keys", accent: accent) {
          KeyChoiceRow(
            label: "Control volume with",
            caption: "Reaches external displays that accept volume over their data cable.",
            symbol: "speaker.wave.2.fill",
            options: Self.modeOptions,
            selection: $volumeMode,
            accent: accent)

          if firesShortcuts(volumeMode) {
            MockDivider()
            MockRow(label: "Volume down", symbol: "speaker.wave.1", accent: accent) {
              ShortcutChip(glyphs: ["⌃", "⌥"], key: "F11", accent: accent)
            }
            MockDivider()
            MockRow(label: "Volume up", symbol: "speaker.wave.3", accent: accent) {
              ShortcutChip(glyphs: ["⌃", "⌥"], key: "F12", accent: accent)
            }
            MockDivider()
            MockRow(
              label: "Mute",
              caption: "Muting over the data cable is a hardware mute, and unmuting comes back the same way.",
              symbol: "speaker.slash", accent: accent
            ) {
              ShortcutChip(glyphs: ["⌃", "⌥"], key: "F10", accent: accent)
            }
          }
        }

        MockSection(title: "More", accent: accent) {
          MockChevronRow(
            label: "Modifier Keys", value: "5 combinations", symbol: "command",
            accent: accent)
          MockDivider()
          MockChevronRow(
            label: "Targeting and Precision", value: targetingPreview,
            symbol: "scope", accent: accent)
        }

        MockSection(accent: accent) {
          KeyboardDisclosure(
            title: "How a press finds its display",
            accent: accent,
            detail:
              "A brightness press adjusts whichever display the pointer is over, unless targeting is set to follow the active window or to move every display at once. A volume press can follow the audio output device instead, and while macOS reports an output device the volume keys go to it whenever no display those keys reach can take the command."
          )
        }
      }
    }

    private var hero: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 18) {
          KeyCluster(
            heading: "Brightness and contrast",
            line: modeLine(brightnessMode),
            lit: watchesKeys(brightnessMode),
            keys: [("sun.min", "F1"), ("sun.max", "F2")],
            accent: accent)
          KeyCluster(
            heading: "Volume and mute",
            line: modeLine(volumeMode),
            lit: watchesKeys(volumeMode),
            keys: [("speaker.slash", "F10"), ("speaker.wave.1", "F11"), ("speaker.wave.3", "F12")],
            accent: accent)
          KeyCluster(
            heading: "F14 and F15",
            line: alternateLit ? "Treated as brightness keys" : "Left to macOS",
            lit: alternateLit,
            keys: [("sun.min", "F14"), ("sun.max", "F15")],
            accent: accent)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.25), value: brightnessMode)
        .animation(.easeOut(duration: 0.25), value: volumeMode)
        .animation(.easeOut(duration: 0.25), value: acceptAlternate)

        if watchesKeys(brightnessMode) || watchesKeys(volumeMode) {
          HStack(spacing: 7) {
            // Decoration beside the words, never instead of them.
            Circle()
              .fill(Color.green.opacity(0.7))
              .frame(width: 7, height: 7)
            Text("Accessibility granted, so the lit keys reach Candela")
              .font(.caption)
              .foregroundStyle(OnboardingStyle.faintColor)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Hero

  /// One key family: its caps, a bracket tying them to their sentence, and the
  /// sentence itself. The lighting is never the only signal; the line says the
  /// same thing in words.
  private struct KeyCluster: View {
    var heading: String
    var line: String
    var lit: Bool
    var keys: [(glyph: String, label: String)]
    var accent: Color

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 7) {
          ForEach(keys, id: \.label) { key in
            HeroKeycap(glyph: key.glyph, label: key.label, lit: lit, accent: accent)
          }
        }
        KeyClusterBracket()
          .stroke(
            lit ? accent.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1
          )
          .frame(height: 8)
          .padding(.horizontal, 6)
          .padding(.top, 7)
          .padding(.bottom, 6)
        VStack(spacing: 3) {
          Text(heading)
            .font(.caption.weight(.semibold))
            .foregroundStyle(lit ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
          Text(line)
            .font(.caption2)
            .foregroundStyle(lit ? OnboardingStyle.bodyColor : OnboardingStyle.faintColor)
            .multilineTextAlignment(.center)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .top)
    }
  }

  /// A drawn key: flat face, hairline edge. The watched ones read as lit
  /// through a brighter face and an accent edge, never through a glow.
  private struct HeroKeycap: View {
    var glyph: String
    var label: String
    var lit: Bool
    var accent: Color

    var body: some View {
      VStack(spacing: 3) {
        Image(systemName: glyph)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(lit ? accent : Color.white.opacity(0.38))
        Text(label)
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(OnboardingStyle.faintColor)
      }
      .frame(width: 46, height: 46)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(Color.white.opacity(lit ? 0.11 : 0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(
            lit ? accent.opacity(0.4) : Color.white.opacity(0.10), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
  }

  /// The open-topped outline that ties a cluster's caps to its sentence.
  private struct KeyClusterBracket: Shape {
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

  // MARK: - Local components

  /// Four options will not fit trailing a label, so this row stacks: label and
  /// its consequence above, segments below.
  private struct KeyChoiceRow: View {
    var label: String
    var caption: String?
    var symbol: String?
    var options: [String]
    @Binding var selection: Int
    var accent: Color

    var body: some View {
      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(label)
              .foregroundStyle(OnboardingStyle.titleColor)
            if let caption {
              Text(caption)
                .font(.caption)
                .foregroundStyle(OnboardingStyle.faintColor)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: 8)
        }
        MockSegments(options: options, selection: $selection, accent: accent)
          .padding(.leading, symbol == nil ? 0 : 34)
      }
      .padding(.vertical, 7)
    }
  }

  /// A recorded combination, drawn in the keycap vocabulary at row scale.
  private struct ShortcutChip: View {
    var glyphs: [String]
    var key: String
    var accent: Color

    var body: some View {
      HStack(spacing: 4) {
        ForEach(glyphs, id: \.self) { glyph in
          chip(Text(verbatim: glyph).font(.callout))
        }
        chip(Text(key).font(.caption.weight(.medium)))
      }
    }

    private func chip(_ content: some View) -> some View {
      content
        .foregroundStyle(OnboardingStyle.titleColor)
        .frame(minWidth: 16)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(accent.opacity(0.3), lineWidth: 1)
        )
    }
  }

  /// The page's fine print, folded away: a chevron header that turns down over
  /// one paragraph, so the detail is reachable without being in the way.
  private struct KeyboardDisclosure: View {
    var title: String
    var accent: Color
    var detail: String

    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          withAnimation(.easeInOut(duration: 0.22)) { isOpen.toggle() }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(isOpen || hovering ? accent : OnboardingStyle.faintColor)
              .rotationEffect(.degrees(isOpen ? 90 : 0))
              .frame(width: 12)
            Text(title)
              .foregroundStyle(OnboardingStyle.titleColor)
            Spacer(minLength: 8)
          }
          .padding(.vertical, 7)
          .padding(.horizontal, 6)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.white.opacity(hovering ? 0.06 : 0))
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)

        if isOpen {
          Text(detail)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 22)
            .padding(.trailing, 6)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
    }
  }
#endif
