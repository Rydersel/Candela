import AppKit
import CandelaKit
import SwiftUI

/// `@MainActor` matches every other pane: `View` is not a globally-isolated
/// protocol, so only `body` would otherwise be main-actor, and both
/// `SettingsActions` and `UpdaterModel` are `@MainActor` types.
///
/// One deliberate omission. **No Donate button and no project links** (D26):
/// every fork link points at a project Candela is not, and Candela has no
/// public URL yet.
///
/// The software update controls were their own pane until 2026-08-20, when
/// Ryder merged the two: one page holds the version and the controls that
/// change it, which is where a person looks for both. Sparkle is still the
/// store for every updater setting (`SUEnableAutomaticChecks` and friends are
/// Sparkle's schema, not `PrefName` cases), so every write here goes through
/// `UpdaterModel` and nothing is persisted by us.
@MainActor
struct AboutPane: View {
  @Environment(SettingsActions.self) private var actions
  @Environment(UpdaterModel.self) private var updater
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    @Bindable var updater = updater
    SettingsPageScaffold {
      hero

      // Directly under the version it updates: the hero states which build is
      // running, and this states when it last looked for a newer one.
      SettingsCardSection(title: "Software Update") {
        // The caption is the row's, not hand-attached to the button:
        // `SettingRow` republishes it as the control's accessibility hint
        // (contract 3), which the standalone lockup could not do.
        SettingRow(caption: SettingsCaption(verbatim: checkNowLine)) {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .disabled(!updater.canCheckForUpdates)
        }
        SettingsCardDivider()
        SettingRow("When this is on, \(AppInfo.productName) checks about once a day, in the background.") {
          Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            .themedSwitch()
        }
        SettingsCardDivider()
        // The promise that holds however the toggle above is set, so it sits
        // under both rows rather than in either one's caption: the cadence
        // claim is the toggle's and is conditional on the toggle being on.
        SettingsRowNote("\(AppInfo.productName) never installs an update without asking first.")
      }

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

  // MARK: - Update copy

  private var checkNowLine: String {
    Self.checkNowCaption(lastCheck: updater.lastUpdateCheckDate)
  }

  /// Never claims the app is up to date: only a completed check knows that, and
  /// only Sparkle's own window reports it.
  ///
  /// Nameable so the app test target can pin it (AT10). The locale is fixed
  /// because the words are asserted verbatim and the app ships English only
  /// (D25); a machine-locale formatter would fail the test on any other locale.
  static func checkNowCaption(lastCheck: Date?, now: Date = .now) -> String {
    guard let lastCheck else {
      // Interpolated like every sibling string on this page; the verbatim test
      // still pins the full sentence because the name resolves to the same
      // words.
      return "\(AppInfo.productName) hasn't checked for updates yet."
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = .full
    let relative = formatter.localizedString(for: lastCheck, relativeTo: now)
    return "Last checked \(relative)."
  }
}
