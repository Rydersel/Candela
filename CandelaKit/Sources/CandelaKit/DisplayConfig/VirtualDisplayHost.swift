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
  // Confinement: every access to `slots`, `reserved` and `stranded` is under
  // `lock`; the C tokens are owned by this instance alone and released
  // exactly once in destroy paths.
  private let lock = NSLock()
  private var slots: [Int: (token: UnsafeMutableRawPointer, handle: VirtualDisplayHandle)] = [:]
  /// Slots with a create in flight. Reserved UNDER THE LOCK before the C call
  /// so two concurrent creates cannot both pass the occupancy check and the
  /// second overwrite the first's token (a leaked display with no destroy
  /// path). Today every app create rides one serial queue; this makes the
  /// invariant structural rather than a convention a future caller can break.
  private var reserved: Set<Int> = []
  /// Slots whose display did not depart at destroy. The token is gone, so the
  /// display cannot be destroyed again, and its identity is still advertised;
  /// a later create for the slot would only collect the duplicate-identity
  /// refusal after a full timeout, so create refuses these up front.
  private var stranded: Set<Int> = []
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
    let refusal: VirtualDisplayFailure? = if slots[slot] != nil || reserved.contains(slot) {
      .capExceeded
    } else if stranded.contains(slot) {
      // The identity is still advertised by a display we lost the handle to;
      // a create would only collect the duplicate refusal after a timeout.
      .identityInUse
    } else {
      nil
    }
    if refusal == nil { reserved.insert(slot) }
    lock.unlock()
    if let refusal { return .failure(refusal) }
    // Every exit below must release the reservation; success replaces it with
    // the slot entry under the same lock acquisition.
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
      release(reservation: slot)
      return .failure(failure)
    }

    // The main display moving under the user is worse than a failed create.
    // Destroy-and-report rather than move-it-back: main-display transaction
    // semantics are unverified, and nothing may risk outliving the process.
    if CGMainDisplayID() != mainBefore {
      let departed = CandelaVDDestroy(token, displayID, appearanceTimeout)
      log.error("vd.create slot=\(slot) refused: main display moved; departed=\(departed ? 1 : 0)")
      lock.lock()
      reserved.remove(slot)
      if !departed { stranded.insert(slot) }
      lock.unlock()
      return .failure(.wouldBecomeMainDisplay)
    }

    // Registered BEFORE the profile check and the engage below: the display
    // has been online since the C call's appearance poll, and its arrival
    // fires a topology refresh whose DDC-pool exclusion reads
    // `ownedDisplayIDs`. The engage can take seconds; a window that long with
    // the owned set stale would leave the exclusion to the foreign predicate
    // alone.
    let handle = VirtualDisplayHandle(
      uuid: uuid, slot: slot, displayID: displayID,
      identity: VirtualDisplayIdentity.configIdentity(slot: slot), spec: normalized
    )
    lock.lock()
    slots[slot] = (token, handle)
    reserved.remove(slot)
    lock.unlock()

    reportProfileGrowth(before: profilesBefore, slot: slot)

    // A new virtual display engages the 1x variant even when the 2x mode is
    // in its ladder (measured 2026-08-13: hiDPI=1, single declared
    // 1920x1080 mode, ceiling 8192x4320, engaged pixels == logical). The
    // Retina promise is only real if the 2x mode is ENGAGED, so engage it
    // and verify; the pane reports achieved state, never this spec's claim.
    //
    // Gated on the ceiling: macOS emits a 2x variant only when the doubled
    // framebuffer fits under maxPixels, so a request it can never satisfy
    // must not burn the two engage attempts before failing.
    if normalized.hiDPI {
      let fitsCeiling = normalized.logicalWidth * 2 <= VirtualDisplayIdentity.maxPixels.wide
        && normalized.logicalHeight * 2 <= VirtualDisplayIdentity.maxPixels.high
      // In-process first (free when it works), then the re-exec helper: the
      // creating process usually cannot enumerate the display's modes, and a
      // fresh process always can (both measured 2026-08-13).
      var engaged = fitsCeiling && Self.engageHiDPIModeInThisProcess(
        displayID: displayID,
        logicalWidth: normalized.logicalWidth, logicalHeight: normalized.logicalHeight
      )
      if fitsCeiling, !engaged {
        engaged = spawnEngageHelper(
          displayID: displayID,
          logicalWidth: normalized.logicalWidth, logicalHeight: normalized.logicalHeight
        )
      }
      if !engaged {
        log.error("vd.create slot=\(slot) id=\(displayID): 2x mode \(fitsCeiling ? "did not engage" : "cannot exist under the pixel ceiling"); display stays 1x")
      }
    }

    log.info("vd.create slot=\(slot) id=\(displayID) \(normalized.logicalWidth)x\(normalized.logicalHeight) hiDPI=\(normalized.hiDPI ? 1 : 0)")
    return .success(handle)
  }

  private func release(reservation slot: Int) {
    lock.lock()
    reserved.remove(slot)
    lock.unlock()
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
    if !departed {
      // The token is released, so the display can never be destroyed again
      // from this process; record the slot so create refuses it honestly
      // instead of timing out into the duplicate-identity refusal.
      lock.lock()
      stranded.insert(slot)
      lock.unlock()
      log.error("vd.destroy slot=\(slot) id=\(entry.handle.displayID) did NOT depart; slot is stranded for this session")
    } else {
      lock.lock()
      stranded.remove(slot)
      lock.unlock()
    }
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

  /// The argv contract every executable embedding this host must honour at
  /// startup, BEFORE any UI or app machinery: when launched as
  /// `<binary> --vd-engage <displayID> <width> <height>`, perform the HiDPI
  /// engage in this fresh process and exit. A process can enumerate display
  /// modes only for the FIRST virtual display it creates (the two-process
  /// rig exists because of it, and both slots' in-process engages failed
  /// measured 2026-08-13), so the engage must run in a process that created
  /// nothing; re-executing our own binary is the smallest such process.
  public static func handleEngageHelperInvocation() {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.count >= 2, arguments[1] == "--vd-engage" else { return }
    // Anything carrying the flag TERMINATES here: falling through would boot
    // a second full app instance, i.e. a second DDC writer.
    guard arguments.count == 5,
          let displayID = UInt32(arguments[2]),
          let width = Int(arguments[3]), let height = Int(arguments[4])
    else { exit(2) }
    let achieved = engageHiDPIModeInThisProcess(
      displayID: displayID, logicalWidth: width, logicalHeight: height
    )
    exit(achieved ? 0 : 1)
  }

  private func spawnEngageHelper(
    displayID: CGDirectDisplayID, logicalWidth: Int, logicalHeight: Int
  ) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    process.arguments = ["--vd-engage", String(displayID), String(logicalWidth), String(logicalHeight)]
    // A semaphore, not a run-loop poll: on a background dispatch queue the
    // default mode is source-less and CFRunLoopRunInMode returns immediately,
    // which turned the old loop into an 8-second 100% CPU spin (measured).
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      log.error("vd.engage helper failed to spawn: \(error.localizedDescription, privacy: .public)")
      return false
    }
    guard finished.wait(timeout: .now() + 8) == .success else {
      process.terminate()
      return false
    }
    return process.terminationStatus == 0
  }

  /// Engage the true-HiDPI variant of the requested logical size and verify
  /// it took. The mode list can lag the display's arrival, so an empty list
  /// is retried briefly and then reported false rather than fought.
  ///
  /// Reading `CGDisplayCopyDisplayMode` here does not violate the
  /// nothing-is-read-back rule (VD5): that rule is about the private
  /// CGVirtualDisplay object's own properties, which lie; the engaged mode is
  /// public CoreGraphics topology state, the same source every mode feature
  /// trusts.
  private static func engageHiDPIModeInThisProcess(
    displayID: CGDirectDisplayID, logicalWidth: Int, logicalHeight: Int
  ) -> Bool {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    var modes: [CGDisplayMode] = []
    // Wall-clock retry: on a source-less background thread the run-loop call
    // returns immediately (measured), so the remainder is slept out or the
    // "3 s of retries" is really one try.
    let deadline = Date(timeIntervalSinceNow: 3)
    while Date() < deadline {
      modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
      if !modes.isEmpty { break }
      if CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, false) == .finished {
        Thread.sleep(forTimeInterval: 0.25)
      }
    }
    guard let target = modes.first(where: {
      $0.width == logicalWidth && $0.height == logicalHeight && $0.pixelWidth >= logicalWidth * 2
    }) else { return false }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return false }
    // Achieved state, not the return code: the platform has returned .success
    // without honouring a configuration before.
    guard let achieved = CGDisplayCopyDisplayMode(displayID) else { return false }
    return achieved.pixelWidth >= achieved.width * 2
  }

  /// The achieved mode of a live slot, for surfaces that must state what IS
  /// rather than what was asked (nil when the display is gone).
  public func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)? {
    lock.lock()
    let displayID = slots[slot]?.handle.displayID
    lock.unlock()
    guard let displayID, let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    return (mode.width, mode.height, mode.pixelWidth >= mode.width * 2)
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
