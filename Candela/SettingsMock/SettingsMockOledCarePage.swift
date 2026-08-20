#if DEBUG
  import SwiftUI

  /// OLED Care re-imagined in the guided setup flow's language: the protection
  /// story plays as theater at the top, each display is its own lit card, and
  /// the statistics fold away behind Details so the page reads as drama first
  /// and data second. Nothing here reads or writes a pref; every control is
  /// local state.
  struct SettingsMockOledCarePage: View {
    var accent: Color

    @State private var hideMenuBar = true
    @State private var hideDock = false
    /// Displays the user has hand-marked, so the quiet non-OLED rows still
    /// answer a click.
    @State private var marked: Set<String> = []

    private var oleds: [SettingsMockDisplay] {
      SettingsMockFixtures.displays.filter { $0.isOled }
    }

    private var others: [SettingsMockDisplay] {
      SettingsMockFixtures.displays.filter { !$0.isOled }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "OLED Care",
          subtitle:
            "\(AppInfo.productName) protects an OLED the only two ways software can: show fewer bright pixels, and show them for less time.",
          accent: accent)

        hero

        VStack(alignment: .leading, spacing: 8) {
          MockCareSectionTitle(text: "Displays", accent: accent)
          ForEach(oleds) { display in
            MockCareDisplayCard(display: display, accent: accent)
          }
          if !others.isEmpty {
            quietDisplays
          }
          Text("Wear accumulates where bright, unchanging content sits, so the cards above show where each display is spending its light.")
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
            .padding(.leading, 4)
            .fixedSize(horizontal: false, vertical: true)
        }

        chrome
      }
    }

    // MARK: - Hero

    /// The demonstration carries the explanation (the flow's OB5 move): the
    /// loop shows the shield and the dim happening, and the copy beside it only
    /// says when.
    private var hero: some View {
      MockCard {
        HStack(alignment: .center, spacing: 22) {
          OnboardingCareDemo(accent: accent, aspect: oleds.first?.aspect ?? 16.0 / 9.0)
            .frame(width: 208, height: 132)
          VStack(alignment: .leading, spacing: 8) {
            Text("Protection, while you are away")
              .font(.system(size: 17, weight: .bold, design: .rounded))
              .foregroundStyle(OnboardingStyle.titleColor)
            Text("When you step away, \(AppInfo.productName) eases brightness down and shields the areas that never change, then puts everything back the moment you touch the keyboard.")
              .font(.callout)
              .foregroundStyle(OnboardingStyle.bodyColor)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }

    // MARK: - Displays that are not OLED

    /// Listed rather than hidden: a display missing from the page reads as a
    /// bug, and the row is where a wrong guess gets corrected.
    private var quietDisplays: some View {
      MockCard {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(others.enumerated()), id: \.element.id) { pair in
            if pair.offset > 0 { MockDivider() }
            quietRow(for: pair.element)
          }
        }
      }
    }

    private func quietRow(for display: SettingsMockDisplay) -> some View {
      let isMarked = marked.contains(display.id)
      return HStack(spacing: 12) {
        DisplayGlyph(
          aspect: display.aspect, accent: .white.opacity(0.35), lit: 0.35,
          showsStand: false, showsReflection: false
        )
        .frame(width: 46, height: 30)
        VStack(alignment: .leading, spacing: 3) {
          Text(display.name)
            .foregroundStyle(OnboardingStyle.bodyColor)
          Text(
            isMarked
              ? "Marked as OLED, so care settings now apply to it."
              : "Not an OLED, so nothing on this page applies to it."
          )
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
        }
        Spacer(minLength: 12)
        if isMarked {
          MockBadge(text: "OLED", accent: accent)
        }
        Button(isMarked ? "Undo" : "Mark as OLED") {
          withAnimation(.easeOut(duration: 0.2)) {
            if isMarked { marked.remove(display.id) } else { marked.insert(display.id) }
          }
        }
        .buttonStyle(MockSecondaryButtonStyle())
      }
      .padding(.vertical, 6)
    }

    // MARK: - Screen chrome

    private var chrome: some View {
      MockSection(title: "Screen Chrome", accent: accent) {
        MockRow(
          label: "Automatically hide the menu bar",
          caption: "The brightest unchanging strip on the screen stops being drawn, at the cost of a trip to the top edge for the clock.",
          symbol: "menubar.rectangle", accent: accent
        ) {
          MockToggle(isOn: $hideMenuBar, accent: accent)
        }
        MockDivider()
        MockRow(
          label: "Automatically hide the Dock",
          caption: "Changing this restarts the Dock, which takes a moment and is visible.",
          symbol: "dock.rectangle", accent: accent
        ) {
          MockToggle(isOn: $hideDock, accent: accent)
        }
        MockDivider()
        Text("Both belong to macOS: they apply to every display, and enrolling one display never changes them.")
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .padding(.top, 8)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Section title

  /// `MockSection`'s header without its card, for the stretches of this page
  /// that are several cards rather than one.
  private struct MockCareSectionTitle: View {
    var text: String
    var accent: Color

    var body: some View {
      Text(text.uppercased())
        .font(.caption.weight(.semibold))
        .kerning(1.1)
        .foregroundStyle(accent.opacity(0.85))
        .padding(.leading, 4)
    }
  }

  // MARK: - One display

  /// An enrolled display as a quiet object: the glyph brightens while
  /// protection is on and settles back when it is off, so the switch has a
  /// visible consequence beside it rather than a paragraph under it.
  private struct MockCareDisplayCard: View {
    let display: SettingsMockDisplay
    let accent: Color

    @State private var protected = true
    @State private var dimLevel: Double = 0.5

    var body: some View {
      MockCard {
        VStack(alignment: .leading, spacing: 0) {
          header
          if protected {
            MockDivider()
            healthLine
            MockDivider()
            MockRow(
              label: "Dim to",
              caption: "How bright this display is left once it has been idle for five minutes.",
              symbol: "moon.fill", accent: accent
            ) {
              HStack(spacing: 10) {
                MockSlider(value: $dimLevel, accent: accent)
                  .frame(width: 140)
                Text("\(Int((dimLevel * 100).rounded()))%")
                  .monospacedDigit()
                  .foregroundStyle(OnboardingStyle.bodyColor)
                  .frame(width: 40, alignment: .trailing)
              }
            }
            MockDivider()
            MockCareNavRow(
              label: "Measurement and Data", value: "Measured", badge: "Recommended",
              symbol: "waveform.path.ecg", accent: accent)
            MockCareNavRow(
              label: "Display Health", value: "Even wear",
              symbol: "chart.dots.scatter", accent: accent)
            MockDivider()
            MockCareDisclosure(label: "Details", accent: accent) {
              details
            }
          }
        }
      }
      // Protection reads as a tint and a badge, not as light: the enrolled
      // card sits a shade warmer than the rest with a hairline to match.
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(accent.opacity(protected ? 0.07 : 0))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(accent.opacity(protected ? 0.34 : 0), lineWidth: 1)
      )
    }

    private var header: some View {
      HStack(spacing: 14) {
        ZStack(alignment: .bottomTrailing) {
          DisplayGlyph(
            aspect: display.aspect, accent: protected ? accent : .white.opacity(0.4),
            lit: protected ? 0.85 : 0.3, showsStand: false, showsReflection: false
          )
          .frame(width: 78, height: 44)
          Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accent)
            .padding(3)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .opacity(protected ? 1 : 0)
            .offset(x: 5, y: 4)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(display.name)
              .font(.system(size: 15, weight: .semibold, design: .rounded))
              .foregroundStyle(OnboardingStyle.titleColor)
            if protected {
              MockBadge(text: "Protected", accent: accent)
            }
          }
          Text("\(display.sizeLine) at \(display.refreshLine)")
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
        Spacer(minLength: 12)
        MockToggle(
          isOn: Binding(
            get: { protected },
            set: { on in withAnimation(.spring(duration: 0.4)) { protected = on } }),
          accent: accent)
      }
      .padding(.bottom, 8)
    }

    /// Drama, not a number: the ribbon carries the shape of the wear and the
    /// sentence says what it means. The figures behind it live under Details.
    private var healthLine: some View {
      VStack(alignment: .leading, spacing: 7) {
        Text("Wear is spread evenly across the glass, with no area running far ahead of the rest.")
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
        MockCareWearRibbon(accent: accent)
      }
      .padding(.vertical, 8)
    }

    private var details: some View {
      VStack(alignment: .leading, spacing: 9) {
        MockCareStatLine(label: "Hours of use", value: "412 in total, 6 since the last standby")
        MockCareStatLine(label: "Hottest area", value: "1.2x this display's average")
        MockCareStatLine(label: "Readings", value: "1,840 taken, one a minute")
        MockCareHistogram(accent: accent)
      }
      .padding(.bottom, 4)
    }
  }

  // MARK: - Card parts

  /// `MockChevronRow` with room for a badge, which the shared row has no slot
  /// for and which is the whole point of the recommended path.
  private struct MockCareNavRow: View {
    var label: String
    var value: String?
    var badge: String?
    var symbol: String
    var accent: Color

    @State private var hovering = false

    var body: some View {
      Button {} label: {
        HStack(spacing: 12) {
          Text(label)
            .foregroundStyle(OnboardingStyle.titleColor)
          if let badge {
            MockBadge(text: badge, accent: accent)
          }
          Spacer(minLength: 12)
          if let value {
            Text(value)
              .foregroundStyle(OnboardingStyle.bodyColor)
          }
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(hovering ? accent : OnboardingStyle.faintColor)
        }
        .padding(.vertical, 6)
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
    }
  }

  /// Folded closed: the statistics are the reward for asking, never the first
  /// thing the page says.
  private struct MockCareDisclosure<Content: View>: View {
    var label: String
    var accent: Color
    @ViewBuilder var content: Content

    @State private var open = false
    @State private var hovering = false

    var body: some View {
      VStack(alignment: .leading, spacing: 9) {
        Button {
          withAnimation(.easeInOut(duration: 0.25)) { open.toggle() }
        } label: {
          HStack(spacing: 7) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(open || hovering ? accent : OnboardingStyle.faintColor)
              .rotationEffect(.degrees(open ? 90 : 0))
            Text(label)
              .font(.callout.weight(.medium))
              .foregroundStyle(
                open || hovering ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)

        if open {
          content
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(.top, 8)
      .clipped()
    }
  }

  /// The wear map compressed to one line: deeper where the light has been
  /// spent, with the hottest cell marked by a hairline rather than a glow.
  private struct MockCareWearRibbon: View {
    var accent: Color

    private let cells: [Double] = [
      0.22, 0.31, 0.28, 0.44, 0.52, 0.61, 0.86, 0.58, 0.47, 0.39, 0.33, 0.26,
    ]

    var body: some View {
      let peak = cells.firstIndex(of: cells.max() ?? 0)
      HStack(spacing: 4) {
        ForEach(cells.indices, id: \.self) { index in
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(accent.opacity(0.12 + 0.5 * cells[index]))
            .frame(height: 10)
            .overlay(
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.white.opacity(index == peak ? 0.32 : 0), lineWidth: 1)
            )
        }
      }
      .accessibilityHidden(true)
    }
  }

  private struct MockCareStatLine: View {
    var label: String
    var value: String

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .frame(width: 96, alignment: .leading)
        Text(value)
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(OnboardingStyle.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private struct MockCareHistogram: View {
    var accent: Color

    private let buckets: [Double] = [0.14, 0.3, 0.55, 0.92, 0.48, 0.21]

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        Text("Time at brightness")
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
        HStack(alignment: .bottom, spacing: 6) {
          ForEach(buckets.indices, id: \.self) { index in
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(accent.opacity(0.5))
              .frame(height: max(4, 36 * buckets[index]))
              .frame(maxWidth: .infinity)
          }
        }
        .frame(height: 36, alignment: .bottom)
      }
      .accessibilityHidden(true)
    }
  }
#endif
