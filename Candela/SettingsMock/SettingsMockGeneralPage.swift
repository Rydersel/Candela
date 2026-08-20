#if DEBUG
  import SwiftUI

  /// General, re-imagined in the guided setup flow's language: one lit status
  /// strip saying what the app is doing right now, then the decisions about it.
  /// The reset's consequences fold into the confirmation rather than sitting on
  /// the page as a paragraph nobody reads until it matters.
  ///
  /// Visual mock. Every control binds to local state and nothing is persisted.
  struct SettingsMockGeneralPage: View {
    var accent: Color

    @State private var opensAtLogin = true
    @State private var dimPastMinimum = true
    @State private var allowFullyDark = false
    @State private var matchBuiltIn = true
    @State private var startupChoice = 0
    @State private var confirmingReset = false

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "General",
          subtitle:
            "How \(AppInfo.productName) starts, how far it dims, and what it does with your saved levels.",
          accent: accent)

        statusStrip

        applicationSection
        brightnessSection
        syncSection
        startupSection
      }
    }

    // MARK: - Hero

    /// The page's one standing object: the app itself, running, with its login state
    /// read off the same row that changes it below.
    private var statusStrip: some View {
      MockCard {
        HStack(spacing: 16) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 54, height: 54)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

          VStack(alignment: .leading, spacing: 4) {
            Text("Running from the menu bar")
              .font(.system(size: 17, weight: .bold, design: .rounded))
              .foregroundStyle(OnboardingStyle.titleColor)
            Text("No Dock icon and no window to lose: the controls live behind the icon.")
              .font(.caption)
              .foregroundStyle(OnboardingStyle.bodyColor)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: 12)

          VStack(alignment: .trailing, spacing: 6) {
            MockBadge(text: opensAtLogin ? "Opens at Login" : "Manual start", accent: accent)
            Text("3 displays connected")
              .font(.caption2)
              .foregroundStyle(OnboardingStyle.faintColor)
          }
        }
      }
      .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    // MARK: - Application

    private var applicationSection: some View {
      MockSection(title: "Application", accent: accent) {
        MockRow(
          label: "Open at Login",
          caption: "\(AppInfo.productName) starts with your Mac and restores your saved levels.",
          symbol: "power", accent: accent
        ) {
          MockToggle(isOn: $opensAtLogin, accent: accent)
        }

        MockDivider()

        HStack(spacing: 10) {
          Button("Quit \(AppInfo.productName)") {}
            .buttonStyle(MockSecondaryButtonStyle())
          Button("Reset All Settings…") {
            withAnimation(.easeOut(duration: 0.22)) { confirmingReset = true }
          }
          .buttonStyle(DangerButtonStyle())
          Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, confirmingReset ? 8 : 2)

        if confirmingReset {
          resetConfirmation
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
    }

    /// The confirmation lands inside the card it was asked for, so the page
    /// never has to explain the reset while nobody is doing one.
    private var resetConfirmation: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Self.dangerTint)
          VStack(alignment: .leading, spacing: 4) {
            Text("Reset all settings?")
              .font(.system(size: 15, weight: .bold, design: .rounded))
              .foregroundStyle(OnboardingStyle.titleColor)
            Text(
              "Your displays are put into a known state first, then every saved setting is removed and setup runs again."
            )
            .font(.caption)
            .foregroundStyle(OnboardingStyle.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        Disclosure(label: "What gets cleared", accent: accent) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(Self.resetItems, id: \.self) { item in
              HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                  .fill(accent.opacity(0.7))
                  .frame(width: 4, height: 4)
                Text(item)
                  .font(.caption)
                  .foregroundStyle(OnboardingStyle.bodyColor)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }

        HStack(spacing: 10) {
          Spacer(minLength: 0)
          Button("Cancel") {
            withAnimation(.easeOut(duration: 0.22)) { confirmingReset = false }
          }
          .buttonStyle(MockSecondaryButtonStyle())
          Button("Reset All Settings") {
            withAnimation(.easeOut(duration: 0.22)) { confirmingReset = false }
          }
          .buttonStyle(DangerButtonStyle())
        }
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Self.dangerTint.opacity(0.07))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Self.dangerTint.opacity(0.25), lineWidth: 1)
      )
      .padding(.bottom, 4)
    }

    /// One restrained red for the whole reset strand: warning enough to read as
    /// destructive, muted enough to sit beside the desaturated accent.
    fileprivate static let dangerTint = Color(red: 0.84, green: 0.42, blue: 0.40)

    private static let resetItems = [
      "Per-display tuning, names and saved brightness, volume and contrast",
      "Custom keyboard shortcuts and remembered resolutions",
      "OLED care enrollment and the counted hours of use",
      "The Open at Login registration",
    ]

    // MARK: - Brightness

    private var brightnessSection: some View {
      MockSection(title: "Brightness", accent: accent) {
        MockRow(
          label: "Dim past the display's minimum",
          caption: "Keeps dimming in software once a display reaches its own darkest setting.",
          symbol: "sun.min", accent: accent
        ) {
          MockToggle(isOn: $dimPastMinimum, accent: accent)
        }
        MockDivider()
        MockRow(
          label: "Allow a fully dark display",
          caption: "The slider can reach black, which can look like the display turned off.",
          symbol: "circle.fill", accent: accent
        ) {
          MockToggle(isOn: $allowFullyDark, accent: accent)
        }
      }
    }

    // MARK: - Sync

    private var syncSection: some View {
      MockSection(title: "Sync", accent: accent) {
        MockRow(
          label: "Match other displays to the built-in display",
          caption:
            "Ambient light, Control Center and System Settings changes carry across to your other displays.",
          symbol: "arrow.triangle.branch", accent: accent
        ) {
          MockToggle(isOn: $matchBuiltIn, accent: accent)
        }
      }
    }

    // MARK: - Startup

    private var startupSection: some View {
      MockSection(title: "On Startup and Wake", accent: accent) {
        ForEach(Self.startupOptions.indices, id: \.self) { index in
          if index > 0 { MockDivider() }
          ChoiceRow(
            title: Self.startupOptions[index].title,
            caption: Self.startupOptions[index].caption,
            badge: index == 0 ? "Recommended" : nil,
            isSelected: startupChoice == index,
            accent: accent
          ) {
            withAnimation(.easeOut(duration: 0.18)) { startupChoice = index }
          }
        }
        MockDivider()
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Image(systemName: "shift")
            .font(.caption)
          Text("Hold Shift while launching for Safe Mode: saved values are not restored.")
            .font(.caption)
        }
        .foregroundStyle(OnboardingStyle.faintColor)
        .padding(.top, 8)
        .padding(.bottom, 2)
      }
    }

    private static let startupOptions:
      [(title: String, caption: String)] = [
        (
          "Trust the last saved values",
          "Keeps using the levels from last time, and sends them the first time you change something."
        ),
        (
          "Re-send the last saved values",
          "Useful when a display forgets its settings while asleep."
        ),
        (
          "Ask the display for its current values",
          "Reads brightness, contrast and volume back. Not every display answers."
        ),
      ]

    // MARK: - Local components

    /// A radio row that carries its own consequence sentence, so a long-labelled
    /// choice does not have to survive being squeezed into a pill.
    private struct ChoiceRow: View {
      let title: String
      let caption: String
      var badge: String?
      let isSelected: Bool
      let accent: Color
      let action: () -> Void

      @State private var hovering = false

      var body: some View {
        Button(action: action) {
          HStack(alignment: .top, spacing: 12) {
            ZStack {
              Circle()
                .stroke(
                  isSelected ? accent.opacity(0.85) : Color.white.opacity(hovering ? 0.4 : 0.22),
                  lineWidth: 1
                )
                .frame(width: 15, height: 15)
              if isSelected {
                Circle()
                  .fill(accent.opacity(0.85))
                  .frame(width: 8, height: 8)
              }
            }
            .frame(width: 22, height: 20)

            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 7) {
                Text(title)
                  .font(.body.weight(isSelected ? .semibold : .regular))
                  .foregroundStyle(OnboardingStyle.titleColor)
                if let badge {
                  MockBadge(text: badge, accent: accent)
                }
              }
              Text(caption)
                .font(.caption)
                .foregroundStyle(OnboardingStyle.faintColor)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 6)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(Color.white.opacity(hovering && !isSelected ? 0.05 : 0))
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
      }
    }

    /// Detail that earns its place only once someone asks for it.
    private struct Disclosure<Content: View>: View {
      let label: String
      let accent: Color
      @ViewBuilder var content: Content

      @State private var open = false
      @State private var hovering = false

      var body: some View {
        VStack(alignment: .leading, spacing: 9) {
          Button {
            withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .rotationEffect(.degrees(open ? 90 : 0))
              Text(label)
                .font(.caption.weight(.medium))
              Spacer(minLength: 0)
            }
            .foregroundStyle(open || hovering ? accent : OnboardingStyle.faintColor)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { hovering = $0 }
          if open {
            content
              .padding(.leading, 16)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
    }

    /// The secondary button in warning red: same macOS geometry as
    /// `MockSecondaryButtonStyle`, but destructive actions should not borrow the
    /// page's accent, which everywhere else means "this is on".
    private struct DangerButtonStyle: ButtonStyle {
      func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
      }

      private struct HoverLabel: View {
        let configuration: Configuration
        @State private var hovering = false

        private static let danger = SettingsMockGeneralPage.dangerTint

        var body: some View {
          configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(hovering ? Color.white : Self.danger)
            .padding(.horizontal, 14)
            .padding(.vertical, 5.5)
            .background(
              RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(
                  Self.danger.opacity(configuration.isPressed ? 0.38 : (hovering ? 0.28 : 0.12)))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .stroke(Self.danger.opacity(hovering ? 0.5 : 0.3), lineWidth: 1)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
      }
    }
  }
#endif
