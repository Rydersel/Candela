#if DEBUG
  import SwiftUI

  /// Arrangement as a lit stage rather than a diagram: the three fixture
  /// displays stand on a dark floor at their true mounted shapes, the selected
  /// one lit in the pane's accent, and the display carrying the menu bar wears
  /// a strip along the top of its face.
  ///
  /// Selection and the menu bar's home are local state; nothing is applied.
  struct SettingsMockArrangementPage: View {
    var accent: Color

    @State private var selected = SettingsMockFixtures.mag.id
    @State private var main = SettingsMockFixtures.mag.id
    @State private var remembers = true

    var body: some View {
      VStack(alignment: .leading, spacing: 15) {
        MockPageHeader(
          title: "Arrangement",
          subtitle:
            "Where the displays are, and where they should be. Drag one to move it, or tab to it and use the arrow keys.",
          accent: accent)
        map
        mainDisplaySection
        savedSection
      }
    }

    // MARK: - The map

    private var map: some View {
      MockCard {
        VStack(alignment: .leading, spacing: 10) {
          canvas
          Text(verbatim:
            "The strip along the top of a display marks the one showing the menu bar. Displays have to touch along an edge and cannot overlap."
          )
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    private var canvas: some View {
      HStack(alignment: .bottom, spacing: 22) {
        tile(SettingsMockFixtures.dell, size: CGSize(width: 94, height: 158))
        tile(SettingsMockFixtures.mag, size: CGSize(width: 212, height: 116))
        // The laptop sits lower on the desk than the two arms do.
        tile(SettingsMockFixtures.builtIn, size: CGSize(width: 112, height: 92))
          .offset(y: 12)
      }
      .frame(maxWidth: .infinity, minHeight: 214, alignment: .center)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.black.opacity(0.32))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Color.white.opacity(0.07), lineWidth: 1)
      )
    }

    private func tile(_ display: SettingsMockDisplay, size: CGSize) -> some View {
      let isSelected = selected == display.id
      return Button {
        withAnimation(.easeOut(duration: 0.25)) { selected = display.id }
      } label: {
        VStack(spacing: 6) {
          Group {
            if display.isBuiltIn {
              MockLaptopGlyph(
                aspect: display.aspect,
                accent: isSelected ? accent : Color(white: 0.62),
                lit: isSelected ? 1 : 0.42,
                faceOverlay: main == display.id ? AnyView(MockMenuBarStrip()) : nil
              )
            } else {
              DisplayGlyph(
                aspect: display.aspect,
                accent: isSelected ? accent : Color(white: 0.62),
                lit: isSelected ? 1 : 0.42,
                faceOverlay: main == display.id ? AnyView(MockMenuBarStrip()) : nil
              )
            }
          }
          .frame(width: size.width, height: size.height)
          // Selection reads from the accent and the lit face, not from a halo.
          .shadow(color: .black.opacity(isSelected ? 0.4 : 0.25), radius: 10, y: 5)
          Text(verbatim: display.name)
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(
              isSelected ? OnboardingStyle.titleColor : OnboardingStyle.faintColor
            )
            .lineLimit(1)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var mainDisplaySection: some View {
      MockSection(title: "Main Display", accent: accent) {
        MockRow(
          label: "Main display", caption: mainCaption, symbol: "menubar.dock.rectangle",
          accent: accent
        ) {
          Button("Use as Main Display") {
            withAnimation(.easeOut(duration: 0.3)) { main = selected }
          }
          .buttonStyle(MockSecondaryButtonStyle())
          .disabled(selected == main)
          .opacity(selected == main ? 0.45 : 1)
        }
      }
    }

    private var mainCaption: String {
      let name = SettingsMockFixtures.display(for: selected).name
      if selected == main {
        return "\(name) already shows the menu bar. Select another display to move it."
      }
      return
        "Moves the menu bar and the Dock to \(name). You will be asked to keep or undo the change."
    }

    private var savedSection: some View {
      MockSection(title: "Saved Arrangements", accent: accent) {
        MockRow(
          label: "Remember how these displays are arranged",
          caption:
            "Puts them back this way when they reconnect or \(AppInfo.productName) launches.",
          symbol: "clock.arrow.circlepath", accent: accent
        ) {
          MockToggle(isOn: $remembers, accent: accent)
        }
      }
    }
  }

  /// The menu bar drawn on a display's face: the one fact the map states that
  /// the tiles' shapes cannot.
  private struct MockMenuBarStrip: View {
    var body: some View {
      VStack(spacing: 0) {
        Rectangle()
          .fill(Color.white.opacity(0.55))
          .frame(height: 3)
        Spacer(minLength: 0)
      }
    }
  }
#endif
