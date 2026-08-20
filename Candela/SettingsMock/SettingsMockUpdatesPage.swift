#if DEBUG
  import SwiftUI

  /// Updates as a single lit card: the app's own state, large enough to read
  /// from across the desk, with the two decisions a person actually makes
  /// (check now, check automatically) hanging off it. Everything else is
  /// provenance and folds away.
  ///
  /// Visual mock. Checking is theatre on a timer; nothing is fetched, nothing
  /// is installed, nothing is persisted.
  struct SettingsMockUpdatesPage: View {
    var accent: Color

    @State private var checkState: CheckState = .upToDate
    @State private var automatic = true
    @State private var lastChecked = "Last checked 12 minutes ago."
    @State private var spinning = false

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "Updates",
          subtitle:
            "\(AppInfo.productName) checks quietly in the background and always asks before installing anything.",
          accent: accent)

        hero
        automaticSection
        detailsSection
      }
    }

    // MARK: - Hero

    private var hero: some View {
      MockCard(isSelected: checkState == .available, accent: accent) {
        VStack(alignment: .leading, spacing: 18) {
          HStack(spacing: 18) {
            statusRing
            VStack(alignment: .leading, spacing: 5) {
              Text(headline)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(OnboardingStyle.titleColor)
              Text(subhead)
                .font(.callout)
                .foregroundStyle(OnboardingStyle.bodyColor)
                .fixedSize(horizontal: false, vertical: true)
              if checkState != .checking {
                Text(lastChecked)
                  .font(.caption)
                  .foregroundStyle(OnboardingStyle.faintColor)
              }
            }
            Spacer(minLength: 0)
          }

          HStack(spacing: 10) {
            switch checkState {
            case .available:
              Button("Install Update") { settle() }
                .buttonStyle(MockPrimaryButtonStyle(accent: accent))
              Button("Later") { settle() }
                .buttonStyle(MockSecondaryButtonStyle())
            case .checking:
              Button("Checking…") {}
                .buttonStyle(MockSecondaryButtonStyle())
                .disabled(true)
            case .upToDate:
              Button("Check for Updates…") { check() }
                .buttonStyle(MockSecondaryButtonStyle())
            }
            Spacer(minLength: 0)
            if checkState == .available {
              MockBadge(text: "Signed", accent: accent)
            }
          }
        }
      }
      .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    /// The state, drawn once and large: a quiet ring that means up to date, an
    /// arrow that means there is something waiting, a turning one while it asks.
    private var statusRing: some View {
      ZStack {
        Circle()
          .fill(accent.opacity(0.10))
          .frame(width: 84, height: 84)
        Circle()
          .fill(accent.opacity(0.18))
          .frame(width: 58, height: 58)
        Circle()
          .stroke(accent.opacity(0.25), lineWidth: 1)
          .frame(width: 58, height: 58)
        Image(systemName: ringSymbol)
          .font(.system(size: 25, weight: .semibold))
          .foregroundStyle(.white)
          .rotationEffect(.degrees(checkState == .checking && spinning ? 360 : 0))
      }
      .frame(width: 84, height: 84)
    }

    private var ringSymbol: String {
      switch checkState {
      case .upToDate: "checkmark"
      case .checking: "arrow.triangle.2.circlepath"
      case .available: "arrow.down"
      }
    }

    private var headline: String {
      switch checkState {
      case .upToDate: "\(AppInfo.productName) \(AppInfo.version) is up to date"
      case .checking: "Checking for updates"
      case .available: "Version \(Self.offeredVersion) is ready to install"
      }
    }

    private var subhead: String {
      switch checkState {
      case .upToDate: "Build \(AppInfo.build), the newest release available."
      case .checking: "Asking the update feed what the newest release is."
      case .available: "Per-display schedules for OLED care, and a fix for rotated displays."
      }
    }

    // MARK: - Sections

    private var automaticSection: some View {
      MockSection(title: "Automatic Updates", accent: accent) {
        MockRow(
          label: "Check for updates automatically",
          caption: "About once a day, in the background, and never without telling you.",
          symbol: "clock.arrow.circlepath", accent: accent
        ) {
          MockToggle(isOn: $automatic, accent: accent)
        }
        MockDivider()
        MockChevronRow(
          label: "Release Notes", value: AppInfo.version, symbol: "doc.plaintext",
          accent: accent, action: {})
      }
    }

    private var detailsSection: some View {
      MockSection(title: "Details", accent: accent) {
        detailRow(
          label: "Installed version", value: "\(AppInfo.version) (build \(AppInfo.build))",
          symbol: "number")
        MockDivider()
        detailRow(label: "Update feed", value: "candela.fyi", symbol: "antenna.radiowaves.left.and.right")
        MockDivider()
        detailRow(label: "Downloads", value: "Verified before install", symbol: "checkmark.seal")
        MockDivider()
        Disclosure(label: "How an update is checked", accent: accent) {
          Text(
            "Each release is signed with the project's key. \(AppInfo.productName) verifies that signature before it opens anything, and discards a download that fails the check."
          )
          .font(.caption)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
      }
    }

    private func detailRow(label: String, value: String, symbol: String) -> some View {
      MockRow(label: label, symbol: symbol, accent: accent) {
        Text(value)
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
      }
    }

    // MARK: - Mock behaviour

    private static let offeredVersion = "0.2.0"

    /// Alternates outcomes so both resting states are reachable by clicking.
    private func check() {
      guard checkState != .checking else { return }
      let outcome: CheckState = checkState == .available ? .upToDate : .available
      withAnimation(.easeInOut(duration: 0.3)) { checkState = .checking }
      withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spinning = true }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.6))
        // The spin is a repeatForever animation; ending it inside a normal
        // transaction would animate the ring back to zero over the same
        // forever curve, so it stops explicitly.
        var stop = Transaction()
        stop.disablesAnimations = true
        withTransaction(stop) { spinning = false }
        lastChecked = "Last checked just now."
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { checkState = outcome }
      }
    }

    /// Both answers to an offer return the card to its resting state, so the
    /// mock can be clicked through in a loop rather than stranded on one state.
    private func settle() {
      withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { checkState = .upToDate }
    }

    private enum CheckState {
      case upToDate
      case checking
      case available
    }

    // MARK: - Local components

    /// Provenance that only appears when asked for, so the page stays about
    /// the two decisions above it.
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
  }
#endif
