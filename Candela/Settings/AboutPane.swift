import AppKit
import CandelaKit
import SwiftUI

/// `@MainActor` matches every other pane: on `View` only `body` is isolated,
/// and both `SettingsActions` and `UpdaterModel` are `@MainActor` types.
///
/// No Donate button and no project links: every fork link points at a
/// project Candela is not.
///
/// Sparkle owns every updater setting (`SUEnableAutomaticChecks` and friends
/// are its schema, not `PrefName` cases), so writes here go through
/// `UpdaterModel` and we persist nothing.
@MainActor
struct AboutPane: View {
  @Environment(SettingsActions.self) private var actions
  @Environment(UpdaterModel.self) private var updater
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    @Bindable var updater = updater
    SettingsPageScaffold {
      hero

      // Directly under the version it updates: the hero says which build runs,
      // this says when it last looked for a newer one.
      SettingsCardSection(title: "Software Update") {
        // The sentence belongs to the row, not the button: `SettingsActionRow`
        // republishes it as the control's accessibility hint (contract 3).
        SettingsActionRow(verbatim: checkNowLine, dividerFollows: true) {
          // Stated twice, like Run Setup Again below: SwiftUI does not publish
          // a `Button`'s own title to the accessibility layer.
          Button("Check for Updates") { updater.checkForUpdates() }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .accessibilityLabel("Check for Updates")
            .disabled(!updater.canCheckForUpdates)
        }
        SettingsCardDivider()
        SettingRow("When this is on, \(AppInfo.productName) checks about once a day, in the background.") {
          Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            .themedSwitch()
        }
        SettingsCardDivider()
        // Holds however the toggle above is set, so it sits under both rows
        // instead of in a caption that is conditional on the toggle.
        SettingsRowNote("\(AppInfo.productName) never installs an update without asking first.")
      }

      SettingsCardSection(title: "Setup") {
        // The first-run flow stays findable after dismissal, and this is
        // the only way back to it. "Setup" is the user-facing name; the
        // internal name "onboarding" never appears in the UI.
        SettingsActionRow(
          "Walks through Open at Login, the keyboard keys and the Accessibility permission again."
        ) {
          Button("Run Setup Again") { actions.showOnboarding() }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .accessibilityLabel("Run Setup Again")
        }
      }

      // The report's second entry point (spec §7). The first lives on a
      // display's Diagnostics page, which disappears with the display; this one
      // survives the monitor that just stopped working.
      SettingsCardSection(title: "Support") {
        SettingsActionRow("Covers every display. The report doesn't include serial numbers.") {
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

  /// The window's only float; `onboardingFloat` stills it under Reduce
  /// Motion.
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

      // One string, not assembled fragments: the fork built "Version 4.3.4
      // Build 6262" from separate localized words no translation could reorder.
      Text("Version \(AppInfo.version)")
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
  /// The locale is pinned because the app test target asserts these words
  /// verbatim and the app ships English only.
  static func checkNowCaption(lastCheck: Date?, now: Date = .now) -> String {
    guard let lastCheck else {
      return "\(AppInfo.productName) hasn't checked for updates yet."
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = .full
    let relative = formatter.localizedString(for: lastCheck, relativeTo: now)
    return "Last checked \(relative)."
  }
}
