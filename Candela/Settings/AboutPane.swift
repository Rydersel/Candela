import AppKit
import CandelaKit
import SwiftUI

/// `@MainActor` matches the other four panes: `View` is not a globally-isolated
/// protocol, so only `body` would otherwise be main-actor, and
/// `SettingsActions` is a `@MainActor` type.
///
/// One deliberate omission. **No Donate button and no project links** (D26):
/// every fork link points at a project Candela is not, and Candela has no
/// public URL yet. Update controls live in the Updates pane, not here: the
/// version line stays informational.
@MainActor
struct AboutPane: View {
  @Environment(SettingsActions.self) private var actions
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    SettingsPageScaffold {
      hero

      SettingsCardSection {
        // D14: the first-run flow must stay findable after it is dismissed.
        // This is the only way back to it, which is why it is a pane-level
        // button and not buried in a disclosure. "Setup" is the user-facing
        // name, the same word Settings, General's reset alert uses; the
        // internal name "onboarding" never appears in the UI.
        SettingRow(
          "Walks through Open at Login, the keyboard keys and the Accessibility permission again."
        ) {
          Button("Run Setup Again…") { actions.showOnboarding() }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .accessibilityLabel("Run Setup Again…")
        }
      }

      // The report's second entry point (spec §7). The first is on a display's
      // Diagnostics page, which disappears with the display, and the report a
      // person most wants is the one about the monitor that just stopped
      // working. This one is always reachable.
      SettingsCardSection(title: "Support") {
        SettingRow("Covers every display. The report doesn't include serial numbers.") {
          DiagnosticsReportActions()
        }
      }

      SettingsCardSection(title: "Acknowledgements") {
        LabeledContent("MonitorControl") {
          Text("MIT (DDC/CI transport and the behavior this app is measured against)")
        }
        SettingsCardDivider()
        // Reached us through MonitorControl, which adapted it, and named here
        // for the reason the attribution audit gives: a notice that travels
        // only in a source comment does not reach anyone running the app.
        // `MediaKeyEventTap.swift` credits both.
        LabeledContent("MediaKeyTap") {
          Text("MIT (Nicholas Hurden)")
        }
        SettingsCardDivider()
        LabeledContent("KeyboardShortcuts") {
          Text("MIT (Sindre Sorhus)")
        }
        SettingsCardDivider()
        LabeledContent("Sparkle") {
          Text("MIT (Sparkle Project, software updates)")
        }
      }

      Text(copyrightLine)
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }
  }

  // MARK: - Hero

  /// The mark floats over a soft halo rather than sitting in a frame: About is
  /// the one page with nothing to configure, so the object is the content. The
  /// float is the window's only one (SV8) and `onboardingFloat` stills it under
  /// Reduce Motion.
  private var hero: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(lighting.accent.opacity(0.14))
          .frame(width: 168, height: 168)
          .blur(radius: 44)
        Circle()
          .stroke(lighting.accent.opacity(0.10), lineWidth: 1)
          .frame(width: 138, height: 138)
        Circle()
          .stroke(lighting.accent.opacity(0.16), lineWidth: 1)
          .frame(width: 108, height: 108)
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
          .resizable()
          .frame(width: 92, height: 92)
          .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
      }
      .frame(height: 176)
      .onboardingFloat(active: true)
      .accessibilityHidden(true)

      Text(verbatim: AppInfo.productName)
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .foregroundStyle(SettingsTheme.titleColor)
        .settingsHeading()

      // One string, not four interpolated fragments: the fork assembled
      // "Version 4.3.4 Build 6262" from separate localized words, which no
      // translation could reorder.
      Text("Version \(AppInfo.version) (build \(AppInfo.build))")
        .font(.callout)
        .foregroundStyle(SettingsTheme.bodyColor)
        .monospacedDigit()

      // A credit, not a claim of authorship over the acknowledged work below:
      // kept one step quieter than the version line so the hero still reads
      // version-first.
      Text(verbatim: "Ryder Selikow")
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  /// `String(year)`, never the bare Int: interpolating an Int into a
  /// `LocalizedStringKey` formats it with grouping separators and renders
  /// "2,026".
  private var copyrightLine: LocalizedStringKey {
    let year = Calendar.current.component(.year, from: Date())
    return "© \(String(year)) \(AppInfo.productName) contributors. MIT licensed."
  }
}
