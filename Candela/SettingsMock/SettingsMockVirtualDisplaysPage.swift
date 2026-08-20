#if DEBUG
  import SwiftUI

  /// Making a display out of nothing, staged as such: a ghosted outline floats
  /// where a display would be, and the one prominent control on the page fills
  /// it in. Created displays land in a list below as lit objects with their
  /// state on them.
  ///
  /// The list is local state, so Create and Remove work and outlive nothing.
  struct SettingsMockVirtualDisplaysPage: View {
    var accent: Color

    private struct MockVirtual: Identifiable {
      let id = UUID()
      var name: String
      var sizeLine: String
      var isLive: Bool
    }

    private static let sizeOptions = ["1920 x 1080", "2560 x 1440", "3440 x 1440"]

    @State private var displays: [MockVirtual] = [
      MockVirtual(name: "Studio Canvas", sizeLine: "2560 x 1440 (Retina)", isLive: true)
    ]
    @State private var sizeIndex = 1
    @State private var retina = true
    @State private var comesBack = false
    /// Names the next created display without reusing one already on screen.
    @State private var created = 1

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "Virtual Displays",
          subtitle:
            "A virtual display behaves like a connected one: windows move to it, it appears in Arrangement, and it can be shared or recorded.",
          accent: accent)
        hero
        runningSection
        newDisplaySection
      }
    }

    // MARK: - Hero

    private var hero: some View {
      VStack(spacing: 16) {
        MockGhostDisplay(accent: accent)
          .frame(width: 244, height: 152)
        VStack(spacing: 10) {
          Button("New Virtual Display") { create() }
            .buttonStyle(MockPrimaryButtonStyle(accent: accent))
            .disabled(isFull)
            .opacity(isFull ? 0.5 : 1)
          Text(verbatim: heroCaption)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
    }

    private var isFull: Bool { displays.count >= 3 }

    private var heroCaption: String {
      if isFull { return "Three are running, which is as many as macOS will hold." }
      if displays.isEmpty { return "Nothing running yet. Up to three can run at once." }
      return "Up to three can run at once."
    }

    // MARK: - Running

    private var runningSection: some View {
      MockSection(title: "Running", accent: accent) {
        if displays.isEmpty {
          MockRow(
            label: "Nothing running yet",
            caption: "New displays appear here with their size and their state.",
            symbol: "rectangle.dashed", accent: accent
          ) {
            EmptyView()
          }
        } else {
          ForEach(displays) { item in
            // Identity-keyed rather than index-keyed: a removal animates while
            // the array is already one shorter.
            if item.id != displays.first?.id { MockDivider() }
            card(item)
          }
        }
      }
    }

    private func card(_ item: MockVirtual) -> some View {
      HStack(spacing: 14) {
        DisplayGlyph(
          aspect: 16.0 / 9.0, accent: accent, lit: item.isLive ? 1 : 0.3,
          showsStand: false, showsReflection: false
        )
        .frame(width: 76, height: 43)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(verbatim: item.name)
              .foregroundStyle(OnboardingStyle.titleColor)
            MockBadge(text: item.isLive ? "Live" : "Stopped", accent: accent)
          }
          Text(verbatim: item.sizeLine)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.faintColor)
        }

        Spacer(minLength: 16)

        Button("Remove") { remove(item) }
          .buttonStyle(MockSecondaryButtonStyle())
      }
      .padding(.vertical, 6)
    }

    // MARK: - What the next one will be

    private var newDisplaySection: some View {
      MockSection(title: "New Displays", accent: accent) {
        MockRow(
          label: "Size", caption: "Used by the next display you create.",
          symbol: "aspectratio", accent: accent
        ) {
          MockSegments(options: Self.sizeOptions, selection: $sizeIndex, accent: accent)
        }
        MockDivider()
        MockRow(
          label: "Retina (HiDPI)", caption: "Text renders at double resolution.",
          symbol: "textformat.size", accent: accent
        ) {
          MockToggle(isOn: $retina, accent: accent)
        }
        MockDivider()
        MockRow(
          label: "Come back at launch",
          caption: "Created again the next time \(AppInfo.productName) opens.",
          symbol: "arrow.clockwise", accent: accent
        ) {
          MockToggle(isOn: $comesBack, accent: accent)
        }
      }
    }

    // MARK: - State

    private func create() {
      guard !isFull else { return }
      created += 1
      let size = Self.sizeOptions.indices.contains(sizeIndex)
        ? Self.sizeOptions[sizeIndex] : Self.sizeOptions[0]
      let item = MockVirtual(
        name: "Virtual Display \(created)",
        sizeLine: retina ? "\(size) (Retina)" : size,
        isLive: true)
      withAnimation(.easeOut(duration: 0.25)) { displays.append(item) }
    }

    private func remove(_ item: MockVirtual) {
      withAnimation(.easeOut(duration: 0.25)) {
        displays.removeAll { $0.id == item.id }
      }
    }
  }

  /// The display that isn't there yet: a dashed outline with a plus, tinted by
  /// the pane's accent so it reads as an invitation rather than as an error
  /// state.
  private struct MockGhostDisplay: View {
    var accent: Color

    var body: some View {
      GeometryReader { proxy in
        let bounds = proxy.size
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
          ZStack {
            shape.fill(accent.opacity(0.06))
            shape.strokeBorder(
              accent.opacity(0.4),
              style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
            Image(systemName: "plus")
              .font(.system(size: 30, weight: .light))
              .foregroundStyle(accent.opacity(0.7))
          }
          .frame(height: max(1, bounds.height * 0.84))
          Rectangle()
            .fill(accent.opacity(0.24))
            .frame(width: 14, height: max(1, bounds.height * 0.11))
          Capsule()
            .fill(accent.opacity(0.2))
            .frame(width: bounds.width * 0.24, height: 3)
        }
      }
    }
  }
#endif
