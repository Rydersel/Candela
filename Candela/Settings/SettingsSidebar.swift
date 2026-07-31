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
          displayRow(key: builtIn.display.persistenceKey,
                     name: builtIn.display.name,
                     controller: builtIn.controller)
        }
        ForEach(model.displays) { state in
          displayRow(key: state.display.persistenceKey,
                     name: state.display.name,
                     controller: state.controller)
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
  private func displayRow(key: String, name: String, controller: BrightnessController) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(verbatim: name) // hardware name — never a lookup key
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
    .tag(SettingsDestination.display(key))
  }
}
