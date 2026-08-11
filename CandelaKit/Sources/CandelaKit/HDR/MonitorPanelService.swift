//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT).
//  Based on MonitorControl's HDRControl (MIT).

import CandelaPrivateAPIs
import CoreGraphics
import Foundation
import os

/// Programmatic control of the System Settings HDR toggle. Fronted as a
/// protocol so controllers can be tested against a fake.
public protocol HDRToggling: Sendable {
  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool
  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool
  /// The panel's HDR state read NOW, past any cache.
  ///
  /// Deliberately not a default implementation forwarding to `isHDREnabled`
  /// (#65). A conformance that silently answered from a cache would turn every
  /// achieved-state check built on this into a check that cannot fail, which is
  /// the defect this method exists to remove: each conformance has to say what
  /// its own read-through is.
  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool
  /// Reports whether the write was ISSUED, never whether the display switched
  /// (#65). See the implementation's note.
  @discardableResult
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool
  func displaysReconfigured() async
}

/// Programmatic control of the System Settings HDR toggle via the private
/// MonitorPanel framework (fork: Support/HDRControl.swift; same mechanism
/// BetterDisplay/ToggleHDR use). Actor isolation replaces the fork's serial
/// DispatchQueue; MPDisplay/MPDisplayMgr existentials are non-Sendable and
/// must never escape this actor (the compiler enforces this).
public actor MonitorPanelService: HDRToggling {
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "MonitorPanel")

  public init() {}

  /// The only retained MonitorPanel object. MPDisplay instances are NEVER
  /// stored — see mpDisplay(_:). nil when the framework failed to load;
  /// every entry point then degrades (spec §6).
  private lazy var manager: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
          let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type
    else {
      self.log.error("MonitorPanel.framework unavailable; HDR control disabled")
      return nil
    }
    return managerClass.init()
  }()

  /// 2 s isHDREnabled cache (fork: HDRControl.swift:41-53) — checked on every
  /// brightness keypress; MPDisplayMgr enumeration is not free.
  private var hdrStateCache: [CGDirectDisplayID: (value: Bool, timestamp: ContinuousClock.Instant)] = [:]

  /// Fork rule (HDRControl.swift:20): MPDisplay objects must not be cached
  /// across display reconfigurations — always re-fetch per call.
  private func mpDisplay(_ displayID: CGDirectDisplayID) -> MPDisplay? {
    guard let manager else { return nil }
    let mgr = unsafeBitCast(manager, to: MPDisplayMgr.self)
    for display in mgr.displays() {
      let mpDisplay = unsafeBitCast(display as AnyObject, to: MPDisplay.self)
      if mpDisplay.displayID == displayID { return mpDisplay }
    }
    return nil
  }

  public func supportsHDR(displayID: CGDirectDisplayID) -> Bool {
    self.mpDisplay(displayID)?.hasHDRModes ?? false
  }

  public func isHDREnabled(displayID: CGDirectDisplayID) -> Bool {
    if let cached = hdrStateCache[displayID], cached.timestamp.duration(to: .now) < .seconds(2) {
      return cached.value
    }
    return self.measuredHDREnabled(displayID: displayID)
  }

  public func measuredHDREnabled(displayID: CGDirectDisplayID) -> Bool {
    let value = self.mpDisplay(displayID)?.preferHDRModes ?? false
    self.hdrStateCache[displayID] = (value, .now)
    return value
  }

  /// The display blanks and re-modes for ~2 s after this returns; the caller
  /// owns the settle delay and any deferred brightness write (spec §6,
  /// fork: HDRControl.swift:56,107,125).
  ///
  /// **`true` means the write was ISSUED: the lock was taken and
  /// `preferHDRModes` was assigned. It does NOT mean the display switched**
  /// (#65). A caller deciding whether an engage happened has to read
  /// `measuredHDREnabled` after the settle; CLAUDE.md §2's rule about treating
  /// an ACK as evidence of nothing applies here as much as it does on the wire.
  @discardableResult
  public func setHDR(displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
    guard let manager, let display = mpDisplay(displayID) else { return false }
    let mgr = unsafeBitCast(manager, to: MPDisplayMgr.self)
    guard mgr.tryLockAccess() else {
      self.log.debug("MonitorPanel access lock busy; HDR toggle skipped for \(displayID)")
      return false
    }
    display.preferHDRModes = enabled
    mgr.unlockAccess()
    // INVALIDATED, not seeded with the requested value (#65). Seeding made the
    // cache assert the very thing the post-settle read is there to test, and
    // the seed's 2 s TTL equalled `BrightnessController.settleDelay`, so the
    // confirmation read landed on the boundary of the window that would have
    // returned the request back to itself.
    self.hdrStateCache[displayID] = nil
    return true
  }

  /// Call from DisplayManager on every reconfiguration epoch bump: HDR state
  /// may have changed out from under the 2 s cache (mode switches themselves
  /// trigger reconfiguration).
  public func displaysReconfigured() {
    self.hdrStateCache.removeAll()
  }
}
