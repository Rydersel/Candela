import Foundation
import Testing
@testable import CandelaKit

@Suite("Prefs schema versioning (D13)")
struct PrefsSchemaTests {
  @Test func emptyDomainHasNoVersion() {
    #expect(PrefsSchema.storedVersion(in: InMemoryDefaults()) == nil)
  }

  @Test func recordWritesCurrentVersion() {
    let d = InMemoryDefaults()
    PrefsSchema.recordCurrentVersion(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == 1)
    #expect(d.integer(forKey: "prefsSchemaVersion") == 1)
  }

  @Test func downgradeNeverWipes() {
    // A future version is left alone and no other key is touched; the app runs
    // on its enum unknown-value fallbacks (D13). The fork wiped the whole domain.
    let d = InMemoryDefaults()
    d.set(99, forKey: "prefsSchemaVersion")
    d.set(true, forKey: "showContrast")
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == 99)
    #expect(d.bool(forKey: "showContrast"))
  }

  @Test func olderVersionMigratesForwardWithoutTouchingKeys() {
    let d = InMemoryDefaults()
    d.set(0, forKey: "prefsSchemaVersion")
    d.set(true, forKey: "showContrast")
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == 1)
    #expect(d.bool(forKey: "showContrast"))
  }

  /// Counts writes: asserting on the stored value cannot tell a no-op from a
  /// rewrite of the same value.
  private final class WriteCountingDefaults: InMemoryDefaults {
    private(set) var writes: [String] = []
    override func set(_ value: Any?, forKey key: String) {
      writes.append(key)
      super.set(value, forKey: key)
    }
  }

  @Test func currentVersionIsAnUntouchedNoOp() {
    // Relaxing the guard to `<=` would rewrite an identical value, so every
    // value-based assertion still passes. Once a real migration lands, that
    // off-by-one re-runs its side effects on every launch.
    let d = WriteCountingDefaults()
    d.set(PrefsSchema.currentVersion, forKey: "prefsSchemaVersion")
    d.set(true, forKey: "showContrast")
    let writesBefore = d.writes.count
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(d.writes.count == writesBefore) // no write at all, not "same value"
    #expect(PrefsSchema.storedVersion(in: d) == PrefsSchema.currentVersion)
    #expect(d.bool(forKey: "showContrast"))
  }

  @Test func anAbsentVersionIsLeftAbsent() {
    // Absence of the key signals first run (D14). Onboarding completion records
    // it, not this, so an interrupted first run re-onboards.
    let d = InMemoryDefaults()
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == nil)
  }
}
