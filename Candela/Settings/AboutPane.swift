import AppKit
import CandelaKit
import SwiftUI

/// `@MainActor` matches the other four panes: `View` is not a globally-isolated
/// protocol, so only `body` would otherwise be main-actor, and
/// `SettingsActions` is a `@MainActor` type.
///
/// Two deliberate omissions. **No Donate button and no project links** (D26):
/// every fork link points at a project Candela is not, and Candela has no
/// public URL yet. **No updater section**: Sparkle is not a dependency and the
/// spec forbids adding one, so a "Check for Updates" button would have nothing
/// behind it.
@MainActor
struct AboutPane: View {
  @Environment(SettingsActions.self) private var actions

  var body: some View {
    Form {
      Section {
        VStack(spacing: 8) {
          Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
          Text(AppInfo.productName)
            .font(.system(size: 24, weight: .semibold))
          // One string, not four interpolated fragments — the fork assembled
          // "Version 4.3.4 Build 6262" from separate localized words, which no
          // translation could reorder.
          Text("Version \(AppInfo.version) (build \(AppInfo.build))")
            .font(.callout)
            .foregroundStyle(.secondary)
          // A credit, not a claim of authorship over the acknowledged work
          // below: kept one step quieter than the version line so the hero
          // still reads version-first.
          Text(verbatim: "Ryder Selikow")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      Section {
        // D14: the first-run flow must stay findable after it is dismissed.
        // This is the only way back to it, which is why it is a pane-level
        // button and not buried in a disclosure. "Setup" is the user-facing
        // name — the same word Settings → General's reset alert uses; the
        // internal name "onboarding" never appears in the UI.
        Button("Run Setup Again…") { actions.showOnboarding() }
        SettingsCaption("Walks through Open at Login, the keyboard keys and the Accessibility permission again.")
      }
      // The report's second entry point (spec §7). The first is on a display's
      // Diagnostics page, which disappears with the display — and the report a
      // person most wants is the one about the monitor that just stopped
      // working. This one is always reachable.
      Section("Support") {
        SettingRow("Covers every display. The report doesn't include serial numbers.") {
          DiagnosticsReportActions()
        }
      }
      Section("Acknowledgements") {
        LabeledContent("MonitorControl") {
          Text("MIT (DDC/CI transport and the behavior this app is measured against)")
        }
        LabeledContent("KeyboardShortcuts") {
          Text("MIT (Sindre Sorhus)")
        }
        SettingsCaption(copyrightLine)
      }
    }
    .formStyle(.grouped)
  }

  /// `String(year)`, never the bare Int: interpolating an Int into a
  /// `LocalizedStringKey` formats it with grouping separators and renders
  /// "2,026".
  private var copyrightLine: LocalizedStringKey {
    let year = Calendar.current.component(.year, from: Date())
    return "© \(String(year)) \(AppInfo.productName) contributors. MIT licensed."
  }
}
