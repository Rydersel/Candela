import CandelaKit
import SwiftUI

/// The menu-bar icon and the panel's sliders — the two things that decide what
/// the user sees when they click the status item.
///
/// Deliberately five controls. D26 cut the fork's "General menu items style"
/// popup and "Show slider tick marks" toggle, and D32 files both prefs as
/// reserved-and-inert: `menuItemStyle` and `showTickMarks` keep their keys so
/// the schema slots can never be reused, but nothing in Candela reads them,
/// they are not `PrefName` cases, and this pane writes neither. The fork's
/// app-wide "show brightness slider" / "show volume slider" toggles are cut
/// too — the per-display controls in the Displays pane say the same thing more
/// precisely — as are the `multiSliders` combined/relevant modes.
///
/// `@MainActor` as declared by the Task 3 stub — keep it. A `View`'s stored and
/// computed properties are nonisolated under `SWIFT_STRICT_CONCURRENCY:
/// complete`, so `SettingsActions` (itself `@MainActor`) could not be held or
/// touched outside `body` without it.
@MainActor
struct AppMenuPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `menuIcon` is written from OUTSIDE this pane: ⌘-dragging the status item
    // off the menu bar makes StatusItemController persist `.hide` (D5). Prefs
    // are plain UserDefaults and not observable, so the revision bump is the
    // only thing that re-reads them and flips the popup.
    let _ = model.prefsRevision
    Form {
      Section("Menu bar") {
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
          if prefs.menuIcon != .show {
            // Every mode but "Always" can leave the user with no status item and
            // therefore no panel. The fork's caption pointed at a relaunch action
            // that never existed; this one promises only what works today.
            SettingsCaption("With the icon hidden, open \(AppInfo.productName) again from Finder to get back here. You can quit it from the General pane.")
          }
        }
      }

      Section("Sliders") {
        // Shown even on a Mac with no built-in display: a laptop's panel
        // disappears in clamshell, and hiding the control exactly when the lid
        // is closed would make the setting unreachable from the state it
        // governs.
        SettingRow("Apple and built-in displays already have a brightness slider in Control Center.") {
          Toggle("Show the built-in display in the menu bar panel", isOn: Binding(
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
        }

        SettingRow("DDC-controlled displays only, and results vary by monitor.") {
          Toggle("Show a contrast slider", isOn: Binding(
            get: { prefs.showContrast },
            set: { shown in
              prefs.showContrast = shown
              actions.prefDidChange(.showContrast)
            }
          ))
        }
      }

      Section("Slider appearance") {
        Toggle("Snap to 25% steps", isOn: Binding(
          get: { prefs.enableSliderSnap },
          set: { enabled in
            prefs.enableSliderSnap = enabled
            actions.prefDidChange(.enableSliderSnap)
          }
        ))
        // The caption must not promise a 0% stop on every slider: volume rows
        // snap on `SliderSnap.stopsWithoutZero` (D29), because landing on 0 is
        // a mute event in `DDCValueController.apply` and, under
        // `enableMuteUnmute`, a persistent VCP 0x8D hardware mute. A cosmetic
        // convenience must not be able to cause that from the bottom 3% of a
        // drag.
        SettingRow("Snapping pulls a slider to the nearest 25%, 50%, 75% or 100% position while you drag — and to 0% for brightness and contrast. Percentages show the exact value next to each slider.") {
          Toggle("Show percentages", isOn: Binding(
            get: { prefs.enableSliderPercent },
            set: { enabled in
              prefs.enableSliderPercent = enabled
              actions.prefDidChange(.enableSliderPercent)
            }
          ))
        }
      }
    }
    .formStyle(.grouped)
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
