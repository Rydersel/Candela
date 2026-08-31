import Foundation

/// In-memory `UserDefaults` for tests: no disk, no teardown.
///
/// `UserDefaults(suiteName:)` is disk-backed. cfprefsd writes the domain out at
/// process exit and `removePersistentDomain` only empties it, so a stub plist
/// survives every run and no in-run unlink beats the exit-time write-back.
/// Every typed accessor is overridden, not trusted to funnel through the
/// primitives: a silent fall-through would write test keys into a real domain.
/// Not `final` so tests can subclass to spy on writes, the only way to tell
/// "wrote nothing" from "rewrote the same value".
class InMemoryDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Any] = [:]

  /// Named suite rather than `nil` so an accessor that escapes to the superclass
  /// lands in one inert scratch domain, not the test runner's standard defaults.
  init() { super.init(suiteName: "com.rydersel.Candela.tests.inmemory-fallback")! }

  override func object(forKey key: String) -> Any? { lock.withLock { storage[key] } }
  override func set(_ value: Any?, forKey key: String) { lock.withLock { storage[key] = value } }
  override func removeObject(forKey key: String) { lock.withLock { storage[key] = nil } }

  override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
  override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }

  /// `defaults write <domain> <key> NO` stores the STRING "NO", and the
  /// hand-typed escape hatches are read through this accessor. A double that
  /// only cast to `Bool` would pass while the shipped hatch ignored them.
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
  override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
  override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }

  /// This instance's dictionary, not the superclass's merged domains, which
  /// would report the fallback suite and the global domain but never the keys
  /// the test wrote. Lets a test ask "what is left in the store?" instead of
  /// checking a hand-written key list that misses the key nobody remembered.
  override func dictionaryRepresentation() -> [String: Any] {
    lock.withLock { storage }
  }
}
