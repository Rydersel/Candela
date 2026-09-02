import CandelaKit
import CoreGraphics
import SwiftUI

/// One external display's sidebar row, fully resolved. Identity stays the
/// display ID, the key the sidebar's rows are diffed on.
private struct DisplayRow: Identifiable {
  let state: AppModel.DisplayState
  let ordinal: Int?
  var id: CGDirectDisplayID { state.id }
}

/// The ordinal every sidebar row draws, from ONE snapshot of the display
/// list. Nothing here reads the model, so the answer cannot be built against a
/// list other than the one it was handed.
func sidebarDisplayOrdinals(keys: [String]) -> [Int?] {
  DisplayOrdering.sharedIdentityOrdinals(keys: keys)
}

/// Total on purpose. The sidebar crashed subscripting a display list a settings
/// reset had already emptied, using a position captured against the longer list
/// it was built from. An index that no longer describes the snapshot means the
/// row is gone, and a gone row has no number.
func sidebarOrdinal(at index: Int, in ordinals: [Int?]) -> Int? {
  guard ordinals.indices.contains(index) else { return nil }
  return ordinals[index]
}

@MainActor
struct SettingsSidebar: View {
  @Binding var selection: SettingsDestination?
  /// Clicking the row that is ALREADY selected. Writing the same value to
  /// `selection` changes nothing, so without this hook someone sitting in a
  /// sub-page has no way back from the sidebar. What the re-click means is the
  /// root view's call.
  var onReselect: (SettingsDestination) -> Void = { _ in }

  @Environment(AppModel.self) private var model
  /// Published by the shell, so the wordmark relights with the canvas.
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults with no observation, so without this
    // read the sidebar keeps the old name after a rename until something else
    // forces a re-render.
    let _ = model.prefsRevision
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        wordmark
          .background(OverlayScrollers())

        ForEach(SettingsRegistry.sections) { section in
          if let header = section.header {
            sectionHeader(header)
          }
          ForEach(Array(section.panes.enumerated()), id: \.element) { index, id in
            let pane = SettingsRegistry.descriptor(for: id)
            row(
              .pane(pane.id), label: pane.title, symbol: pane.symbol,
              accent: pane.accent.accent
            ) {
              Text(pane.title).lineLimit(1)
            }
            // A headerless break: a header's worth of air with nothing
            // said, so the utility rows do not read as another section.
            .padding(.top, section.gapAbove && index == 0 ? 18 : 0)
          }
        }

        sectionHeader("DISPLAYS")

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
            // Position among the externals, NOT the shared-identity ordinal.
            // It only picks the hue, so two attached panels never match.
            accent: .display(isBuiltIn: false, ordinal: index),
            ordinal: row.ordinal
          )
        }
        if model.displays.isEmpty {
          // Without this, someone seeing only "Built-in Display" cannot tell
          // an undetected monitor from a broken app.
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
    // Transparent on purpose: the canvas is this column's ground, so the
    // sidebar has nothing of its own to dim when the window loses focus.
    //
    // Hand-built rows rather than a `List`. `.sidebar` and `.inset` draw a panel
    // that dims, `.plain` draws a square full-width highlight, and a custom pill
    // under a `List`'s selection gave two stacked highlights because
    // `listRowBackground` composites INSIDE the selection rather than replacing
    // it. The cost is arrow-key navigation; rows are focusable buttons, so Tab
    // and Space still work.
  }

  /// The brand mark AS the C of the product name, sized to the cap height so it
  /// reads as a letter rather than an icon beside the word.
  private var wordmark: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      BrandMark(tint: lighting.accent)
        .frame(width: 13.5, height: 13.5)
        // Seats the ring on the optical baseline; the arc's open right side
        // otherwise reads as extra letter-spacing.
        .offset(x: 1.5, y: 1.5)
        .animation(SettingsTheme.selectionMotion, value: lighting)
      Text(verbatim: String(AppInfo.productName.dropFirst()))
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .foregroundStyle(SettingsTheme.titleColor)
    }
    .padding(.leading, 12)
    // No traffic-light clearance added here: the shell already respects the
    // titlebar safe area, and a second inset would sit inside scrolled content
    // where enough display rows carry it away.
    .padding(.top, 14)
    .padding(.bottom, 16)
    // The mark carries the missing letter. Without this VoiceOver announces
    // the text alone, which is the product name minus its first letter.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: AppInfo.productName))
  }

  /// ONE kicker treatment for every section.
  ///
  /// `title` arrives uppercase as typography. VoiceOver gets the written word,
  /// so the label capitalizes it back rather than spelling out the caps.
  private func sectionHeader(_ title: String) -> some View {
    Text(verbatim: title)
      .font(.caption2.weight(.semibold))
      .kerning(1.2)
      .foregroundStyle(SettingsTheme.faintColor)
      .accessibilityLabel(Text(verbatim: title.capitalized))
      .padding(.leading, 14)
      .padding(.top, 18)
      .padding(.bottom, 6)
  }

  /// One selectable row, drawing its own selection pill.
  ///
  /// The pill is the destination accent at low alpha, so a selected row reads
  /// as lit rather than filled. Hover is a plain white wash: it says
  /// "clickable", never "this is where you are".
  ///
  /// `label` is passed in rather than read off `content`, because SwiftUI does
  /// not publish a `Button`'s implicit label to the accessibility layer at all.
  /// Without it every row announces as a bare "button".
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
    // button's element and takes `AXPress` and `AXFocused` with it.
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  /// From ONE read of the model's display list. Everything a row renders
  /// travels with the row and is never looked up again.
  ///
  /// The crash that forced this shape: a `ForEach` content closure re-ran on its
  /// own after a settings reset emptied `displays`, subscripting the model with
  /// a position from the previous body evaluation. A position captured against
  /// one list does not survive the list; a value does.
  private var displayRows: [DisplayRow] {
    let states = model.displays
    let ordinals = sidebarDisplayOrdinals(keys: states.map(\.display.persistenceKey))
    return states.indices.map { index in
      DisplayRow(state: states[index], ordinal: sidebarOrdinal(at: index, in: ordinals))
    }
  }

  /// Name plus a brightness bar. `BrightnessController` is `@Observable` and
  /// publishes its value, so the bar tracks the keys and the panel with no
  /// polling.
  ///
  /// The bar is decoration and is hidden from accessibility: a percentage
  /// announced on every row is noise, and it is not actionable from here.
  @ViewBuilder
  private func displayRow(
    display: ExternalDisplay, controller: BrightnessController,
    accent: SettingsAccent, ordinal: Int? = nil
  ) -> some View {
    // The SAME resolution the panel uses, so a rename moves the sidebar, the
    // panel header, the slider's label and the HUD together. The detail pane's
    // title deliberately does not follow: it stays the hardware name, so
    // renaming does not relabel the window you are editing it in.
    let prefs = DisplayPrefs(persistenceKey: display.persistenceKey)
    let resolved = DisplayOrdering.title(
      friendlyName: prefs.friendlyName, hardwareName: display.name
    )
    let name = ordinal.map { "\(resolved) (\($0))" } ?? resolved
    let hasUnread = model.displayModes.hasUnreadReport(for: display.id)
    // Straight from prefs, like the name above. The `prefsRevision` read at the
    // top of `body` is what brings an enrollment change back here.
    let isEnrolled = prefs.oledCareEnrolled
    // Both facts ride the row's own label rather than nested elements: an
    // explicit `.accessibilityLabel` on a `Button` replaces the label derived
    // from its content, so a child's label stops being announced. Spoken in the
    // order the glyphs are drawn.
    let spokenName =
      name + (isEnrolled ? ", enrolled in OLED care" : "")
      + (hasUnread ? ", has an unread notice" : "")
    row(
      .display(display.persistenceKey), label: spokenName,
      // The built-in draws as a laptop everywhere it is depicted.
      symbol: display.persistenceKey == "builtIn" ? "laptopcomputer" : "display",
      accent: accent.accent
    ) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(verbatim: name) // a display's name, never a lookup key
            .lineLimit(1)
            .truncationMode(.tail)
          // Enrolled in OLED care. A shield, not the notice dot: two
          // facts, two shapes, neither carried by colour. Faint because it is
          // a standing state, and the OLED Care overview holds the
          // authoritative badge.
          if isEnrolled {
            Image(systemName: "shield.fill")
              .font(.system(size: 8))
              .foregroundStyle(SettingsTheme.faintColor)
              .accessibilityHidden(true)
          }
          // An unread notice. A dot, not a count: the destination carries the
          // account, this only says there is one to open. The notice itself is
          // inside, so a missed dot costs nothing.
          if hasUnread {
            Circle()
              // The row's own hue; the low-alpha pill does not swallow it.
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
              // Monochrome, not the accent: an accent bar on every row made
              // the sidebar read as competing highlights rather than one
              // selection plus some levels.
              //
              // Explicit rather than `.primary`: an unselected row dims its own
              // text, and inheriting that put the fill one step off the track,
              // so a full bar stopped reading as full.
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

/// The sidebar's row chrome. A view of its own because `@State` for the hover
/// cannot live in a function.
///
/// The glyph is bare and tinted rather than a filled tile: a column of
/// saturated tiles is the System Settings idiom. It is decoration, so the row's
/// text carries the meaning.
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
          // Lit only on the selected row, so the hues do not all compete.
          .foregroundStyle(isSelected ? accent : SettingsTheme.bodyColor)
          .frame(width: 20)
          .accessibilityHidden(true)
        content
          .font(.callout.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? SettingsTheme.titleColor : SettingsTheme.bodyColor)
          // The whole remaining width: a display row's bar measures against it.
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
