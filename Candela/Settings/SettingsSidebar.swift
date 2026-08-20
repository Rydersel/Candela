import CandelaKit
import CoreGraphics
import SwiftUI

/// One external display's sidebar row, fully resolved: the state it draws and
/// the ordinal it draws it under. Identity stays the display ID, the same key
/// the sidebar's rows have always been diffed on.
private struct DisplayRow: Identifiable {
  let state: AppModel.DisplayState
  let ordinal: Int?
  var id: CGDirectDisplayID { state.id }
}

/// The SO21 ordinal every sidebar row draws, one entry per key, derived from
/// ONE snapshot of the display list. Plain keys in, plain answers out: nothing
/// here reads the model, so the answer cannot be built against a list other
/// than the one it was handed.
func sidebarDisplayOrdinals(keys: [String]) -> [Int?] {
  DisplayOrdering.sharedIdentityOrdinals(keys: keys)
}

/// The ordinal the row at `index` draws.
///
/// Total on purpose. A position is a description of a list that outlives the
/// list: the sidebar crashed subscripting a display list a settings reset had
/// already emptied, with a position captured against the longer list it was
/// built from. An index that no longer describes the snapshot means the row it
/// pointed at is gone, and a gone row has no number, so the honest answer is
/// nil rather than a trap.
func sidebarOrdinal(at index: Int, in ordinals: [Int?]) -> Int? {
  guard ordinals.indices.contains(index) else { return nil }
  return ordinals[index]
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
  /// The destination's lighting, published by the shell. The wordmark takes
  /// its tint from here, so the mark relights with the canvas.
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    // Display rows show the user's chosen name, and `DisplayPrefs` is plain
    // UserDefaults with no observation — so without this the sidebar would keep
    // showing the old name after a rename until something else forced a
    // re-render.
    let _ = model.prefsRevision
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        wordmark

        ForEach(SettingsRegistry.panes) { pane in
          row(
            .pane(pane.id), label: pane.title, symbol: pane.symbol,
            accent: pane.accent.accent
          ) {
            Text(pane.title).lineLimit(1)
          }
        }

        Text("DISPLAYS")
          .font(.caption2.weight(.semibold))
          .kerning(1.2)
          .foregroundStyle(SettingsTheme.faintColor)
          // The uppercasing is typography; VoiceOver gets the written word.
          .accessibilityLabel(Text("Displays"))
          .padding(.leading, 14)
          .padding(.top, 18)
          .padding(.bottom, 6)

        // Built-in first, matching `AppModel.allControlledStates`.
        if let builtIn = model.builtIn {
          displayRow(
            display: builtIn.display, controller: builtIn.controller,
            accent: .display(isBuiltIn: true, ordinal: 0))
        }
        ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
          displayRow(
            display: row.state.display,
            controller: row.state.controller,
            // Position among the externals, NOT the shared-identity ordinal:
            // this only decides which hue the row lights with, so two panels
            // attached at once never draw the same colour.
            accent: .display(isBuiltIn: false, ordinal: index),
            ordinal: row.ordinal
          )
        }
        if model.displays.isEmpty {
          // Preserves what the deleted Displays pane told the user. Without it,
          // someone seeing only "Built-in Display" cannot tell an undetected
          // monitor from a broken app.
          Text("No external displays connected")
            .font(.callout)
            .foregroundStyle(SettingsTheme.faintColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.bottom, 12)
    }
    .scrollContentBackground(.hidden)
    // Transparent, and that is now the whole point: the canvas behind the
    // shell is this column's ground, so the sidebar has nothing of its own to
    // dim when the window loses focus. The opaque fill that used to sit here
    // solved the same problem the other way round, before there was a canvas.
    //
    // Hand-built rows rather than a `List`, still: `.sidebar` and `.inset`
    // draw a panel that dims, `.plain` draws a square full-width highlight,
    // and a custom pill under a `List`'s own selection gave two stacked
    // highlights because `listRowBackground` composites INSIDE the selection
    // rather than replacing it. Owning the rows gives exactly one pill and no
    // panel.
    //
    // The cost is arrow-key navigation between rows, which a `List` gave for
    // free. Each row is a focusable button, so the sidebar stays reachable and
    // operable by keyboard via Tab and Space.
  }

  /// The brand mark AS the C of the product name, seated on the first text
  /// baseline and sized to the cap height so it reads as a capital letter
  /// rather than an icon standing beside the word (SV10). It relights with the
  /// destination at the selection cadence.
  private var wordmark: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      BrandMark(tint: lighting.accent)
        .frame(width: 13.5, height: 13.5)
        // Seats the ring on the optical baseline and tucks it toward the word;
        // the arc's open right side reads as extra letter-spacing.
        .offset(x: 1.5, y: 1.5)
        .animation(SettingsTheme.selectionMotion, value: lighting)
      Text(verbatim: String(AppInfo.productName.dropFirst()))
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundStyle(SettingsTheme.titleColor)
    }
    .padding(.leading, 12)
    // The mock's number and nothing added to it. The traffic lights are cleared
    // by the titlebar safe area the shell already respects (the canvas is the
    // one view that opts out), so a second clearance here would both double the
    // inset and put the defence inside scrolled content, where enough display
    // rows carry it away.
    .padding(.top, 14)
    .padding(.bottom, 16)
    // The mark carries the missing letter, so the two halves have to be read
    // as one word: without this VoiceOver announces the text alone, which is
    // the product name with its first letter cut off.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: AppInfo.productName))
  }

  /// One selectable row: the destination's glyph, whatever the row draws beside
  /// it, and a button that draws its own selection pill.
  ///
  /// The pill is the destination's own accent at low alpha with a brighter
  /// stroke, so a selected row reads as lit rather than filled and the row's
  /// text keeps its own colour. Hover is a plain white wash: it says "this is
  /// clickable", never "this is where you are".
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
    symbol: String,
    accent: Color,
    @ViewBuilder _ content: () -> some View
  ) -> some View {
    let isSelected = selection == destination
    SidebarRowButton(isSelected: isSelected, accent: accent, symbol: symbol) {
      if isSelected {
        onReselect(destination)
      } else {
        selection = destination
      }
    } content: {
      content()
    }
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
  /// looked up again later. The crash that forced this shape was a `ForEach`
  /// content closure re-running on its own, after a settings reset had emptied
  /// `displays`, and subscripting the model with the position it had been
  /// handed at the previous body evaluation. Whatever schedules that re-run,
  /// its input is not guaranteed to still describe the model: a position
  /// captured against one list does not survive the list, and a value does.
  private var displayRows: [DisplayRow] {
    let states = model.displays
    let ordinals = sidebarDisplayOrdinals(keys: states.map(\.display.persistenceKey))
    return states.indices.map { index in
      DisplayRow(state: states[index], ordinal: sidebarOrdinal(at: index, in: ordinals))
    }
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
    display: ExternalDisplay, controller: BrightnessController,
    accent: SettingsAccent, ordinal: Int? = nil
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
    let hasUnread = model.displayModes.hasUnreadReport(for: display.id)
    // The dot's fact rides in the row's own label rather than in a nested
    // element: an explicit `.accessibilityLabel` on a `Button` replaces the
    // label derived from its content, so a child element's label would simply
    // stop being announced. Same reason the brightness bar stays hidden.
    let spokenName = hasUnread ? "\(name), has an unread notice" : name
    row(
      .display(display.persistenceKey), label: spokenName,
      // The built-in draws as a laptop everywhere it is depicted (SV9).
      symbol: display.persistenceKey == "builtIn" ? "laptopcomputer" : "display",
      accent: accent.accent
    ) {
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
              // The row's own hue, which the low-alpha selection pill no
              // longer swallows the way the old solid accent fill did.
              .fill(accent.accent)
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
        }
        Capsule()
          .fill(Color.white.opacity(0.14))
          .frame(height: 3)
          .overlay(alignment: .leading) {
            GeometryReader { geo in
              // Monochrome, not the accent: the selection pill is already
              // accent-coloured, and an accent bar on every row made the
              // sidebar read as several competing highlights rather than one
              // selection plus some levels.
              //
              // Near-white, and explicit rather than `.primary`: the row
              // dims its own text on an unselected row, and a level
              // indicator's entire job is showing where the fill boundary
              // is. Inheriting that dimming put the fill one step from the
              // track and a full bar stopped reading as full.
              Capsule()
                .fill(SettingsTheme.titleColor)
                .frame(width: geo.size.width * min(max(controller.brightness, 0), 1))
            }
          }
          .accessibilityHidden(true)
      }
    }
  }
}

/// The sidebar's row chrome: the destination glyph, the hover wash, the
/// selection pill, and the type weight that moves with selection. A view of its
/// own because the hover state has to live somewhere, and a `@State` cannot
/// live in a function.
///
/// The glyph is bare and tinted, not a filled tile: a column of saturated tiles
/// is the System Settings idiom, and this window is not that window. It is
/// decoration either way, so it is the row's text that carries the meaning and
/// nothing here is said by colour alone.
private struct SidebarRowButton<Content: View>: View {
  let isSelected: Bool
  let accent: Color
  let symbol: String
  let action: () -> Void
  @ViewBuilder let content: Content

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .medium))
          // Lit only where the user is; elsewhere it sits at the row's own
          // weight so eight hues do not compete for the eye at once.
          .foregroundStyle(isSelected ? accent : SettingsTheme.bodyColor)
          .frame(width: 20)
          .accessibilityHidden(true)
        content
          .font(.callout.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? SettingsTheme.titleColor : SettingsTheme.bodyColor)
          // The whole remaining width, not the text's own: a display row's
          // brightness bar is measured against it.
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .fill(
            isSelected
              ? accent.opacity(0.13)
              : Color.white.opacity(hovering ? 0.06 : 0))
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .stroke(isSelected ? accent.opacity(0.25) : .clear, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(SettingsTheme.hoverMotion, value: hovering)
  }
}
