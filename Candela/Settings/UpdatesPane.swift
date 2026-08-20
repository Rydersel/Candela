import SwiftUI

/// Software update settings, backed by the one Sparkle updater the app owns.
///
/// Deliberately small: Sparkle owns scheduling, the consent flow and the
/// install UI, so the pane exposes the two decisions a person can make (check
/// automatically, check now) and states the app's standing promise that
/// nothing installs without asking. `@MainActor` for the same reason as every
/// other pane: `UpdaterModel` is a `@MainActor` type and only `body` would
/// otherwise be isolated.
@MainActor
struct UpdatesPane: View {
  @Environment(UpdaterModel.self) private var updater
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    @Bindable var updater = updater
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Updates",
        // The promise that holds however the toggle below is set: nothing
        // installs itself. The cadence claim belongs to that toggle's caption,
        // where it is conditional on the toggle being on.
        subtitle: "\(AppInfo.productName) never installs an update without asking first."
      )

      hero

      SettingsCardSection(title: "Automatic Updates") {
        SettingRow("When this is on, \(AppInfo.productName) checks about once a day, in the background.") {
          Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            .themedSwitch()
        }
      }
    }
  }

  // MARK: - Hero

  /// The app's own state drawn once and large, with the page's one action under
  /// it. The lockup states the version it is running and when it last asked;
  /// it never claims to be up to date, which only a completed check knows and
  /// only Sparkle's own window reports.
  private var hero: some View {
    SettingsCard {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 18) {
          statusRing
          VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: "\(AppInfo.productName) \(AppInfo.version)")
              .font(.system(size: 19, weight: .bold, design: .rounded))
              .foregroundStyle(SettingsTheme.titleColor)
            Text("Build \(AppInfo.build)")
              .font(.callout)
              .foregroundStyle(SettingsTheme.bodyColor)
              .monospacedDigit()
            Text(verbatim: checkNowLine)
              .font(.caption)
              .foregroundStyle(SettingsTheme.faintColor)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }

        Button("Check for Updates…") { updater.checkForUpdates() }
          .buttonStyle(SettingsPrimaryButtonStyle())
          .disabled(!updater.canCheckForUpdates)
          // Accessibility contract 3 by hand: the sentence sits in the lockup
          // rather than in a `SettingRow`, so the hint is attached here.
          .accessibilityHint(Text(verbatim: checkNowLine))
      }
    }
    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
  }

  /// Decorative: everything it means is said in the lockup beside it.
  private var statusRing: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(0.10))
        .frame(width: 84, height: 84)
      Circle()
        .fill(accent.opacity(0.18))
        .frame(width: 58, height: 58)
      Circle()
        .stroke(accent.opacity(0.25), lineWidth: 1)
        .frame(width: 58, height: 58)
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 25, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: 84, height: 84)
    .accessibilityHidden(true)
  }

  private var accent: Color { lighting.accent }

  private var checkNowLine: String {
    Self.checkNowCaption(lastCheck: updater.lastUpdateCheckDate)
  }

  /// Nameable so the app test target can pin it (AT10). The locale is fixed
  /// because the words are asserted verbatim and the app ships English only
  /// (D25); a machine-locale formatter would fail the test on any other locale.
  static func checkNowCaption(lastCheck: Date?, now: Date = .now) -> String {
    guard let lastCheck else { return "Candela hasn't checked for updates yet." }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = .full
    let relative = formatter.localizedString(for: lastCheck, relativeTo: now)
    return "Last checked \(relative)."
  }
}
