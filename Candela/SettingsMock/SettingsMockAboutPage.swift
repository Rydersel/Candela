#if DEBUG
  import SwiftUI

  /// About as the window's rest note: the app as one quiet mark, the
  /// version under it, then quiet rows that go somewhere. No update controls
  /// (those belong to Updates) and no dense text, so the eye lands and stops.
  struct SettingsMockAboutPage: View {
    var accent: Color

    @State private var acknowledgementsOpen = false

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        hero

        MockSection(title: "Elsewhere", accent: accent) {
          MockChevronRow(
            label: "Website", value: "candela.fyi", symbol: "globe", accent: accent)
          MockDivider()
          MockChevronRow(
            label: "Release Notes", value: nil, symbol: "text.append", accent: accent)
          MockDivider()
          MockChevronRow(
            label: "License", value: "MIT", symbol: "doc.plaintext", accent: accent)
        }

        MockSection(title: "Credits", accent: accent) {
          MockAboutDisclosure(
            label: "Acknowledgements", accent: accent, isOpen: $acknowledgementsOpen
          ) {
            VStack(alignment: .leading, spacing: 9) {
              MockAboutCredit(
                name: "MonitorControl",
                detail: "MIT, the DDC transport and the behavior this app is measured against")
              MockAboutCredit(name: "MediaKeyTap", detail: "MIT, Nicholas Hurden")
              MockAboutCredit(name: "KeyboardShortcuts", detail: "MIT, Sindre Sorhus")
              MockAboutCredit(name: "Sparkle", detail: "MIT, the Sparkle Project")
            }
          }
          MockDivider()
          MockRow(
            label: "Run Setup Again",
            caption: "Walks through the keys, the permission and the OLED questions one more time.",
            symbol: "sparkles", accent: accent
          ) {
            Button("Open") {}
              .buttonStyle(MockSecondaryButtonStyle())
          }
        }

        Text(copyrightLine)
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.top, 4)
      }
    }

    // MARK: - Hero

    /// The mark floats over a soft halo rather than sitting in a frame: About
    /// is the one page with nothing to configure, so the object is the
    /// content, and it is the only object left in the mock that moves on its
    /// own.
    private var hero: some View {
      VStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(accent.opacity(0.14))
            .frame(width: 168, height: 168)
            .blur(radius: 44)
          Circle()
            .stroke(accent.opacity(0.10), lineWidth: 1)
            .frame(width: 138, height: 138)
          Circle()
            .stroke(accent.opacity(0.16), lineWidth: 1)
            .frame(width: 108, height: 108)
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 92, height: 92)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .frame(height: 176)
        .onboardingFloat(active: true)
        .accessibilityHidden(true)

        Text(AppInfo.productName)
          .font(.system(size: 30, weight: .bold, design: .rounded))
          .foregroundStyle(OnboardingStyle.titleColor)

        Text("Version \(AppInfo.version) (build \(AppInfo.build))")
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .monospacedDigit()

        // A credit, kept one step quieter than the version line so the hero
        // still reads version first.
        Text(verbatim: "Ryder Selikow")
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
    }

    private var copyrightLine: String {
      let year = Calendar.current.component(.year, from: Date())
      return "\u{00A9} \(year) \(AppInfo.productName) contributors. MIT licensed."
    }
  }

  // MARK: - Page parts

  /// A row that folds a list open in place, so the acknowledgements are one
  /// click away without being a page of their own.
  private struct MockAboutDisclosure<Content: View>: View {
    var label: String
    var accent: Color
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
      VStack(alignment: .leading, spacing: 9) {
        Button {
          withAnimation(.easeInOut(duration: 0.25)) { isOpen.toggle() }
        } label: {
          HStack(spacing: 12) {
            Text(label)
              .foregroundStyle(OnboardingStyle.titleColor)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(isOpen || hovering ? accent : OnboardingStyle.faintColor)
              .rotationEffect(.degrees(isOpen ? 90 : 0))
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

        if isOpen {
          content
            .padding(.leading, 34)
            .padding(.bottom, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .clipped()
    }
  }

  private struct MockAboutCredit: View {
    var name: String
    var detail: String

    var body: some View {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name)
          .font(.callout.weight(.medium))
          .foregroundStyle(OnboardingStyle.bodyColor)
        Text(verbatim: detail)
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
#endif
