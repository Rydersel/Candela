import CandelaKit
import SwiftUI

/// The built-in display's destination.
///
/// It has almost no per-display settings, because macOS owns built-in
/// brightness — but "almost" is not "none", and the old Displays pane rendered
/// a dead-end caption saying otherwise. `isDisabled` genuinely applies here:
/// `stepBrightnessBuiltIn` and `stepBrightness(displayIDs:)` both filter
/// through `keyEnabledStates`, which reads it for the built-in slot. It had no
/// UI only because the old pane iterated `model.displays`, which is
/// external-only.
///
/// "Show the built-in display in the menu bar panel" deliberately does NOT
/// live here. A laptop's panel disappears in clamshell, so a control governing
/// whether this row exists cannot live inside it — it would vanish at exactly
/// the moment it is needed. It stays in Menu Bar, and the button below
/// navigates there rather than duplicating it (D26 cut duplicate hide toggles).
@MainActor
struct BuiltInDisplayPane: View {
  @Binding var selection: SettingsDestination?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "builtIn") }
  /// The same seam every per-display write goes through, for the same reason:
  /// mutate, then fan out. The engine reads prefs at construction and at key
  /// time, not reactively, so a write without propagation is a dead control.
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: "builtIn", actions: actions)
  }

  var body: some View {
    let _ = model.prefsRevision
    Form {
      Section("Keyboard") {
        Toggle("Control this display with the keyboard", isOn: Binding(
          get: { !prefs.isDisabled },
          set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
        ))
        SettingsCaption("When off, the brightness keys skip the built-in display.")
      }

      Section("Brightness") {
        SettingsCaption("macOS controls the built-in display's brightness directly, so there is nothing to set here. \(AppInfo.productName) reads its level to keep your other displays in step.")
      }

      Section("Menu bar panel") {
        Button("Open Menu Bar Settings") { selection = .pane(.menuBar) }
        SettingsCaption("Whether this display's slider appears in the panel is set under Menu Bar, so it stays reachable when the lid is closed and this display disappears.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Text(verbatim: model.builtIn?.display.name ?? "Built-in Display"))
  }
}
