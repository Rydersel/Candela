import Foundation

/// A full-range quit write is not a sample of the running combined scale.
/// The saved value and mapping bind this exception to the exact state that quit.
struct QuitBrightnessHandback: Codable, Equatable, Sendable {
  struct Mapping: Codable, Equatable, Sendable {
    let combinedDisabled: Bool
    let switchingPoint: Int
    let forceSoftware: Bool
    let unavailable: Bool
    let minimum: Int
    let maximumOverride: Int
    let curve: Int
    let inverted: Bool
    let registers: [UInt8]

    init(_ prefs: DisplayPrefs) {
      let tuning = prefs.tuning(for: .brightness)
      combinedDisabled = prefs.disableCombinedBrightness
      switchingPoint = prefs.combinedSwitchingPoint
      forceSoftware = prefs.forceSoftware
      unavailable = tuning.unavailableDDC
      minimum = tuning.minDDCOverride
      maximumOverride = tuning.maxDDCOverride
      curve = tuning.curveIndex
      inverted = tuning.invert
      registers = tuning.remapCodes
    }
  }

  let id: UUID
  let savedLogical: Double
  let quitLogical: Double
  let mapping: Mapping
  /// Nil only for bounded migration from a version that recorded no quit write.
  let raw: UInt16?
  let effectiveMaximum: Int?

  var isLegacy: Bool { raw == nil }
}

/// The quit barrier blocks MainActor. Observe the readable register's outcome
/// on the writer's executor; another remapped register may fail independently.
struct RecordingQuitBrightnessWriter: DDCWriting {
  let base: any DDCWriting
  let readRegister: UInt8
  let recordSuccess: @Sendable () -> Void

  func write(command: UInt8, value: UInt16) async -> Bool {
    let succeeded = await base.write(command: command, value: value)
    if succeeded, command == readRegister { recordSuccess() }
    return succeeded
  }
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    await base.read(command: command)
  }
}

/// Controllers sharing one record must all resolve it before it can be erased.
/// Immutable identity and prefs; the shared lock protects lease lifetime across
/// actor-independent deinit. No controller is retained by the registry.
final class QuitHandbackLease: @unchecked Sendable {
  private struct Group {
    var holders: Set<UUID> = []
    var abandoned = false
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var groups: [UUID: Group] = [:]
  private let recordID: UUID
  private let holder = UUID()
  private let prefs: DisplayPrefs

  init(record: QuitBrightnessHandback, prefs: DisplayPrefs) {
    self.recordID = record.id
    self.prefs = prefs
    _ = Self.lock.withLock { Self.groups[recordID, default: Group()].holders.insert(holder) }
  }

  func resolve() { release(resolved: true) }

  private func release(resolved: Bool) {
    Self.lock.withLock {
      guard var group = Self.groups[recordID], group.holders.remove(holder) != nil else { return }
      if !resolved { group.abandoned = true }
      if group.holders.isEmpty {
        Self.groups.removeValue(forKey: recordID)
        if resolved, !group.abandoned { prefs.consumeQuitBrightnessHandback(recordID) }
      } else {
        Self.groups[recordID] = group
      }
    }
  }

  static func consumeIfUnheld(_ record: QuitBrightnessHandback, prefs: DisplayPrefs) {
    lock.withLock {
      if groups[record.id] == nil { prefs.consumeQuitBrightnessHandback(record.id) }
    }
  }

  deinit { release(resolved: false) }
}
