import CandelaKit
import CoreGraphics
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

/// One external display's sidebar row, fully resolved: the state it draws and
/// the ordinal it draws it under. Identity stays the display ID, the same key
/// the sidebar's rows have always been diffed on.
private struct DisplayRow: Identifiable {
  let state: AppModel.DisplayState
  let ordinal: Int?
  var id: CGDirectDisplayID { state.id }
}

@MainActor
struct SettingsSidebar: View {
  @Binding var selection: SettingsDestination?
  /// Clicking the row that is ALREADY selected. Writing the same value to
  /// `selection` changes nothing, so without this hook the click is a no-op and
  /// a user sitting in a sub-page has no way back from the sidebar. What the
  /// re-click means is the root view's to decide.
  var onReselect: (SettingsDestination) -> Void = { _ in }

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
          row(.pane(pane.id), label: pane.title) {
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
        ForEach(displayRows) { row in
          displayRow(
            display: row.state.display,
            controller: row.state.controller,
            ordinal: row.ordinal
          )
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
  ///
  /// `label` is passed in rather than read off `content`, for the reason
  /// `SettingRow` records: a control's own label is not readable from here, and
  /// SwiftUI does not publish a `Button`'s implicit label to the accessibility
  /// layer at all, the same finding `NavigationRow` carries. Without it every
  /// row announces as a bare "button", which is the whole sidebar.
  @ViewBuilder
  private func row(
    _ destination: SettingsDestination,
    label: String,
    @ViewBuilder _ content: () -> some View
  ) -> some View {
    let isSelected = selection == destination
    Button {
      if isSelected {
        onReselect(destination)
      } else {
        selection = destination
      }
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
    // Never `.accessibilityElement(children: .ignore)` here: it replaces the
    // button's element and takes `AXPress` and `AXFocused` with it. See
    // `NavigationRow` for the measurement.
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  /// The external-display rows, each carrying its own SO21 ordinal, derived
  /// from ONE read of the model's display list.
  ///
  /// Everything a row renders travels with the row, and nothing it renders is
  /// looked up again later. SwiftUI keeps a `ForEach`'s data from the body
  /// evaluation that produced it and re-runs the content closure per child
  /// afterwards, so a closure that reaches back into the model is reading a
  /// list that may have moved on: a settings reset empties `displays` and
  /// rebuilds it, which is enough to strand a row holding a position no longer
  /// in the list. Positions do not survive that; values do.
  private var displayRows: [DisplayRow] {
    let states = model.displays
    let ordinals = DisplayOrdering.sharedIdentityOrdinals(
      keys: states.map(\.display.persistenceKey)
    )
    return zip(states, ordinals).map(DisplayRow.init)
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
  private func displayRow(
    display: ExternalDisplay, controller: BrightnessController, ordinal: Int? = nil
  ) -> some View {
    // The SAME resolution the panel uses, so a rename moves the sidebar, the
    // panel header, the slider's accessibility label and the HUD together. The
    // detail pane's title deliberately does NOT follow — it stays the hardware
    // name, so renaming does not relabel the window you are editing it in.
    let resolved = DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: display.persistenceKey).friendlyName,
      hardwareName: display.name
    )
    let name = ordinal.map { "\(resolved) (\($0))" } ?? resolved
    let isSelected = selection == .display(display.persistenceKey)
    let hasUnread = model.displayModes.hasUnreadReport(for: display.id)
    // The dot's fact rides in the row's own label rather than in a nested
    // element: an explicit `.accessibilityLabel` on a `Button` replaces the
    // label derived from its content, so a child element's label would simply
    // stop being announced. Same reason the brightness bar stays hidden.
    let spokenName = hasUnread ? "\(name), has an unread notice" : name
    row(.display(display.persistenceKey), label: spokenName) {
      Label {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(verbatim: name) // a display's name — never a lookup key
              .lineLimit(1)
              .truncationMode(.tail)
            // Something happened on this display while nobody was looking and
            // nobody has read it yet. A dot, not a count: the destination
            // carries the account, this only says there is one to open. It is
            // never the sole carrier of the fact either — the notice itself is
            // inside — so a missed dot costs nothing.
            if hasUnread {
              Circle()
                // White on the selected row for the reason the row forces its
                // foreground: an accent dot on the accent pill is invisible.
                .fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            }
          }
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
