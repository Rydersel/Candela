#if DEBUG
  import SwiftUI

  /// Menu Bar in the guided setup flow's language: the pane's subject is drawn
  /// first as a lit object, and every control below moves it. The miniature is
  /// fed by this page's own state, so the mock stays honest about being a mock.
  struct SettingsMockMenuBarPage: View {
    var accent: Color

    @State private var iconMode = 0
    @State private var showBuiltIn = true
    @State private var showKeepAwake = true
    @State private var showContrast = false
    @State private var snapSteps = true
    @State private var showPercent = true
    @State private var indicatorStyle = 0
    @State private var brightnessAnchor = 2
    @State private var volumeAnchor = 1

    /// The mock rig always has an external attached, so only "Never" can take
    /// the icon away here.
    private var iconVisible: Bool { iconMode != 3 }

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "Menu Bar",
          subtitle:
            "What Candela puts on screen outside its own windows: the icon, the sliders behind it, and the indicators a key press draws.",
          accent: accent)

        hero

        MockSection(title: "Menu Bar", accent: accent) {
          MenuBarChoiceRow(
            label: "Show the menu bar icon",
            caption:
              "Choose Never and Candela keeps running with no icon. Open it again from Applications to come back here.",
            symbol: "menubar.rectangle",
            options: ["Always", "With a slider", "External only", "Never"],
            selection: $iconMode,
            accent: accent)
        }

        MockSection(title: "Sliders", accent: accent) {
          MockRow(
            label: "Show the built-in display",
            caption: "Apple displays already have a brightness slider in Control Center.",
            symbol: "laptopcomputer", accent: accent
          ) {
            MockToggle(isOn: $showBuiltIn, accent: accent)
          }
          MockDivider()
          MockRow(
            label: "Show Keep Display Awake",
            caption:
              "While it is on, OLED care's idle dimming and blackout never start. Hiding the row here does not turn it off.",
            symbol: "eye.fill", accent: accent
          ) {
            MockToggle(isOn: $showKeepAwake, accent: accent)
          }
          MockDivider()
          MockRow(
            label: "Show a contrast slider",
            caption: "Displays controlled over their data cable only, and results vary by monitor.",
            symbol: "circle.lefthalf.filled", accent: accent
          ) {
            MockToggle(isOn: $showContrast, accent: accent)
          }
        }

        MockSection(title: "Slider Appearance", accent: accent) {
          MockRow(
            label: "Snap to 25% steps",
            caption: "A drag pulls to the nearest quarter, and to 0% for brightness and contrast.",
            symbol: "ruler", accent: accent
          ) {
            MockToggle(isOn: $snapSteps, accent: accent)
          }
          MockDivider()
          MockRow(
            label: "Show percentages",
            caption: "The exact value sits next to each slider.",
            symbol: "textformat.123", accent: accent
          ) {
            MockToggle(isOn: $showPercent, accent: accent)
          }
        }

        MockSection(title: "On-Screen Indicators", accent: accent) {
          MenuBarChoiceRow(
            label: "Indicator style",
            caption: "One style for every indicator, on every display.",
            symbol: "rectangle.on.rectangle",
            options: ["Match macOS", "Segmented", "Compact"],
            selection: $indicatorStyle,
            accent: accent)
          MockDivider()
          MenuBarChoiceRow(
            label: "Brightness indicator position",
            caption: "Contrast uses this position too.",
            symbol: "sun.max.fill",
            options: ["Top left", "Top center", "Top right"],
            selection: $brightnessAnchor,
            accent: accent)
          MockDivider()
          MenuBarChoiceRow(
            label: "Volume indicator position",
            caption: "Mute uses this position too, on the display the keys reach.",
            symbol: "speaker.wave.2.fill",
            options: ["Top left", "Top center", "Top right"],
            selection: $volumeAnchor,
            accent: accent)
        }

        MockSection(accent: accent) {
          MenuBarDisclosure(
            title: "Why both indicators show at once",
            accent: accent,
            detail:
              "On screen the two kinds take turns in one window per display, so you never see a brightness and a volume indicator together. The preview draws both so each position stays visible while you choose it. An indicator is drawn on the display the press acted on; when a press reaches every display, each one draws its own."
          )
        }
      }
    }

    private var hero: some View {
      VStack(alignment: .leading, spacing: 8) {
        MenuBarStripHero(
          accent: accent, iconVisible: iconVisible, style: indicatorStyle,
          brightnessAnchor: brightnessAnchor, volumeAnchor: volumeAnchor)
        HStack(spacing: 8) {
          MockBadge(text: "Preview", accent: accent)
          Text("Every control below moves this.")
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
      }
    }
  }

  // MARK: - Hero

  /// The pane's subject as a drawn object: a menu-bar capsule with the accent
  /// mark in its trailing cluster, and the indicator pills parked at their
  /// chosen anchors on the ground below it.
  private struct MenuBarStripHero: View {
    var accent: Color
    var iconVisible: Bool
    var style: Int
    var brightnessAnchor: Int
    var volumeAnchor: Int

    var body: some View {
      ZStack {
        ground
        VStack(spacing: 12) {
          strip
          pillDeck
          Spacer(minLength: 0)
        }
        .padding(12)
      }
      .frame(height: 178)
      .accessibilityHidden(true)
    }

    private var ground: some View {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color(red: 0.08, green: 0.09, blue: 0.16),
                Color(red: 0.05, green: 0.05, blue: 0.09),
              ],
              startPoint: .topLeading, endPoint: .bottomTrailing)
          )
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(accent.opacity(0.05))
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Color.white.opacity(0.09), lineWidth: 1)
      }
    }

    private var strip: some View {
      HStack(spacing: 11) {
        Image(systemName: "apple.logo").font(.system(size: 8))
        Text("Finder").font(.system(size: 8, weight: .semibold))
        Text("File").font(.system(size: 8))
        Text("Window").font(.system(size: 8))
        Spacer(minLength: 8)
        if iconVisible {
          Image(systemName: "circle.lefthalf.filled")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)
            .transition(.scale.combined(with: .opacity))
        }
        Image(systemName: "wifi").font(.system(size: 7.5))
        Image(systemName: "battery.75percent").font(.system(size: 8))
        Text("Wed 14:12").font(.system(size: 8)).fixedSize()
      }
      .foregroundStyle(Color.white.opacity(0.55))
      .padding(.horizontal, 14)
      .frame(height: 28)
      .frame(maxWidth: .infinity)
      .background(Capsule().fill(Color.black.opacity(0.55)))
      .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
      .animation(.easeOut(duration: 0.2), value: iconVisible)
    }

    private var pillDeck: some View {
      HStack(alignment: .top, spacing: 8) {
        column(0)
        column(1)
        column(2)
      }
      .animation(.easeInOut(duration: 0.28), value: brightnessAnchor)
      .animation(.easeInOut(duration: 0.28), value: volumeAnchor)
    }

    /// One anchor's stack. Brightness sits above volume when both land here,
    /// the same order the real preview keeps.
    @ViewBuilder
    private func column(_ anchor: Int) -> some View {
      VStack(alignment: horizontal(anchor), spacing: 7) {
        if brightnessAnchor == anchor {
          MenuBarIndicatorPill(
            title: SettingsMockFixtures.mag.name, symbol: "sun.max.fill",
            value: SettingsMockFixtures.mag.brightness, style: style, accent: accent)
        }
        if volumeAnchor == anchor {
          MenuBarIndicatorPill(
            title: SettingsMockFixtures.mag.name, symbol: "speaker.wave.2.fill",
            value: SettingsMockFixtures.mag.volume, style: style, accent: accent)
        }
      }
      .frame(maxWidth: .infinity, alignment: alignment(anchor))
    }

    private func horizontal(_ anchor: Int) -> HorizontalAlignment {
      switch anchor {
      case 0: .leading
      case 1: .center
      default: .trailing
      }
    }

    private func alignment(_ anchor: Int) -> Alignment {
      switch anchor {
      case 0: .topLeading
      case 1: .top
      default: .topTrailing
      }
    }
  }

  /// One indicator, at the miniature scale the strip needs. Style 2 drops the
  /// display name, which is the whole of what compact means.
  private struct MenuBarIndicatorPill: View {
    var title: String
    var symbol: String
    var value: Double
    var style: Int
    var accent: Color

    private var corner: CGFloat { style == 2 ? 13 : 12 }

    var body: some View {
      Group {
        if style == 2 {
          bar
            .padding(.horizontal, 11)
            .frame(width: 122, height: 26)
        } else {
          VStack(alignment: .leading, spacing: 5) {
            Text(title)
              .font(.system(size: 7.5, weight: .semibold))
              .foregroundStyle(Color.white.opacity(0.82))
              .lineLimit(1)
            bar
          }
          .padding(.horizontal, 11)
          .frame(width: 152, height: 42, alignment: .leading)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .fill(Color.black.opacity(0.58))
      )
      .overlay(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .stroke(Color.white.opacity(0.12), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.35), radius: 7, y: 3)
    }

    private var bar: some View {
      HStack(spacing: 7) {
        Image(systemName: symbol)
          .font(.system(size: 7.5, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.75))
        Group {
          if style == 1 {
            segmentedTrack
          } else {
            continuousTrack
          }
        }
        .frame(height: 4)
      }
    }

    private var continuousTrack: some View {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.16))
          Capsule()
            .fill(accent.opacity(0.85))
            .frame(width: max(3, proxy.size.width * value))
        }
      }
    }

    private var segmentedTrack: some View {
      let filled = Int((min(max(value, 0), 1) * 14).rounded())
      return HStack(spacing: 1.5) {
        ForEach(0..<14, id: \.self) { index in
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(index < filled ? accent.opacity(0.85) : Color.white.opacity(0.16))
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  // MARK: - Local components

  /// A choice whose options need the full row width. `MockRow` keeps its
  /// control trailing, which four segments cannot afford, so the label and its
  /// consequence sit above the segments instead.
  private struct MenuBarChoiceRow: View {
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

  /// The page's fine print, folded away: a chevron header that turns down over
  /// one paragraph, so the detail is reachable without being in the way.
  private struct MenuBarDisclosure: View {
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
