import Foundation

/// In-memory `UserDefaults` for tests — no disk, no teardown.
///
/// `UserDefaults(suiteName:)` is disk-backed: cfprefsd writes the domain into
/// `~/Library/Preferences` at process exit, and `removePersistentDomain`
/// only empties it — a 42-byte stub plist survives every run. That left ~78
/// files per test run accumulating indefinitely (≈6k of them by the time it
/// was noticed), and no in-run unlink can win the race against the exit-time
/// write-back.
///
/// Overriding the documented primitives (`object(forKey:)`, `set(_:forKey:)`,
/// `removeObject(forKey:)`) routes every access into a dictionary. The typed
/// accessors are overridden too rather than trusted to funnel through the
/// primitives — a silent fall-through to the superclass would write test keys
/// into a real defaults domain, which is exactly the failure this class
/// exists to prevent. Each instance is an isolated store, so tests need no
/// unique suite names and no cleanup at all.
/// Not `final`: tests subclass this to spy on writes, which is the only way to
/// tell "wrote nothing" apart from "rewrote the same value".
class InMemoryDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Any] = [:]

  /// Named suite rather than `nil`: if any accessor ever escapes to the
  /// superclass, it lands in one inert scratch domain instead of polluting
  /// the test runner's standard defaults.
  init() { super.init(suiteName: "com.rydersel.Candela.tests.inmemory-fallback")! }

  override func object(forKey key: String) -> Any? { lock.withLock { storage[key] } }
  override func set(_ value: Any?, forKey key: String) { lock.withLock { storage[key] = value } }
  override func removeObject(forKey key: String) { lock.withLock { storage[key] = nil } }

  override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }

  /// Coerces the way the real `UserDefaults` documents, rather than casting to
  /// `Bool` and giving up. `defaults write <domain> <key> NO` stores the STRING
  /// "NO", and `wireTimingGuard` — an escape hatch a human types by hand — is
  /// read through this accessor. A strict double would have passed its tests
  /// while the shipped hatch ignored the commonest way of setting it.
  override func bool(forKey key: String) -> Bool {
    switch object(forKey: key) {
    case let number as NSNumber: return number.boolValue  // catches Bool and Int
    case let string as String: return (string as NSString).boolValue
    default: return false
    }
  }
  override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
  override func double(forKey key: String) -> Double { object(forKey: key) as? Double ?? 0 }
  override func float(forKey key: String) -> Float { object(forKey: key) as? Float ?? 0 }
  override func string(forKey key: String) -> String? { object(forKey: key) as? String }
  /// `ModePersistence` stores a JSON-encoded descriptor, making this the first
  /// `Data` accessor in the suite. Overridden for the same reason as the rest:
  /// a silent fall-through to the superclass would read the real defaults
  /// domain rather than this instance's dictionary.
  override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

  /// This instance's dictionary, not the superclass's merged domains — the
  /// same reason every accessor above is overridden (the superclass would
  /// report the fallback suite plus the global domain, i.e. never the keys the
  /// test wrote). `DisplayPrefs.hasAnyStoredValue` scans it, and it is what
  /// lets a test ask "what is left in the store?" rather than checking a
  /// hand-written list of keys — the only form that catches a key nobody
  /// remembered.
  override func dictionaryRepresentation() -> [String: Any] {
    lock.withLock { storage }
  }
}
