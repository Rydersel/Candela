import Foundation

/// Prefs schema versioning. Version 1 is the 1.0 settings surface.
///
/// A missing version means FIRST RUN, which is also the onboarding trigger, so
/// the version is recorded at onboarding completion rather than at launch. A stored
/// version NEWER than `currentVersion` is left alone: downgrades never wipe, and the
/// enum unknown-raw fallbacks carry the app.
public enum PrefsSchema {
  public static let currentVersion = 1
  static let versionKey = "prefsSchemaVersion"

  public static func storedVersion(in defaults: UserDefaults) -> Int? {
    defaults.object(forKey: versionKey) == nil ? nil : defaults.integer(forKey: versionKey)
  }

  public static func recordCurrentVersion(in defaults: UserDefaults) {
    defaults.set(currentVersion, forKey: versionKey)
  }

  /// Future versions add per-key migrations here, switching on the stored version.
  /// House pattern: migrate the key, leave the old one in place, never wipe.
  public static func migrateIfNeeded(in defaults: UserDefaults) {
    guard let stored = storedVersion(in: defaults), stored < currentVersion else { return }
    recordCurrentVersion(in: defaults)
  }
}
