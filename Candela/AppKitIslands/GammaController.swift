//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from Support/DisplayManager.swift
//  (the gamma activity enforcer) and Model/Display.swift (`swUpdateDefaultGammaTable`,
//  the per-channel scaling in `setSwBrightness`, and the peak-ratio readback in
//  `getSwBrightness`).

import AppKit
import CandelaKit
import os

/// Software dimming by gamma-table scaling: the display's captured default
/// transfer table, multiplied uniformly by a 0…1 scale.
///
/// Two things make this an AppKit island rather than engine code:
/// 1. the "activity enforcer" — a 1×1 window WindowServer has to composite for
///    a gamma write to take effect (see `enforceActivity`);
/// 2. `NSScreen` geometry, needed to park that window on the target display.
@MainActor
final class GammaController: GammaApplying {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  /// The capture size the fork uses; `CGGetDisplayTransferByTable` reports back
  /// how many samples it actually filled, and writes use that count.
  private static let sampleCapacity: UInt32 = 256
  /// The readback is quantized to 1/256 before comparison so float round-trip
  /// noise never reads as drift (fork `getSwBrightness`).
  private static let readbackQuantum: Double = 256
  /// Fork threshold for "someone else rewrote our table" (`checkGammaInterference`).
  private static let intactTolerance: Double = 0.02

  /// A display's untouched transfer table — the baseline every scale multiplies.
  /// Captured before we ever write, so the user's ColorSync profile curve shape
  /// is preserved and repeated scales don't compound.
  private struct DefaultTable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]
    let sampleCount: UInt32
    /// Max across all three channels' maxima; the readback's denominator.
    let peak: CGGammaValue
  }

  private var defaultTables: [CGDirectDisplayID: DefaultTable] = [:]
  private var lastAppliedScale: [CGDirectDisplayID: Double] = [:]

  // MARK: - GammaApplying

  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    guard let table = self.defaultTable(for: displayID) else {
      return false
    }
    // Scales above 1 would push table entries out of the API's 0…1 range (and
    // gamma cannot brighten a panel past its own output anyway).
    let clamped = min(max(scale, 0), 1)
    let factor = CGGammaValue(clamped)
    let red = table.red.map { $0 * factor }
    let green = table.green.map { $0 * factor }
    let blue = table.blue.map { $0 * factor }
    // Fork order, and it matters: park the enforcer on the drawable display,
    // write the table to the PANEL, then force a composite pass.
    //
    // DT17: if the enforcer has no screen the write is not attempted at all and
    // this returns false. Before, the enforcer silently stayed where it was,
    // the write got no composite pass, and `lastAppliedScale` was recorded
    // ANYWAY — so `verifyTableIntact` disagreed with itself, reported
    // interference, and drove the fallback to the shade path, which was also
    // broken on the same display.
    guard self.moveEnforcer(to: drawableDisplayID) else {
      Self.log.error(
        "No screen for display \(drawableDisplayID, privacy: .public); gamma write for \(displayID, privacy: .public) not attempted"
      )
      return false
    }
    // The WRITE keeps the raw panel ID: gamma is per-display and the slave's own
    // panel is what we want dimmed. Whether it reaches a hardware mirror slave
    // is UNVERIFIED — and nothing depends on the answer, because a failure is
    // now reported.
    let result = CGSetDisplayTransferByTable(displayID, table.sampleCount, red, green, blue)
    guard result == .success else {
      Self.log.error("CGSetDisplayTransferByTable failed for display \(displayID, privacy: .public): \(result.rawValue)")
      return false
    }
    self.enforceActivity()
    self.lastAppliedScale[displayID] = clamped
    return true
  }

  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool {
    guard let table = self.defaultTables[displayID], let expected = self.lastAppliedScale[displayID] else {
      // Nothing of ours is installed, so there is nothing to have been clobbered.
      return true
    }
    guard let peak = Self.readPeak(for: displayID) else {
      return false
    }
    let ratio = Double(peak / table.peak)
    let quantized = (ratio * Self.readbackQuantum).rounded() / Self.readbackQuantum
    return abs(quantized - expected) <= Self.intactTolerance
  }

  /// Re-capture the baseline. Caller contract: the OS must own the table at this
  /// moment (i.e. call `resetAllGamma()`, or otherwise be sure no scale of ours
  /// is installed, first) — capturing while dimmed bakes the dimming into the
  /// baseline and the display can never get back to full brightness.
  func recaptureDefaultTable(on displayID: CGDirectDisplayID) {
    self.defaultTables.removeValue(forKey: displayID)
    // The previous scale was measured against the previous baseline; keeping it
    // would make `verifyTableIntact` compare against a stale reference.
    self.lastAppliedScale.removeValue(forKey: displayID)
    _ = self.defaultTable(for: displayID)
  }

  func resetAllGamma() {
    CGDisplayRestoreColorSyncSettings()
    // Baselines stay valid (they were captured from the OS-owned table), but
    // nothing of ours is installed anymore.
    self.lastAppliedScale.removeAll()
    Self.log.info("Gamma tables handed back to the OS")
  }

  // MARK: - Default tables

  private func defaultTable(for displayID: CGDirectDisplayID) -> DefaultTable? {
    if let existing = self.defaultTables[displayID] {
      return existing
    }
    guard let captured = Self.captureDefaultTable(for: displayID) else {
      return nil
    }
    self.defaultTables[displayID] = captured
    return captured
  }

  private static func captureDefaultTable(for displayID: CGDirectDisplayID) -> DefaultTable? {
    var red = [CGGammaValue](repeating: 0, count: Int(self.sampleCapacity))
    var green = red
    var blue = red
    var sampleCount: UInt32 = 0
    let result = CGGetDisplayTransferByTable(displayID, self.sampleCapacity, &red, &green, &blue, &sampleCount)
    guard result == .success, sampleCount > 0 else {
      self.log.error("CGGetDisplayTransferByTable failed for display \(displayID, privacy: .public): \(result.rawValue)")
      return nil
    }
    let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
    // DIVERGENCE (fork bug): the fork stores a zero peak without complaint, then
    // divides by it on readback (NaN/inf) and scales an all-zero table into a
    // black screen. A zero-peak capture is a failed capture.
    guard peak > 0 else {
      self.log.error("Captured an all-zero gamma table for display \(displayID, privacy: .public); treating as a failed capture")
      return nil
    }
    return DefaultTable(red: red, green: green, blue: blue, sampleCount: sampleCount, peak: peak)
  }

  private static func readPeak(for displayID: CGDirectDisplayID) -> CGGammaValue? {
    var red = [CGGammaValue](repeating: 0, count: Int(self.sampleCapacity))
    var green = red
    var blue = red
    var sampleCount: UInt32 = 0
    guard CGGetDisplayTransferByTable(displayID, self.sampleCapacity, &red, &green, &blue, &sampleCount) == .success, sampleCount > 0 else {
      return nil
    }
    return max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
  }

  // MARK: - Activity enforcer

  /// WindowServer drops (or never applies) a `CGSetDisplayTransferByTable` write
  /// on a display with no drawing activity. The countermeasure is this window:
  /// 1×1, black, effectively invisible at 1% alpha, click-through, parked on the
  /// display we are about to write to. Its *alpha change* right after the write
  /// is what forces a composite pass — the value itself is irrelevant.
  private lazy var enforcer: NSWindow = {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [], backing: .buffered, defer: false)
    window.title = "Candela Gamma Activity Enforcer"
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = false
    window.backgroundColor = .black
    window.alphaValue = Self.enforcerBaseAlpha
    window.ignoresMouseEvents = true
    // Deliberately lower than the shade's `CGShieldingWindowLevel()`: this one
    // only has to be composited, not to cover anything.
    window.level = .screenSaver
    window.orderFrontRegardless()
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    Self.log.info("Gamma activity enforcer created")
    return window
  }()

  private static let enforcerBaseAlpha: CGFloat = 0.01
  private static let enforcerToggledAlpha: CGFloat = 0.02
  private var enforcerToggled = false

  /// One enforcer window shared by all displays: it can only enforce on one
  /// display at a time, which is fine because every gamma write moves it first.
  ///
  /// The ID is ALREADY RESOLVED to a drawable display by the engine (DT15) —
  /// the fork resolved mirroring here instead, at each of nine such sites.
  ///
  /// Returns whether it actually has a screen. The old version ordered it front
  /// regardless "because a stale position still composites somewhere" — which
  /// is true and is exactly the problem: it composites on the WRONG display,
  /// and the write it was supposed to enable is never applied.
  private func moveEnforcer(to displayID: CGDirectDisplayID) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return false
    }
    self.enforcer.setFrameOrigin(screen.frame.origin)
    self.enforcer.orderFrontRegardless()
    return true
  }

  private func enforceActivity() {
    // DIVERGENCE (robustness): the fork decides which way to flip by comparing
    // `alphaValue` to a float literal. Tracking the flip in a Bool is the same
    // toggle without the exact float compare.
    self.enforcerToggled.toggle()
    self.enforcer.alphaValue = self.enforcerToggled ? Self.enforcerToggledAlpha : Self.enforcerBaseAlpha
  }
}
