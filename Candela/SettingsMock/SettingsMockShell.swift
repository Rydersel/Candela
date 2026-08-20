#if DEBUG
  import SwiftUI

  /// The mock's whole window: hand-built dark sidebar over the drifting
  /// canvas, one page view per destination. Selection is local state; the
  /// canvas relights as the selection moves, the way the flow's acts do.
  struct SettingsMockShell: View {
    @State private var destination: SettingsMockDestination = Self.initialDestination()

    /// Capture runs cannot click the sidebar (no Accessibility grant), so the
    /// starting destination is injectable: a section's raw id or a fixture
    /// display id in CANDELA_SETTINGS_MOCK_DEST.
    private static func initialDestination() -> SettingsMockDestination {
      guard let raw = ProcessInfo.processInfo.environment["CANDELA_SETTINGS_MOCK_DEST"]
      else { return .section(.general) }
      if let section = SettingsMockSection(rawValue: raw) { return .section(section) }
      if SettingsMockFixtures.displays.contains(where: { $0.id == raw }) {
        return .display(raw)
      }
      return .section(.general)
    }

    var body: some View {
      ZStack {
        SettingsMockCanvas(
          accent: destination.accent, secondary: destination.secondary)
        HStack(spacing: 0) {
          sidebar
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
          detail
        }
      }
      .frame(minWidth: 1040, minHeight: 660)
      .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
      VStack(alignment: .leading, spacing: 2) {
        // The wordmark: the icon's C, tinted by the destination, IS the C of
        // the product name, and the header relights with the canvas.
        // Baseline-aligned and cap-height sized, so the mark reads as the
        // capital letter rather than an icon standing beside the word.
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          MockBrandMark(tint: destination.accent)
            .frame(width: 13.5, height: 13.5)
            // Seats the ring on the optical baseline and tucks it toward the
            // word; the arc's open right side reads as extra letter-spacing.
            .offset(x: 1.5, y: 1.5)
            .animation(.easeInOut(duration: 0.5), value: destination)
          Text(verbatim: String(AppInfo.productName.dropFirst()))
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(OnboardingStyle.titleColor)
        }
        .padding(.leading, 12)
        .padding(.top, 14)
        .padding(.bottom, 16)

        ForEach(SettingsMockSection.allCases) { section in
          SidebarRow(
            title: section.title, symbol: section.symbol,
            accent: section.accent,
            isSelected: destination == .section(section)
          ) { select(.section(section)) }
        }

        Text("DISPLAYS")
          .font(.caption2.weight(.semibold))
          .kerning(1.2)
          .foregroundStyle(OnboardingStyle.faintColor)
          .padding(.leading, 14)
          .padding(.top, 18)
          .padding(.bottom, 6)

        ForEach(SettingsMockFixtures.displays) { display in
          SidebarRow(
            title: display.name,
            symbol: display.isBuiltIn ? "laptopcomputer" : "display",
            accent: display.accent,
            isSelected: destination == .display(display.id)
          ) { select(.display(display.id)) }
        }

        Spacer()

        Text("Visual mock, nothing is written")
          .font(.caption2)
          .foregroundStyle(OnboardingStyle.faintColor.opacity(0.7))
          .padding(.leading, 14)
          .padding(.bottom, 12)
      }
      .padding(.horizontal, 8)
      .frame(width: 224, alignment: .leading)
    }

    private func select(_ new: SettingsMockDestination) {
      withAnimation(.easeInOut(duration: 0.5)) { destination = new }
    }

    @ViewBuilder
    private var detail: some View {
      ScrollView {
        Group {
          switch destination {
          case let .section(section):
            sectionPage(section)
          case let .display(id):
            SettingsMockDisplayPage(display: SettingsMockFixtures.display(for: id))
          }
        }
        .frame(maxWidth: SettingsMockStyle.pageWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionPage(_ section: SettingsMockSection) -> some View {
      switch section {
      case .general: SettingsMockGeneralPage(accent: section.accent)
      case .menuBar: SettingsMockMenuBarPage(accent: section.accent)
      case .arrangement: SettingsMockArrangementPage(accent: section.accent)
      case .oledCare: SettingsMockOledCarePage(accent: section.accent)
      case .virtualDisplays: SettingsMockVirtualDisplaysPage(accent: section.accent)
      case .keyboard: SettingsMockKeyboardPage(accent: section.accent)
      case .updates: SettingsMockUpdatesPage(accent: section.accent)
      case .about: SettingsMockAboutPage(accent: section.accent)
      }
    }

    private struct SidebarRow: View {
      let title: String
      let symbol: String
      let accent: Color
      let isSelected: Bool
      let action: () -> Void

      @State private var hovering = false

      var body: some View {
        Button(action: action) {
          HStack(spacing: 10) {
            Image(systemName: symbol)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(isSelected ? accent : OnboardingStyle.bodyColor)
              .frame(width: 20)
            Text(title)
              .font(.callout.weight(isSelected ? .semibold : .regular))
              .foregroundStyle(
                isSelected ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor
              )
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 7)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(
                isSelected
                  ? accent.opacity(0.13)
                  : Color.white.opacity(hovering ? 0.06 : 0))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .stroke(
                isSelected ? accent.opacity(0.25) : .clear, lineWidth: 1)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
      }
    }
  }
#endif
