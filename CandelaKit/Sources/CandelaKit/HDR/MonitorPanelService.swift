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
  /// No default forwarding to `isHDREnabled`: a conformance answering from a
  /// cache turns every achieved-state check built on this into one that cannot
  /// fail. Each conformance states its own read-through.
  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool
  /// Reports whether the write was ISSUED, never whether the display switched.
  /// See the implementation's note.
  @discardableResult
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool
  func displaysReconfigured() async
}

/// Programmatic control of the System Settings HDR toggle through the private
/// MonitorPanel framework, which is what the Displays pane itself drives.
/// Actor isolation replaces the fork's serial DispatchQueue; MPDisplay and
/// MPDisplayMgr existentials are non-Sendable and must never escape this actor,
/// which the compiler enforces.
public actor MonitorPanelService: HDRToggling {
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "MonitorPanel")

  public init() {}

  /// The only retained MonitorPanel object; MPDisplay instances are never
  /// stored (see `mpDisplay`). nil when the framework failed to load, and every
  /// entry point then degrades.
  private lazy var manager: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
          let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type
    else {
      self.log.error("MonitorPanel.framework unavailable; HDR control disabled")
      return nil
    }
    return managerClass.init()
  }()

  /// 2 s cache: `isHDREnabled` runs on every brightness keypress and
  /// MPDisplayMgr enumeration is not free.
  private var hdrStateCache: [CGDirectDisplayID: (value: Bool, timestamp: ContinuousClock.Instant)] = [:]

  /// MPDisplay objects must not be cached across display reconfigurations, so
  /// re-fetch on every call.
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
  /// owns the settle delay and any deferred brightness write.
  ///
  /// **`true` means the write was ISSUED, not that the display switched.** To
  /// know whether an engage happened, read `measuredHDREnabled` after the settle.
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
    // Invalidated, not seeded with the requested value: a seed makes the cache
    // assert the very thing the post-settle read exists to test, and its 2 s TTL
    // equals `BrightnessController.settleDelay`.
    self.hdrStateCache[displayID] = nil
    return true
  }

  /// Call on every reconfiguration epoch bump: HDR state may have changed out
  /// from under the 2 s cache, and mode switches trigger reconfiguration.
  public func displaysReconfigured() {
    self.hdrStateCache.removeAll()
  }
}
