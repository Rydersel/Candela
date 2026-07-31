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

  /// Counts writes so a no-op can be distinguished from a rewrite of the same
  /// value — asserting on the stored value alone cannot tell those apart.
  private final class WriteCountingDefaults: InMemoryDefaults {
    private(set) var writes: [String] = []
    override func set(_ value: Any?, forKey key: String) {
      writes.append(key)
      super.set(value, forKey: key)
    }
  }

  @Test func currentVersionIsAnUntouchedNoOp() {
    // The branch that runs on EVERY normal launch, and the only one with no
    // coverage before this (Task 1 review, Minor 4). `stored == current` must
    // fall through the `stored < currentVersion` guard and write NOTHING.
    //
    // The write count is the whole point: relaxing the guard to `<=` would
    // re-record an identical value, so every value-based assertion would still
    // pass. Harmless while this function only bumps an integer — but the moment
    // a real migration lands, an off-by-one guard re-runs its side effects on
    // every launch, which is exactly the kind of bug that surfaces as data
    // drift months later.
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
    // First run is signalled by the ABSENCE of the key (D14). migrateIfNeeded
    // must not record it — onboarding completion does (Task 15), so an
    // interrupted first run re-onboards.
    let d = InMemoryDefaults()
    PrefsSchema.migrateIfNeeded(in: d)
    #expect(PrefsSchema.storedVersion(in: d) == nil)
  }
}
