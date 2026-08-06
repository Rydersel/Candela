import Foundation

/// Prefs schema versioning (D13). Version 1 = the M5 settings surface.
///
/// A missing version means FIRST RUN (that absence is also the onboarding
/// trigger — D14 — so the version is recorded at onboarding completion, not
/// at launch). A stored version NEWER than `currentVersion` is left alone:
/// downgrades never wipe; the enum unknown-raw fallbacks carry the app.
public enum PrefsSchema {
  public static let currentVersion = 1
  static let versionKey = "prefsSchemaVersion"

  public static func storedVersion(in defaults: UserDefaults) -> Int? {
    defaults.object(forKey: versionKey) == nil ? nil : defaults.integer(forKey: versionKey)
  }

  public static func recordCurrentVersion(in defaults: UserDefaults) {
    defaults.set(currentVersion, forKey: versionKey)
  }

  /// Future versions add their per-key migrations here, switching on the
  /// stored version — the BrightnessController legacy-key transplant is the
  /// house pattern (migrate the key, leave the old one in place, never wipe).
  public static func migrateIfNeeded(in defaults: UserDefaults) {
    guard let stored = storedVersion(in: defaults), stored < currentVersion else { return }
    recordCurrentVersion(in: defaults)
  }
}
