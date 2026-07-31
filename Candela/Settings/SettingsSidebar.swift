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
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(SettingsRegistry.panes) { pane in
          row(.pane(pane.id)) {
            Label {
              Text(pane.title)
            } icon: {
              SettingsSymbolTile(symbol: pane.symbol, tint: pane.tint)
            }
          }
        }

        Text("Displays")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.top, 14)
          .padding(.bottom, 2)

        // Built-in first, matching `AppModel.allControlledStates`.
        if let builtIn = model.builtIn {
          displayRow(display: builtIn.display, controller: builtIn.controller)
        }
        ForEach(model.displays) { state in
          displayRow(display: state.display, controller: state.controller)
        }
        if model.displays.isEmpty {
          // Preserves what the deleted Displays pane told the user. Without it,
          // someone seeing only "Built-in Display" cannot tell an undetected
          // monitor from a broken app.
          Text("No external displays connected")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 10)
    }
    .scrollContentBackground(.hidden)
    // OPAQUE, deliberately. No material, no Liquid Glass, nothing translucent.
    //
    // Every translucent option dimmed when the window lost focus, which for a
    // settings window is most of the time it is on screen — you click away to
    // see what a setting did. That dimming was not reachable: the panel is
    // drawn by SwiftUI's list style, not by an `NSVisualEffectView` (a dump of
    // the live hierarchy found no sidebar-material effect view at all, and
    // every effect view present was already pinned `.active`), and replacing
    // it with our own `glassEffect` surface dimmed too. A solid fill cannot
    // dim, which is the whole point.
    //
    // Hand-built rows rather than a `List` for a related reason: `.sidebar`
    // and `.inset` draw the panel that dims, `.plain` draws a square
    // full-width highlight, and a custom pill under a `List`'s own selection
    // gave two stacked highlights because `listRowBackground` composites
    // INSIDE the selection rather than replacing it. Owning the rows gives
    // exactly one pill and no panel.
    //
    // The cost is arrow-key navigation between rows, which a `List` gave for
    // free. Each row is a focusable button, so the sidebar stays reachable and
    // operable by keyboard via Tab and Space.
    .background(Color(nsColor: .windowBackgroundColor))
    // A settings window has exactly one navigation surface, and collapsing it
    // leaves a detail pane you cannot navigate out of. `NavigationSplitView`
    // adds the toggle by default, which parks a stray button in the toolbar.
    .toolbar(removing: .sidebarToggle)
  }

  /// One selectable row: a button that draws its own selection pill.
  ///
  /// Foreground is forced to white when selected. SwiftUI only auto-inverts a
  /// label's colour for selection styles it drew itself, so a hand-drawn
  /// background has to handle the text, or the tinted-tile rows go unreadable
  /// against the accent fill.
  @ViewBuilder
  private func row(_ destination: SettingsDestination, @ViewBuilder _ content: () -> some View) -> some View {
    let isSelected = selection == destination
    Button {
      selection = destination
    } label: {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
    )
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
    // detail pane's title deliberately does NOT follow — it stays the hardware
    // name, so renaming does not relabel the window you are editing it in.
    let name = DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
    row(.display(display.persistenceKey)) {
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
                // Monochrome, not the accent: the selection pill is already
                // accent-coloured, and an accent bar on every row made the
                // sidebar read as several competing highlights rather than one
                // selection plus some levels.
                //
                // `.primary`, NOT `.secondary`. Secondary sits one step from
                // the quaternary track, so in dark mode both are mid-greys and
                // a full bar was indistinguishable from an empty one — the fill
                // boundary simply did not read. A level indicator's entire job
                // is showing where that boundary is, so it takes the highest-
                // contrast neutral available: near-white on dark, near-black on
                // light, and white against the accent on the selected row.
                Capsule()
                  .fill(.primary)
                  .frame(width: geo.size.width * min(max(controller.brightness, 0), 1))
              }
            }
            .accessibilityHidden(true)
        }
      } icon: {
        SettingsSymbolTile(symbol: "display", tint: .blue)
      }
    }
  }
}
