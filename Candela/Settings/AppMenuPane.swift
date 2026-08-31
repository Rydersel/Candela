import CandelaKit
import SwiftUI

/// The menu-bar icon, the panel's sliders and the on-screen indicators: what
/// Candela puts on screen outside its own windows.
///
/// The indicator positions live here rather than under Keyboard because they
/// are an appearance choice. Keyboard decides which display a press acts on;
/// this decides where the answer is drawn.
///
/// D26 cut the fork's menu-items-style popup and tick-marks toggle; D32 files
/// `menuItemStyle` and `showTickMarks` as reserved-and-inert, keeping the schema
/// slots while nothing reads them and this pane writes neither. The fork's
/// app-wide slider toggles are cut too: each display's own destination says the
/// same thing more precisely.
///
/// `@MainActor` is load-bearing: a `View`'s properties are nonisolated under
/// `SWIFT_STRICT_CONCURRENCY: complete`, so `SettingsActions` could not be held
/// or touched outside `body` without it.
@MainActor
struct AppMenuPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  /// Scroll anchors for the preview's click-to-jump (KMR-A5). On the section
  /// container, not a row: the jump should land the section heading at the top.
  private static let slidersSectionID = "menuBar.sliders"
  private static let indicatorsSectionID = "menuBar.indicators"

  var body: some View {
    // `menuIcon` is written from OUTSIDE this pane: ⌘-dragging the status item
    // off the menu bar persists `.hide` (D5). Prefs are not observable, so the
    // revision bump is the only thing that re-reads them and flips the popup.
    let _ = model.prefsRevision
    // The scaffold's reading variant: the page scrolls, and the preview's
    // doorways need the proxy that drives it.
    SettingsPageScaffold(reading: { proxy in
      SettingsPageHeader(
        title: "Menu Bar",
        subtitle:
          "What Candela puts on screen outside its own windows: the icon, the sliders behind it, and the indicators a key press draws."
      )

      preview(proxy: proxy)

      SettingsCardSection(title: "Menu Bar") {
        menuIconRow
      }

      SettingsCardSection(title: "Sliders") {
        builtInDisplayRow
        SettingsCardDivider()
        keepAwakeRow
        SettingsCardDivider()
        combinedBrightnessRow
        SettingsCardDivider()
        contrastRow
      }
      .id(Self.slidersSectionID)

      SettingsCardSection(title: "Slider Appearance") {
        snapRow
        SettingsCardDivider()
        percentRow
      }

      indicatorSection
    })
  }

  // MARK: - Preview

  /// The pane's subject, drawn (KMR7). The widgets are doorways (KMR-A5):
  /// clicking one scrolls to the section that configures it. It depicts the real
  /// widgets, not this window's look (SV13); only the frame is this window's.
  private func preview(proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 8) {
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

  // MARK: - Menu bar

  private var menuIconRow: some View {
    SettingRow {
      VStack(alignment: .leading, spacing: 6) {
        ThemedChoiceRow(label: "Show the menu bar icon:", selection: Binding(
          get: { prefs.menuIcon },
          set: { mode in
            prefs.menuIcon = mode
            actions.prefDidChange(.menuIcon)
          }
        )) {
          // `MenuIconPolicy.pickerOrder`, never `MenuIcon.allCases`: raw order
          // is not reading order, so iterating allCases would silently reorder
          // the popup (D5).
          ForEach(MenuIconPolicy.pickerOrder, id: \.self) { mode in
            Text(label(for: mode)).tag(mode)
          }
        }
        .prefIdentifier(.menuIcon)
        if prefs.menuIcon != .show {
          // Every mode but "Always" can leave the user with no icon and no way
          // in. `StatusItemController.applicationShouldHandleReopen` opens this
          // window when the running app is opened again (SO24).
          SettingsCaption("Open \(AppInfo.productName) again from Applications to get back to these settings. You can quit it from General.")
        }
      }
    }
  }

  // MARK: - Sliders

  /// Shown even on a Mac with no built-in display: a laptop's panel disappears
  /// in clamshell, and hiding the control exactly when the lid is closed would
  /// make the setting unreachable from the state it governs.
  private var builtInDisplayRow: some View {
    SettingRow("Apple and built-in displays already have a brightness slider in Control Center.") {
      Toggle("Show the built-in display in the menu bar", isOn: Binding(
        get: { !prefs.hideBuiltInDisplay },
        set: { shown in
          prefs.hideBuiltInDisplay = !shown
          // Also `.updateStatusItem`, not just a panel rebuild: under
          // `.sliderOnly` this pref decides `hasVisibleSlider`, so without the
          // fan-out the icon catches up only on the next hotplug.
          actions.prefDidChange(.hideBuiltInDisplay)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.hideBuiltInDisplay)
    }
  }

  /// The caption carries the consequence because the panel's own row cannot: a
  /// one-line row is what keeps the panel from resizing while its menu is open,
  /// so the reach gets stated here (A-21).
  private var keepAwakeRow: some View {
    SettingRow("Keep Display Awake stops the display sleeping until you turn it off or quit. While it is on, OLED care's idle dimming, blackout and unfocused dimming do not start. Hiding the row here does not turn it off.") {
      Toggle("Show Keep Display Awake in the menu bar", isOn: Binding(
        get: { !prefs.hideKeepAwake },
        set: { shown in
          prefs.hideKeepAwake = !shown
          actions.prefDidChange(.hideKeepAwake)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.hideKeepAwake)
    }
  }

  /// The row only exists with two or more displays it can command, so the
  /// caption says what it is rather than promising it is on screen.
  private var combinedBrightnessRow: some View {
    SettingRow("One slider that sets every display to the same brightness. Shown with two or more displays; a display with keyboard control off is left out.") {
      Toggle("Show an All Displays brightness slider", isOn: Binding(
        get: { !prefs.hideCombinedBrightness },
        set: { shown in
          prefs.hideCombinedBrightness = !shown
          actions.prefDidChange(.hideCombinedBrightness)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.hideCombinedBrightness)
    }
  }

  private var contrastRow: some View {
    SettingRow("DDC-controlled displays only, and results vary by monitor.") {
      Toggle("Show a contrast slider", isOn: Binding(
        get: { prefs.showContrast },
        set: { shown in
          prefs.showContrast = shown
          actions.prefDidChange(.showContrast)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.showContrast)
    }
  }

  // MARK: - Slider appearance

  private var snapRow: some View {
    SettingRow {
      Toggle("Snap to 25% steps", isOn: Binding(
        get: { prefs.enableSliderSnap },
        set: { enabled in
          prefs.enableSliderSnap = enabled
          actions.prefDidChange(.enableSliderSnap)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.enableSliderSnap)
    }
  }

  /// The caption must not promise a 0% stop on every slider: volume rows snap
  /// on `SliderSnap.stopsWithoutZero` (D29), because landing on 0 is a mute in
  /// `DDCValueController.apply` and, under `enableMuteUnmute`, a persistent VCP
  /// 0x8D hardware mute a cosmetic convenience must never cause.
  private var percentRow: some View {
    SettingRow("Snapping pulls a slider to the nearest 25%, 50%, 75% or 100% position while you drag (and to 0% for brightness and contrast). Percentages show the exact value next to each slider.") {
      Toggle("Show percentages", isOn: Binding(
        get: { prefs.enableSliderPercent },
        set: { enabled in
          prefs.enableSliderPercent = enabled
          actions.prefDidChange(.enableSliderPercent)
        }
      ))
      .themedSwitch()
      .prefIdentifier(.enableSliderPercent)
    }
  }

  // MARK: - On-screen indicators

  /// Where the pills a key press puts on screen sit. Two pickers so each kind
  /// has a stable home, not a way to see both at once: the HUD keys one window
  /// per display, so the two kinds take turns in it.
  ///
  /// Each row's caption describes ITS OWN control, because `SettingRow`
  /// republishes the caption as that control's accessibility hint.
  ///
  /// "Indicator" is the user-facing term; "OSD" and "HUD" never appear here.
  private var indicatorSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCardSection(title: "On-Screen Indicators") {
        SettingRow("One style for every indicator, on every display.") {
          ThemedChoiceRow(label: "Indicator style:", selection: Binding(
            get: { prefs.hudStyle },
            set: { style in
              prefs.hudStyle = style
              actions.prefDidChange(.hudStyle)
            }
          )) {
            // `HUDStyle.pickerOrder` even though it matches raw order today,
            // so a future case slots into reading order without renumbering
            // raws.
            ForEach(HUDStyle.pickerOrder, id: \.self) { style in
              Text(label(for: style)).tag(style)
            }
          }
          .prefIdentifier(.hudStyle)
        }

        SettingsCardDivider()

        SettingRow("Contrast uses this position too.") {
          ThemedChoiceRow(label: "Brightness indicator position:", selection: Binding(
            get: { prefs.hudPositionBrightness },
            set: { position in
              prefs.hudPositionBrightness = position
              actions.prefDidChange(.hudPositionBrightness)
            }
          )) {
            // `HUDPlacement.pickerOrder`, never `allCases`: raw 0 is top-right,
            // so raw order is not reading order.
            ForEach(HUDPlacement.pickerOrder, id: \.self) { position in
              Text(label(for: position)).tag(position)
            }
          }
          .prefIdentifier(.hudPositionBrightness)
        }

        SettingsCardDivider()

        SettingRow("Mute uses this position too. The indicator appears on the display the keys act on.") {
          ThemedChoiceRow(label: "Volume indicator position:", selection: Binding(
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
      }
      // The preview shows both kinds at once so both positions stay visible
      // (KMR-A5); this line stops that picture reading as what the screen does.
      SettingsCaption("On screen, the two kinds of indicator take turns in one window per display; the preview shows both so each position stays visible.")
    }
    .id(Self.indicatorsSectionID)
  }

  // MARK: - Labels

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

  /// Reads as one sentence with the row label: "Show the menu bar icon: When an
  /// external display is connected" (D25). Exhaustive, so a future `MenuIcon`
  /// case is a compile error rather than a blank row.
  private func label(for mode: MenuIcon) -> LocalizedStringKey {
    switch mode {
    case .show: "Always"
    case .sliderOnly: "When a display slider is available"
    case .externalOnly: "When an external display is connected"
    case .hide: "Never"
    }
  }
}
