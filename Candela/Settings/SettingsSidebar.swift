import CandelaKit
import SwiftUI

/// System Settings' row idiom: a tinted rounded-rect tile holding a white SF
/// Symbol, then the title. The tile is decoration — the title carries the
/// meaning, so nothing here is communicated by color alone.
struct SettingsSymbolTile: View {
  let symbol: String
  let tint: Color

  var body: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(tint)
      .frame(width: 18, height: 18)
      .overlay(
        Image(systemName: symbol)
          .font(.system(size: 10, weight: .semibold))
          // The one deliberate non-semantic color in the window. The glyph sits
          // on a saturated tint in BOTH appearances, so it stays white in both
          // — exactly what System Settings does. A semantic label color would
          // go dark on the tint in light mode and lose all contrast.
          .foregroundStyle(.white)
      )
      .accessibilityHidden(true)
  }
}

@MainActor
struct SettingsSidebar: View {
  @Binding var selection: SettingsDestination?

  @Environment(AppModel.self) private var model

  var body: some View {
    // Display rows show the user's chosen name, and `DisplayPrefs` is plain
    // UserDefaults with no observation — so without this the sidebar would keep
    // showing the old name after a rename until something else forced a
    // re-render.
    let _ = model.prefsRevision
    List(selection: $selection) {
      Section {
        ForEach(SettingsRegistry.panes) { pane in
          Label {
            Text(pane.title)
          } icon: {
            SettingsSymbolTile(symbol: pane.symbol, tint: pane.tint)
          }
          .tag(SettingsDestination.pane(pane.id))
        }
      }

      Section("Displays") {
        // Built-in first, matching `AppModel.allControlledStates`.
        if let builtIn = model.builtIn {
          displayRow(display: builtIn.display, controller: builtIn.controller)
        }
        ForEach(model.displays) { state in
          displayRow(display: state.display, controller: state.controller)
        }
        if model.displays.isEmpty {
          // Preserves what the deleted Displays pane told the user. Without
          // it, someone seeing only "Built-in Display" cannot tell an
          // undetected monitor from a broken app.
          Text("No external displays connected")
            .font(.callout)
            .foregroundStyle(.secondary)
            .selectionDisabled()
        }
      }
    }
    .listStyle(.sidebar)
    // A settings window has exactly one navigation surface, and collapsing it
    // leaves a detail pane you cannot navigate out of. `NavigationSplitView`
    // adds the toggle by default, which parked a stray button in the middle of
    // the sidebar's toolbar strip and reserved a band of empty space under the
    // window controls. Removing it reclaims both.
    .toolbar(removing: .sidebarToggle)
  }

  /// A display's row: name, and a bar showing where its brightness currently
  /// sits. `BrightnessController` is `@MainActor @Observable` and publishes its
  /// value, so the bar tracks the keys and the panel live with no polling.
  ///
  /// The bar is decoration. It is never the only thing saying anything — the
  /// destination carries the real state, and nothing here is conveyed by color
  /// alone. It is hidden from accessibility for the same reason: a percentage
  /// announced on every row is noise, and it is not actionable from here.
  @ViewBuilder
  private func displayRow(display: ExternalDisplay, controller: BrightnessController) -> some View {
    // The SAME resolution the panel uses, so a rename moves the sidebar, the
    // panel header, the slider's accessibility label and the HUD together. The
    // detail pane's navigation title deliberately does NOT follow — it stays
    // the hardware name, so renaming does not relabel the window you are
    // editing the name in.
    let name = DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: name) // a display's name — never a lookup key
          .lineLimit(1)
          .truncationMode(.tail)
        Capsule()
          .fill(.quaternary)
          .frame(height: 3)
          .overlay(alignment: .leading) {
            GeometryReader { geo in
              Capsule()
                .fill(.tint)
                .frame(width: geo.size.width * min(max(controller.brightness, 0), 1))
            }
          }
          .accessibilityHidden(true)
      }
    } icon: {
      SettingsSymbolTile(symbol: "display", tint: .blue)
    }
    .tag(SettingsDestination.display(display.persistenceKey))
  }
}
