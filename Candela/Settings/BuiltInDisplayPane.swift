import CandelaKit
import SwiftUI

/// The built-in display's destination.
///
/// macOS owns built-in brightness, which is why this page has no brightness
/// control, and the old Displays pane read that as "nothing to set here" and
/// rendered a dead-end caption. Two things it was wrong about. `isDisabled`
/// genuinely applies here:
/// `stepBrightnessBuiltIn` and `stepBrightness(displayIDs:)` both filter
/// through `keyEnabledStates`, which reads it for the built-in slot. It had no
/// UI only because the old pane iterated `model.displays`, which is
/// external-only. And resolution applies here in full: the built-in is in the
/// configurator's list, its identity has a first-class persistence key, and the
/// reapply pass already walks it, so the only thing ever missing was a surface
/// to make the choice on.
///
/// "Show the built-in display in the menu bar" deliberately does NOT
/// live here. A laptop's panel disappears in clamshell, so a control governing
/// whether this row exists cannot live inside it — it would vanish at exactly
/// the moment it is needed. It stays in Menu Bar, and the button below
/// navigates there rather than duplicating it (D26 cut duplicate hide toggles).
@MainActor
struct BuiltInDisplayPane: View {
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Pop restoration (a11y contract 1): whichever chevron row pushed takes
  /// focus back when its page pops. Two of them now, All Sizes and Diagnostics.
  @FocusState private var focusedRow: DisplaySubPage?

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "builtIn") }
  /// The same seam every per-display write goes through, for the same reason:
  /// mutate, then fan out. The engine reads prefs at construction and at key
  /// time, not reactively, so a write without propagation is a dead control.
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: "builtIn", actions: actions)
  }
  private var catalog: DisplayModeCoordinator.Catalog? {
    model.builtIn.flatMap { model.displayModes.catalogs[$0.id] }
  }

  var body: some View {
    let _ = model.prefsRevision
    SettingsPageScaffold {
      // The same opening every external page gets, in the variant that drops
      // the external-only facts. Conditional on the slot rather than assumed:
      // in clamshell the built-in departs while this pane can still be the
      // restored selection for one frame.
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
        // Renders nothing where the sensor or its symbols are missing, so on
        // such a machine this card falls back to the caption alone. No hairline
        // between the two: the sentence explains the card, and it has to read
        // as the explanation whether or not the row above it exists.
        AmbientBrightnessRow()
        SettingsCaption("macOS controls the built-in display's brightness directly, so there is nothing else to set here. \(AppInfo.productName) reads its level to keep your other displays in step.")
          .padding(.vertical, 6)
      }

      SettingsCardSection(title: "Menu Bar") {
        SettingRow("Whether this display's slider appears in the menu bar is set under Menu Bar, so it stays reachable when the lid is closed and this display disappears.") {
          Button("Open Menu Bar Settings") { selection = .pane(.menuBar) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("Open Menu Bar Settings")
        }
      }

      // DT45: the built-in gets Diagnostics too. "Why can't hardware control
      // reach my laptop screen?" is one of the questions that feature exists
      // to answer, and the route belongs on the page for the display it is
      // about. A chevron to the sub-page since Task 13 (spec §8); no readback
      // preview, because the built-in has no wire for a read verdict to be
      // about.
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
    // The built-in never passes through the launch warm-up (that walks
    // `model.displays`, which is external-only), so without this its catalog
    // stays absent: the Diagnostics "Current mode" row would have nothing to
    // report and the Display section below would never appear at all. Any LATER
    // change, ours or System Settings' or a lid cycle, re-enumerates through the
    // coordinator's own screen-parameters observer, which runs whether or not
    // this page is on screen.
    // Hung off the page root rather than off a card, which is where the
    // grouped `Form` this page used to be required it (a lifecycle modifier on
    // a `Section` was not reliably applied) and where it still belongs: the
    // enumeration is the page's, not one card's.
    .task(id: model.builtIn?.id) {
      guard let id = model.builtIn?.id else { return }
      model.displayModes.refreshCatalog(for: id)
    }
  }

  /// The laptop panel's own resolution controls, over the same coordinator, the
  /// same curated rows and the same preview-with-countdown every external gets.
  ///
  /// It is the one page in the window where the display being reconfigured is
  /// also the display the question is asked on, which is a reason to keep the
  /// countdown rather than to skip it: a mode that leaves this panel unreadable
  /// leaves nothing to answer with, and the expiry is what recovers it.
  ///
  /// Three things an external's Display section has are deliberately absent
  /// here. Synthesized sizes: SS14 keeps the built-in out entirely, and the
  /// catalog carries no stops for it. Mirroring and rotation: neither is part of
  /// this page's scope, so they are not offered rather than offered broken. The
  /// density recommendation: the built-in never passes through display
  /// discovery, so no physical size is ever filed for it and the model abstains,
  /// which would leave a callout that could not appear.
  @ViewBuilder private var displaySection: some View {
    // A nil catalog is "not enumerated yet", NOT "no modes": rendering an
    // empty state for it would flash false copy on every pane switch. The
    // built-in is never warmed at launch (that pass walks the external list),
    // so this page's own `.task` is what fills it, one frame in.
    if let catalog {
      SettingsCardSection(title: "Display") {
        DisplaySizeRows(catalog: catalog)

        if !catalog.all.isEmpty {
          // Never the card's first row: the size rows above always draw
          // something once there is a catalog, and there is one here.
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
