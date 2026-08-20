#if DEBUG
  import SwiftUI

  /// One display's page, re-imagined in the guided setup flow's language: the
  /// lit display object is the page's opening image and doubles as its header,
  /// and the brightness slider drives the glyph's own face so the control and
  /// the picture of the thing it controls are the same object.
  ///
  /// Fixture-driven and inert. Every control binds to local state; nothing here
  /// reads or writes a pref, and no engine type is named.
  struct SettingsMockDisplayPage: View {
    var display: SettingsMockDisplay

    @State private var brightness: Double
    @State private var contrast: Double
    @State private var volume: Double
    @State private var sizeIndex = 0
    @State private var refreshIndex = 0
    @State private var rememberSize = true
    @State private var showInMenuBar = true
    @State private var useKeys = true
    @State private var oledEnrolled = true
    /// The last chevron clicked, so a drill-in row does something visible in a
    /// mock that has nowhere to drill in to.
    @State private var opened: String?

    /// Same call shape as the memberwise init the shell uses; the values start
    /// at the fixture's rather than flashing a default for one frame.
    init(display: SettingsMockDisplay) {
      self.display = display
      _brightness = State(initialValue: display.brightness)
      _contrast = State(initialValue: display.contrast)
      _volume = State(initialValue: display.volume)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        hero
        levelsSection
        displaySection
        menuBarSection
        navigationSection
      }
      // The shell has one page identity for all three displays, so switching
      // displays reuses this state unless it is re-seeded by hand.
      .onChange(of: display.id) { _, _ in reseed() }
    }

    // MARK: - Hero

    private var hero: some View {
      VStack(spacing: 12) {
        Group {
          if display.isBuiltIn {
            MockLaptopGlyph(aspect: display.aspect, accent: display.accent, lit: glyphLit)
          } else {
            DisplayGlyph(aspect: display.aspect, accent: display.accent, lit: glyphLit)
          }
        }
        .frame(width: 230, height: 168)
          // Depth, not glow: the face's own brightness is the live signal.
          .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
          .animation(.easeOut(duration: 0.12), value: brightness)

        VStack(spacing: 6) {
          Text(verbatim: display.name)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(OnboardingStyle.titleColor)
          Text(verbatim: "\(display.sizeLine) · \(display.refreshLine)")
            .font(.callout)
            .foregroundStyle(OnboardingStyle.bodyColor)
          HStack(spacing: 6) {
            if display.isOled {
              MockBadge(text: "OLED", accent: display.accent)
            }
            MockBadge(
              text: display.isBuiltIn ? "Built-in" : "Connected", accent: display.accent)
          }
          .padding(.top, 2)
          Text(verbatim: display.controlLine)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
      }
      .frame(maxWidth: .infinity)
    }

    /// Never fully black: an unlit glyph reads as a broken page rather than as
    /// a dim display.
    private var glyphLit: Double { 0.18 + 0.82 * brightness }

    // MARK: - Levels

    private var levelsSection: some View {
      MockSection(title: "Levels", accent: display.accent) {
        MockRow(
          label: "Brightness", caption: brightnessCaption, symbol: "sun.max.fill",
          accent: display.accent
        ) {
          slider($brightness)
        }
        MockDivider()
        MockRow(
          label: "Contrast", symbol: "circle.righthalf.filled", accent: display.accent
        ) {
          slider($contrast)
        }
        if display.hasVolume {
          MockDivider()
          MockRow(
            label: "Volume", caption: "The volume keys move this same level.",
            symbol: "speaker.wave.2.fill", accent: display.accent
          ) {
            slider($volume)
          }
        } else if !display.isBuiltIn {
          MockDivider()
          MockRow(
            label: "Volume",
            caption: "This display reports no volume command, so the slider stays off.",
            symbol: "speaker.slash.fill", accent: display.accent
          ) {
            HStack(spacing: 10) {
              MockSlider(value: .constant(0), accent: display.accent)
                .frame(width: 240)
              Text(verbatim: "Off")
                .font(.caption)
                .foregroundStyle(OnboardingStyle.bodyColor)
                .frame(width: 38, alignment: .trailing)
            }
            .disabled(true)
            .opacity(0.4)
          }
        }
      }
    }

    private func slider(_ value: Binding<Double>) -> some View {
      HStack(spacing: 10) {
        MockSlider(value: value, accent: display.accent)
          .frame(width: 240)
        Text(verbatim: Self.percent(value.wrappedValue))
          .font(.caption.monospacedDigit())
          .foregroundStyle(OnboardingStyle.bodyColor)
          .frame(width: 38, alignment: .trailing)
      }
    }

    /// A remembered value is never presented with a measurement's confidence.
    private var brightnessCaption: String? {
      if display.isBuiltIn {
        return "macOS sets this display's brightness directly."
      }
      // The mock rig has one write-only display and it is the OLED one; the
      // real page asks the controller's own readback evidence.
      if display.isOled {
        return "Shown as last set: this display doesn't report its values."
      }
      return "This display answers reads, so the level shown is the level measured."
    }

    // MARK: - Display

    private var displaySection: some View {
      MockSection(title: "Display", accent: display.accent) {
        MockRow(
          label: "Size", caption: sizeCaption, symbol: "rectangle.inset.filled",
          accent: display.accent
        ) {
          MockPopUpValue(options: sizeOptions, index: $sizeIndex, accent: display.accent)
        }
        MockDivider()
        MockRow(label: "Refresh Rate", symbol: "timer", accent: display.accent) {
          MockPopUpValue(
            options: refreshOptions, index: $refreshIndex, accent: display.accent)
        }
        MockDivider()
        MockRow(
          label: "Remember this size",
          caption:
            "Puts this display back to it when it reconnects or \(AppInfo.productName) launches.",
          symbol: "pin.fill", accent: display.accent
        ) {
          MockToggle(isOn: $rememberSize, accent: display.accent)
        }
      }
    }

    /// Plausible neighbours for the mock, first entry matching the fixture; the
    /// real page offers what the mode catalog reports.
    private var sizeOptions: [String] {
      if display.isBuiltIn {
        return [display.sizeLine, "1352 x 878", "1710 x 1112"]
      }
      if display.aspect < 1 {
        return [display.sizeLine, "1620 x 2880", "1080 x 1920"]
      }
      return [display.sizeLine, "2752 x 1152", "1720 x 720"]
    }

    private var refreshOptions: [String] {
      display.refreshLine == "60 Hz" ? [display.refreshLine] : [display.refreshLine, "60 Hz"]
    }

    private var sizeCaption: String {
      sizeIndex == 0
        ? "This is the display's own size."
        : "Everything is drawn larger; the display still runs at its own size."
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
      MockSection(title: "In the Menu Bar", accent: display.accent) {
        MockRow(
          label: "Show this display", caption: "Its sliders appear in the menu bar.",
          symbol: "menubar.rectangle", accent: display.accent
        ) {
          MockToggle(isOn: $showInMenuBar, accent: display.accent)
        }
        MockDivider()
        MockRow(
          label: "Use the brightness keys for it", symbol: "keyboard",
          accent: display.accent
        ) {
          MockToggle(isOn: $useKeys, accent: display.accent)
        }
      }
    }

    // MARK: - Navigation

    private var navigationSection: some View {
      VStack(alignment: .leading, spacing: 6) {
        MockSection(accent: display.accent) {
          if display.isOled {
            MockRow(
              label: "OLED Care",
              caption: "Dims this display once it has been idle, and counts its hours.",
              symbol: "shield.lefthalf.filled", accent: display.accent
            ) {
              MockToggle(isOn: $oledEnrolled, accent: display.accent)
            }
            MockDivider()
          }
          MockChevronRow(
            label: "All Sizes and Refresh Rates", value: allSizesCount,
            symbol: "list.bullet", accent: display.accent,
            action: { open("All Sizes and Refresh Rates") })
          MockDivider()
          MockChevronRow(
            label: "Advanced", value: "Nothing changed", symbol: "slider.horizontal.3",
            accent: display.accent, action: { open("Advanced") })
          MockDivider()
          MockChevronRow(
            label: "Diagnostics", value: readbackVerdict, symbol: "stethoscope",
            accent: display.accent, action: { open("Diagnostics") })
        }
        if let opened {
          Text(verbatim: "\(opened) opens as its own page. This mock doesn't navigate.")
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .padding(.leading, 4)
            .transition(.opacity)
        }
      }
    }

    /// Mock counts, not a claim about any of these displays.
    private var allSizesCount: String {
      if display.isBuiltIn { return "14" }
      return display.isOled ? "22" : "31"
    }

    private var readbackVerdict: String {
      if display.isBuiltIn { return "Driven by macOS" }
      return display.isOled ? "Never answers reads" : "Answers reads"
    }

    private func open(_ destination: String) {
      withAnimation(.easeOut(duration: 0.2)) { opened = destination }
    }

    // MARK: - State

    private func reseed() {
      brightness = display.brightness
      contrast = display.contrast
      volume = display.volume
      sizeIndex = 0
      refreshIndex = 0
      opened = nil
    }

    private static func percent(_ value: Double) -> String {
      "\(Int((value * 100).rounded()))%"
    }
  }

  /// A pop-up button in the flow's language: the value, a hover lift, and a
  /// click that cycles the options. Cycling rather than opening a real menu
  /// keeps the mock free of menu plumbing while still feeling live.
  private struct MockPopUpValue: View {
    var options: [String]
    @Binding var index: Int
    var accent: Color

    @State private var hovering = false

    var body: some View {
      Button {
        guard !options.isEmpty else { return }
        index = (index + 1) % options.count
      } label: {
        HStack(spacing: 7) {
          Text(verbatim: options.indices.contains(index) ? options[index] : "")
            .foregroundStyle(OnboardingStyle.titleColor)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(hovering ? accent : OnboardingStyle.faintColor)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.12 : 0.07))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(
              hovering ? accent.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
#endif
