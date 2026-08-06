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
    let value = self.mpDisplay(displayID)?.preferHDRModes ?? false
    self.hdrStateCache[displayID] = (value, .now)
    return value
  }

  /// The display blanks and re-modes for ~2 s after this returns; the caller
  /// owns the settle delay and any deferred brightness write (spec §6,
  /// fork: HDRControl.swift:56,107,125).
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
    self.hdrStateCache[displayID] = (enabled, .now)
    return true
  }

  /// Call from DisplayManager on every reconfiguration epoch bump: HDR state
  /// may have changed out from under the 2 s cache (mode switches themselves
  /// trigger reconfiguration).
  public func displaysReconfigured() {
    self.hdrStateCache.removeAll()
  }
}
