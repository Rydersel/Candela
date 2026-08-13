import CandelaPrivateAPIs
import CoreGraphics
import Foundation
import os

/// The live implementation of `VirtualDisplayProviding`, and the only Swift
/// file that calls the vdcore C interface.
///
/// A lock-backed class rather than an actor because
/// `DisplayDiscovery.discover()` is a non-async static function that needs
/// `ownedDisplayIDs` synchronously. `create` and `destroy` BLOCK (they poll
/// the online list and pump the calling thread's run loop); callers hop off
/// the main actor first.
public final class VirtualDisplayHost: VirtualDisplayProviding, @unchecked Sendable {
  // Confinement: every access to `slots` is under `lock`; the C tokens are
  // owned by this instance alone and released exactly once in destroy paths.
  private let lock = NSLock()
  private var slots: [Int: (token: UnsafeMutableRawPointer, handle: VirtualDisplayHandle)] = [:]
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "virtualdisplay")

  private static let profilesDirectory = "/Library/ColorSync/Profiles/Displays"

  public init() {}

  public var isAvailable: Bool { CandelaVDAvailable() }

  public var ownedDisplayIDs: Set<CGDirectDisplayID> {
    lock.lock()
    defer { lock.unlock() }
    return Set(slots.values.map(\.handle.displayID))
  }

  public func live() -> [VirtualDisplayHandle] {
    lock.lock()
    defer { lock.unlock() }
    return slots.values.map(\.handle).sorted { $0.slot < $1.slot }
  }

  public func create(
    _ spec: VirtualDisplaySpec, slot: Int, uuid: UUID, appearanceTimeout: TimeInterval
  ) -> Result<VirtualDisplayHandle, VirtualDisplayFailure> {
    guard isAvailable else { return .failure(.classFamilyUnavailable) }
    guard VirtualDisplayIdentity.slotRange.contains(slot) else { return .failure(.capExceeded) }
    lock.lock()
    let occupied = slots[slot] != nil
    lock.unlock()
    guard !occupied else { return .failure(.capExceeded) }

    let normalized = spec.normalized
    let mainBefore = CGMainDisplayID()
    let profilesBefore = profileListing()

    var displayID: UInt32 = 0
    var failureCode: Int32 = 0
    let token = CandelaVDCreate(
      normalized.name,
      VirtualDisplayIdentity.vendorID,
      VirtualDisplayIdentity.productID(slot: slot),
      VirtualDisplayIdentity.serial(slot: slot),
      Double(VirtualDisplayIdentity.sizeInMillimeters.width),
      Double(VirtualDisplayIdentity.sizeInMillimeters.height),
      UInt32(VirtualDisplayIdentity.maxPixels.wide),
      UInt32(VirtualDisplayIdentity.maxPixels.high),
      UInt32(normalized.logicalWidth),
      UInt32(normalized.logicalHeight),
      normalized.hiDPI,
      normalized.refreshHz,
      appearanceTimeout,
      &displayID,
      &failureCode
    )
    guard let token else {
      let failure: VirtualDisplayFailure = switch failureCode {
      case 1: .classFamilyUnavailable
      case 3: .identityInUse
      case 4: .settingsRejected
      case 5: .neverAppearedOnline
      default: .refused
      }
      log.error("vd.create slot=\(slot) failed=\(String(describing: failure))")
      return .failure(failure)
    }

    // The main display moving under the user is worse than a failed create.
    // Destroy-and-report rather than move-it-back: main-display transaction
    // semantics are unverified, and nothing may risk outliving the process.
    if CGMainDisplayID() != mainBefore {
      _ = CandelaVDDestroy(token, displayID, appearanceTimeout)
      log.error("vd.create slot=\(slot) refused: main display moved")
      return .failure(.wouldBecomeMainDisplay)
    }

    reportProfileGrowth(before: profilesBefore, slot: slot)

    let handle = VirtualDisplayHandle(
      uuid: uuid, slot: slot, displayID: displayID,
      identity: VirtualDisplayIdentity.configIdentity(slot: slot), spec: normalized
    )
    lock.lock()
    slots[slot] = (token, handle)
    lock.unlock()
    log.info("vd.create slot=\(slot) id=\(displayID) \(normalized.logicalWidth)x\(normalized.logicalHeight) hiDPI=\(normalized.hiDPI ? 1 : 0)")
    return .success(handle)
  }

  @discardableResult
  public func destroy(slot: Int, departureTimeout: TimeInterval) -> Bool {
    lock.lock()
    guard let entry = slots.removeValue(forKey: slot) else {
      lock.unlock()
      return true
    }
    lock.unlock()
    breakMasteredMirrors(of: entry.handle.displayID)
    let departed = CandelaVDDestroy(entry.token, entry.handle.displayID, departureTimeout)
    log.info("vd.destroy slot=\(slot) id=\(entry.handle.displayID) departed=\(departed ? 1 : 0)")
    return departed
  }

  @discardableResult
  public func destroyAll(departureTimeout: TimeInterval) -> Bool {
    lock.lock()
    let liveSlots = Array(slots.keys)
    lock.unlock()
    var all = true
    for slot in liveSlots {
      all = destroy(slot: slot, departureTimeout: departureTimeout) && all
    }
    return all
  }

  /// A display that MASTERS a mirror set must stop mastering it before
  /// release, so the mirroring displays land back on their own framebuffers
  /// rather than on a departing one. Public CoreGraphics only.
  private func breakMasteredMirrors(of displayID: CGDirectDisplayID) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
    let mirroring = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == displayID }
    guard !mirroring.isEmpty else { return }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
    for id in mirroring {
      CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
    }
    if CGCompleteDisplayConfiguration(config, .permanently) != .success {
      log.error("vd.destroy id=\(displayID): breaking its mirror set failed; releasing anyway")
    }
  }

  private func profileListing() -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: Self.profilesDirectory)) ?? [])
  }

  /// VD11: each slot identity mints ONE permanent profile on its first-ever
  /// creation on a machine, and never again. A log rather than an assertion
  /// because fixing requires root and the app never elevates; a REPEATING
  /// growth for the same slot means an identity is varying, which is the
  /// defect this check exists to surface.
  private func reportProfileGrowth(before: Set<String>, slot: Int) {
    let after = profileListing()
    let grown = after.subtracting(before).sorted()
    guard !grown.isEmpty else { return }
    log.info("vd.create slot=\(slot) colour profiles grew \(before.count) -> \(after.count): \(grown.joined(separator: ", ")); expected once per slot ever, investigate if it repeats")
  }
}
