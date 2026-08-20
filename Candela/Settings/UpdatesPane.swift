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

  var body: some View {
    @Bindable var updater = updater
    Form {
      Section {
        LabeledContent("Current version") {
          Text("\(AppInfo.version) (build \(AppInfo.build))")
        }
        SettingRow(caption: SettingsCaption(verbatim: Self.checkNowCaption(lastCheck: updater.lastUpdateCheckDate))) {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        }
      }
      Section {
        Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
        SettingsCaption("Candela checks about once a day and always asks before installing anything.")
      }
    }
    .formStyle(.grouped)
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
