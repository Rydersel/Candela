import CandelaKit
import SwiftUI

/// The built-in display's destination.
///
/// macOS owns built-in brightness, so there is no brightness control here.
/// `isDisabled` still applies: both brightness-key paths filter through
/// `keyEnabledStates`, which reads it for the built-in slot. So does resolution:
/// the built-in is in the configurator's list with its own persistence key, and
/// the reapply pass already walks it.
///
/// "Show the built-in display in the menu bar" stays in Menu Bar (R16): a
/// laptop panel disappears in clamshell, so a control over whether this row
/// exists cannot live inside it. The button below navigates there (D26 cut
/// duplicate hide toggles).
@MainActor
struct BuiltInDisplayPane: View {
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Pop restoration (a11y contract 1): the chevron row that pushed takes focus
  /// back when its page pops.
  @FocusState private var focusedRow: DisplaySubPage?

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "builtIn") }
  /// Every per-display write goes through this seam (D27): the engine reads
  /// prefs at construction and at key time, not reactively, so a write without
  /// propagation is a dead control.
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: "builtIn", actions: actions)
  }
  private var catalog: DisplayModeCoordinator.Catalog? {
    model.builtIn.flatMap { model.displayModes.catalogs[$0.id] }
  }

  var body: some View {
    let _ = model.prefsRevision
    SettingsPageScaffold {
      // Conditional on the slot rather than assumed: in clamshell the built-in
      // departs while this pane can still be the restored selection for a frame.
      if let state = model.builtIn {
        DisplayHeroView(state: state, variant: .builtIn)
      }
      SettingsCardSection(title: "Keyboard") {
        SettingRow("When off, the brightness keys skip the built-in display.") {
          Toggle("Control this display with the keyboard", isOn: Binding(
            get: { !prefs.isDisabled },
            set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
          ))
          .themedSwitch()
          .prefIdentifier(.isDisabled, persistenceKey: "builtIn")
        }
      }

      displaySection

      SettingsCardSection(title: "Brightness") {
        // Renders nothing when the sensor is missing, so the card falls back to
        // the caption alone. No hairline: the caption has to read as the card's
        // explanation whether or not the row above it exists.
        AmbientBrightnessRow()
        SettingsRowNote("macOS controls the built-in display's brightness directly, so there is nothing else to set here. \(AppInfo.productName) reads its level to keep your other displays in step.")
      }

      SettingsCardSection(title: "Menu Bar") {
        SettingRow("Whether this display's slider appears in the menu bar is set under Menu Bar, so it stays reachable when the lid is closed and this display disappears.") {
          Button("Open Menu Bar Settings") { selection = .pane(.menuBar) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("Open Menu Bar Settings")
        }
      }

      // DT45: the built-in gets Diagnostics too, because "why can't hardware
      // control reach my laptop screen?" is one of the questions it answers. No
      // readback preview: the built-in has no wire for a read verdict.
      SettingsCardSection {
        NavigationRow(title: "Diagnostics", value: nil) { path.append(.diagnostics) }
          .focused($focusedRow, equals: .diagnostics)
      }
    }
    .onChange(of: path) { old, new in
      if new.count < old.count, let popped = old.last {
        focusedRow = popped
      }
    }
    // The built-in never passes through the launch warm-up (that walks the
    // external list), so without this its catalog stays absent and the Display
    // section never appears. Any later change re-enumerates through the
    // coordinator's own screen-parameters observer. Hung off the page root
    // rather than a card: the enumeration is the page's, not one card's.
    .task(id: model.builtIn?.id) {
      guard let id = model.builtIn?.id else { return }
      model.displayModes.refreshCatalog(for: id)
    }
  }

  /// The laptop panel's own resolution controls, over the same coordinator and
  /// rows every external gets. The one page where the display being reconfigured
  /// is the display the question is asked on, which is a reason to KEEP the
  /// countdown: a mode that leaves this panel unreadable leaves nothing to
  /// answer with, and the expiry is what recovers it.
  ///
  /// Absent on purpose: synthesized sizes (SS14 keeps the built-in out and the
  /// catalog carries no stops for it), mirroring and rotation (out of this
  /// page's scope), and the density recommendation (no physical size is ever
  /// filed for the built-in, so the model abstains).
  @ViewBuilder private var displaySection: some View {
    // A nil catalog is "not enumerated yet", NOT "no modes": an empty state
    // here would flash false copy on every pane switch.
    if let catalog {
      SettingsCardSection(title: "Display") {
        DisplaySizeRows(catalog: catalog)

        if !catalog.all.isEmpty {
          // Never the card's first row: the size rows above always draw
          // something once there is a catalog.
          SettingsCardDivider()
          RememberResolutionRow(displayID: catalog.display.id, persistenceKey: "builtIn")

          SettingsCardDivider()
          NavigationRow(
            title: DisplaySubPage.allModes.title,
            value: "\(catalog.all.count)",
            spokenValue: "\(catalog.all.count) modes"
          ) { path.append(.allModes) }
            .focused($focusedRow, equals: .allModes)
        }
      }
    }
  }
}
