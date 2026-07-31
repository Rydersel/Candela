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
    // A FUTURE version is left alone, and no other key is touched — the app
    // runs on its enum unknown-value fallbacks (D13; anti-fork: the fork
    // wipes the whole domain on any downgrade).
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

  @Test func anAbsentVersionIsLeftAbsent() {
    // First run is signalled by the ABSENCE of the key (D14). migrateIfNeeded
    // must not record it — onboarding completion does (Task 15), so an
    // interrupted first run re-onboards.
    let d = InMemoryDefaults()
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == nil)
  }
}
