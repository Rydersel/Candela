import CandelaKit
import SwiftUI

/// The menu-bar icon, the panel's sliders and the on-screen indicators: what
/// Candela puts on screen outside its own windows.
///
/// The indicator positions live here rather than under Keyboard because they
/// are an appearance choice, and this is the pane that owns those. Keyboard
/// decides which display a press acts on; this decides where the answer is
/// drawn.
///
/// Deliberately five slider and menu-bar controls. D26 cut the fork's "General menu items style"
/// popup and "Show slider tick marks" toggle, and D32 files both prefs as
/// reserved-and-inert: `menuItemStyle` and `showTickMarks` keep their keys so
/// the schema slots can never be reused, but nothing in Candela reads them,
/// they are not `PrefName` cases, and this pane writes neither. The fork's
/// app-wide "show brightness slider" / "show volume slider" toggles are cut
/// too — the controls on each display's own destination say the same thing more
/// precisely — as are the `multiSliders` combined/relevant modes.
///
/// `@MainActor` is load-bearing. A `View`'s stored and
/// computed properties are nonisolated under `SWIFT_STRICT_CONCURRENCY:
/// complete`, so `SettingsActions` (itself `@MainActor`) could not be held or
/// touched outside `body` without it.
@MainActor
struct AppMenuPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  /// Scroll anchors for the preview's click-to-jump (KMR-A5). On the Section,
  /// not a row: the jump should land the section heading at the top.
  private static let slidersSectionID = "menuBar.sliders"
  private static let indicatorsSectionID = "menuBar.indicators"

  var body: some View {
    // `menuIcon` is written from OUTSIDE this pane: ⌘-dragging the status item
    // off the menu bar makes StatusItemController persist `.hide` (D5). Prefs
    // are plain UserDefaults and not observable, so the revision bump is the
    // only thing that re-reads them and flips the popup.
    let _ = model.prefsRevision
    // A grouped `Form` is a ScrollView underneath, so the reader's proxy can
    // drive it; the OLED pane's old glance strip used the same shape.
    ScrollViewReader { proxy in
      form(proxy: proxy)
    }
  }

  private func form(proxy: ScrollViewProxy) -> some View {
    Form {
      // The pane's subject, drawn (KMR7): everything below decides what
      // Candela puts on screen, and the preview shows the current answer.
      // Its widgets are doorways (KMR-A5): clicking one scrolls to the
      // section that configures it.
      Section {
        VStack(alignment: .leading, spacing: 6) {
          MenuBarPreviewView { target in
            withAnimation {
              switch target {
              case .sliders: proxy.scrollTo(Self.slidersSectionID, anchor: .top)
              case .indicators: proxy.scrollTo(Self.indicatorsSectionID, anchor: .top)
              }
            }
          }
          SettingsCaption("A preview of the current settings; the controls below change it live. Click a widget to jump to its settings.")
        }
      }

      Section("Menu Bar") {
        SettingRow {
          Picker("Show the menu bar icon:", selection: Binding(
            get: { prefs.menuIcon },
            set: { mode in
              prefs.menuIcon = mode
              actions.prefDidChange(.menuIcon)
            }
          )) {
            // The order comes from `MenuIconPolicy.pickerOrder`, never
            // `MenuIcon.allCases`: `externalOnly` was appended as raw 3 but
            // belongs third, so iterating raw order would silently reorder the
            // popup (D5). Consuming the Kit constant keeps the one copy of that
            // rule where it is tested.
            ForEach(MenuIconPolicy.pickerOrder, id: \.self) { mode in
              Text(label(for: mode)).tag(mode)
            }
          }
          .prefIdentifier(.menuIcon)
          if prefs.menuIcon != .show {
            // Every mode but "Always" can leave the user with no icon and
            // therefore no way in. SO24 makes that recovery real rather than a
            // promise: `StatusItemController.applicationShouldHandleReopen`
            // opens this window when the running app is opened again. The fork's
            // caption pointed at a relaunch action that never existed.
            SettingsCaption("Open \(AppInfo.productName) again from Applications to get back to these settings. You can quit it from General.")
          }
        }
      }

      Section("Sliders") {
        // Shown even on a Mac with no built-in display: a laptop's panel
        // disappears in clamshell, and hiding the control exactly when the lid
        // is closed would make the setting unreachable from the state it
        // governs.
        SettingRow("Apple and built-in displays already have a brightness slider in Control Center.") {
          Toggle("Show the built-in display in the menu bar", isOn: Binding(
            get: { !prefs.hideBuiltInDisplay },
            set: { shown in
              prefs.hideBuiltInDisplay = !shown
              // Also `.updateStatusItem`, not just a panel rebuild: with
              // `menuIcon == .sliderOnly` this pref decides `hasVisibleSlider`,
              // so without the fan-out the icon would only catch up on the next
              // hotplug.
              actions.prefDidChange(.hideBuiltInDisplay)
            }
          ))
          .prefIdentifier(.hideBuiltInDisplay)
        }

        // The caption carries the consequence because the panel's own row cannot:
        // a one-line row is what keeps the panel from resizing while its menu is
        // open, so this is where the reach gets stated (A-21).
        SettingRow("Keep Display Awake stops the display sleeping until you turn it off or quit. While it is on, OLED care's idle dimming, blackout and unfocused dimming do not start. Hiding the row here does not turn it off.") {
          Toggle("Show Keep Display Awake in the menu bar", isOn: Binding(
            get: { !prefs.hideKeepAwake },
            set: { shown in
              prefs.hideKeepAwake = !shown
              actions.prefDidChange(.hideKeepAwake)
            }
          ))
          .prefIdentifier(.hideKeepAwake)
        }

        SettingRow("DDC-controlled displays only, and results vary by monitor.") {
          Toggle("Show a contrast slider", isOn: Binding(
            get: { prefs.showContrast },
            set: { shown in
              prefs.showContrast = shown
              actions.prefDidChange(.showContrast)
            }
          ))
          .prefIdentifier(.showContrast)
        }
      }
      .id(Self.slidersSectionID)

      Section("Slider Appearance") {
        Toggle("Snap to 25% steps", isOn: Binding(
          get: { prefs.enableSliderSnap },
          set: { enabled in
            prefs.enableSliderSnap = enabled
            actions.prefDidChange(.enableSliderSnap)
          }
        ))
        .prefIdentifier(.enableSliderSnap)
        // The caption must not promise a 0% stop on every slider: volume rows
        // snap on `SliderSnap.stopsWithoutZero` (D29), because landing on 0 is
        // a mute event in `DDCValueController.apply` and, under
        // `enableMuteUnmute`, a persistent VCP 0x8D hardware mute. A cosmetic
        // convenience must not be able to cause that from the bottom 3% of a
        // drag.
        SettingRow("Snapping pulls a slider to the nearest 25%, 50%, 75% or 100% position while you drag (and to 0% for brightness and contrast). Percentages show the exact value next to each slider.") {
          Toggle("Show percentages", isOn: Binding(
            get: { prefs.enableSliderPercent },
            set: { enabled in
              prefs.enableSliderPercent = enabled
              actions.prefDidChange(.enableSliderPercent)
            }
          ))
          .prefIdentifier(.enableSliderPercent)
        }
      }

      indicatorSection
    }
    .formStyle(.grouped)
  }

  /// Where the pills a key press puts on screen sit. Two pickers rather than
  /// one so each kind has a stable home: volume always reports in one place,
  /// brightness in another. Not a way to see both at once: the HUD keys one
  /// window per display, so on a single display the two kinds take turns in it.
  ///
  /// Each row's caption describes ITS OWN control, because `SettingRow`
  /// republishes the caption as that control's accessibility hint: a shared
  /// sentence under one picker would be spoken as a fact about that picker
  /// alone.
  ///
  /// "Indicator" is the house term for these (the Keyboard pane and each
  /// display's Advanced page both use it); "OSD" and "HUD" are internal words
  /// and never appear here.
  @ViewBuilder private var indicatorSection: some View {
    Section {
      SettingRow("One style for every indicator, on every display.") {
        Picker("Indicator style:", selection: Binding(
          get: { prefs.hudStyle },
          set: { style in
            prefs.hudStyle = style
            actions.prefDidChange(.hudStyle)
          }
        )) {
          // `HUDStyle.pickerOrder`, consumed like every enum picker here even
          // though it matches raw order today, so a future case slots into
          // reading order without renumbering raws.
          ForEach(HUDStyle.pickerOrder, id: \.self) { style in
            Text(label(for: style)).tag(style)
          }
        }
        .prefIdentifier(.hudStyle)
      }

      SettingRow("Contrast uses this position too.") {
        Picker("Brightness indicator position:", selection: Binding(
          get: { prefs.hudPositionBrightness },
          set: { position in
            prefs.hudPositionBrightness = position
            actions.prefDidChange(.hudPositionBrightness)
          }
        )) {
          // `HUDPlacement.pickerOrder`, never `allCases`: raw 0 is the top-right
          // position (the one every earlier build drew), so raw order is not
          // reading order. Same rule as the menu-bar icon popup above.
          ForEach(HUDPlacement.pickerOrder, id: \.self) { position in
            Text(label(for: position)).tag(position)
          }
        }
        .prefIdentifier(.hudPositionBrightness)
      }

      SettingRow("Mute uses this position too. The indicator appears on the display the keys act on.") {
        Picker("Volume indicator position:", selection: Binding(
          get: { prefs.hudPositionVolume },
          set: { position in
            prefs.hudPositionVolume = position
            actions.prefDidChange(.hudPositionVolume)
          }
        )) {
          ForEach(HUDPlacement.pickerOrder, id: \.self) { position in
            Text(label(for: position)).tag(position)
          }
        }
        .prefIdentifier(.hudPositionVolume)
      }
    } header: {
      Text("On-Screen Indicators")
    } footer: {
      // The preview depicts both kinds at once so both position choices stay
      // visible (KMR-A5); this line keeps what the screen actually does from
      // being misread off that picture.
      SettingsCaption("On screen, the two kinds of indicator take turns in one window per display; the preview shows both so each position stays visible.")
    }
    .id(Self.indicatorsSectionID)
  }

  /// Reads as one sentence with the row label: "Indicator style: Match macOS"
  /// (KMR-A3). Exhaustive, so a future `HUDStyle` case is a compile error
  /// rather than a blank row.
  private func label(for style: HUDStyle) -> LocalizedStringKey {
    switch style {
    case .system: "Match macOS"
    case .segments: "Segmented"
    case .compact: "Compact"
    }
  }

  /// Reads as one sentence with the row label: "Brightness indicator position:
  /// Top left". Exhaustive, so a future `HUDPosition` case is a compile error
  /// rather than a blank row.
  private func label(for position: HUDPosition) -> LocalizedStringKey {
    switch position {
    case .topLeft: "Top left"
    case .topCenter: "Top center"
    case .topRight: "Top right"
    }
  }

  /// Written so the popup reads as one sentence with its label — "Show the menu
  /// bar icon: When an external display is connected" — rather than four
  /// independent phrases (D25). Exhaustive, so a future `MenuIcon` case is a
  /// compile error here rather than a blank row.
  private func label(for mode: MenuIcon) -> LocalizedStringKey {
    switch mode {
    case .show: "Always"
    case .sliderOnly: "When a display slider is available"
    case .externalOnly: "When an external display is connected"
    case .hide: "Never"
    }
  }
}
