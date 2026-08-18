//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from Support/DisplayManager.swift
//  (the gamma activity enforcer) and Model/Display.swift (`swUpdateDefaultGammaTable`,
//  the per-channel scaling in `setSwBrightness`, and the peak-ratio readback in
//  `getSwBrightness`).

import AppKit
import CandelaKit
import os

/// One display's three transfer-table channels, however they were obtained.
struct GammaSamples: Equatable {
  var red: [CGGammaValue]
  var green: [CGGammaValue]
  var blue: [CGGammaValue]

  var sampleCount: UInt32 { UInt32(red.count) }
  /// Max across all three channels' maxima; the readback's denominator.
  var peak: CGGammaValue { max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0) }

  func scaled(by factor: CGGammaValue) -> GammaSamples {
    GammaSamples(
      red: red.map { $0 * factor },
      green: green.map { $0 * factor },
      blue: blue.map { $0 * factor }
    )
  }

  /// The straight 0…1 ramp: the table a display would have with no colour
  /// profile applied at all.
  static func linear(count: Int) -> GammaSamples {
    let divisor = CGGammaValue(max(count - 1, 1))
    let ramp = (0 ..< count).map { CGGammaValue($0) / divisor }
    return GammaSamples(red: ramp, green: ramp, blue: ramp)
  }
}

/// What a table read produced. It carries the CoreGraphics code on failure so
/// the one-per-display error line keeps the number the hardware pass reads out
/// of it.
enum GammaReadOutcome {
  case table(GammaSamples)
  case failed(CGError)
}

/// The CoreGraphics transfer-table pair, the ColorSync hand-back and the
/// activity enforcer, behind one seam.
///
/// It exists for a single testability reason, and it is not a hypothetical one:
/// SS15's companion leg is defined by what happens when a display REFUSES to
/// report its own table, and no display in the rig can be told to refuse on
/// demand. The production implementation is the only one shipped; a test drives
/// a stub.
@MainActor
protocol GammaTableDriving: AnyObject {
  func readTable(_ displayID: CGDirectDisplayID, capacity: UInt32) -> GammaReadOutcome
  func writeTable(_ displayID: CGDirectDisplayID, _ samples: GammaSamples) -> CGError
  func restoreColorSyncSettings()
  /// Park the 1×1 activity window on `displayID`. False when it has no screen.
  func moveEnforcer(to displayID: CGDirectDisplayID) -> Bool
  func enforceActivity()
}

/// Software dimming by gamma-table scaling: the display's captured default
/// transfer table, multiplied uniformly by a 0…1 scale.
///
/// Two things make this an AppKit island rather than engine code:
/// 1. the "activity enforcer" — a 1×1 window WindowServer has to composite for
///    a gamma write to take effect (see `CoreGraphicsGammaDriver`);
/// 2. `NSScreen` geometry, needed to park that window on the target display.
@MainActor
final class GammaController: GammaApplying {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  /// The capture size the fork uses; the driver reports back how many samples it
  /// actually filled, and writes use that count.
  private static let sampleCapacity: UInt32 = 256
  /// The readback is quantized to 1/256 before comparison so float round-trip
  /// noise never reads as drift (fork `getSwBrightness`).
  private static let readbackQuantum: Double = 256
  /// Fork threshold for "someone else rewrote our table" (`checkGammaInterference`).
  private static let intactTolerance: Double = 0.02

  private let driver: any GammaTableDriving

  init(driver: any GammaTableDriving = CoreGraphicsGammaDriver()) {
    self.driver = driver
  }

  /// A display's untouched transfer table — the baseline every scale multiplies.
  /// Captured before we ever write, so the user's ColorSync profile curve shape
  /// is preserved and repeated scales don't compound.
  private var defaultTables: [CGDirectDisplayID: GammaSamples] = [:]
  private var lastAppliedScale: [CGDirectDisplayID: Double] = [:]

  /// Displays whose baseline capture already failed and was already logged.
  ///
  /// The capture is still RETRIED every time, so a display that starts
  /// answering gets its baseline; only the line is written once, because the
  /// failure is now reachable at drag rate. SS15 writes the table to both ends
  /// of a synthesis set, and the second end is a virtual display this process
  /// created and measurably cannot read back; without this, one drag on a
  /// synthesized size fills the log with the same error at 60 lines a second.
  /// The line itself is deliberately kept: the hardware pass greps for it.
  private var loggedCaptureFailures: Set<CGDirectDisplayID> = []

  // MARK: - GammaApplying

  @discardableResult
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID, enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    guard let baseline = self.defaultTable(for: displayID) else {
      return false
    }
    return self.write(scale, baseline: baseline, on: displayID, enforcerOn: drawableDisplayID)
  }

  @discardableResult
  func applyGammaScale(
    assumingLinearBaseline scale: Double, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    // The whole difference from the leg above: a display that will not report a
    // table is written anyway, against the straight ramp. That a virtual
    // display's untouched table IS the straight ramp is an ASSUMPTION and is
    // unverified; the hardware pass's eyes item decides the final routing.
    let baseline = self.defaultTable(for: displayID)
      ?? GammaSamples.linear(count: Int(Self.sampleCapacity))
    return self.write(scale, baseline: baseline, on: displayID, enforcerOn: drawableDisplayID)
  }

  private func write(
    _ scale: Double, baseline: GammaSamples, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool {
    // Scales above 1 would push table entries out of the API's 0…1 range (and
    // gamma cannot brighten a panel past its own output anyway).
    let clamped = min(max(scale, 0), 1)
    let scaled = baseline.scaled(by: CGGammaValue(clamped))
    // Fork order, and it matters: park the enforcer on the drawable display,
    // write the table to the target, then force a composite pass.
    //
    // DT17: if the enforcer has no screen the write is not attempted at all and
    // this returns false. Before, the enforcer silently stayed where it was,
    // the write got no composite pass, and `lastAppliedScale` was recorded
    // ANYWAY — so `verifyTableIntact` disagreed with itself, reported
    // interference, and drove the fallback to the shade path, which was also
    // broken on the same display.
    guard self.driver.moveEnforcer(to: drawableDisplayID) else {
      Self.log.error(
        "No screen for display \(drawableDisplayID, privacy: .public); gamma write for \(displayID, privacy: .public) not attempted"
      )
      return false
    }
    // The WRITE keeps whatever ID it was handed: gamma is a per-display property
    // and this holds no opinion about which display should be dimmed.
    //
    // For a mirror SLAVE, whether the write reaches the glass is not decidable
    // from here, or from anywhere else in software. Phase 0 measured a slave's
    // table storing and reading back changed, with an unmirrored positive
    // control, while its scanout comes from the master's framebuffer: both
    // outcomes are consistent with everything observable. That is why the engine
    // writes both ends of a synthesis set (SS15) and why nothing on this path
    // claims a write landed on the panel. A `.success` here means CoreGraphics
    // accepted the table, no more.
    let result = self.driver.writeTable(displayID, scaled)
    guard result == .success else {
      Self.log.error("CGSetDisplayTransferByTable failed for display \(displayID, privacy: .public): \(result.rawValue)")
      return false
    }
    self.driver.enforceActivity()
    self.lastAppliedScale[displayID] = clamped
    return true
  }

  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool {
    guard let table = self.defaultTables[displayID], let expected = self.lastAppliedScale[displayID] else {
      // Nothing of ours is installed, so there is nothing to have been clobbered.
      // A display written only through the assumed-baseline leg lands here too:
      // there is no captured reference to compare a readback against, which is
      // the same fact that made the assumption necessary.
      return true
    }
    guard case let .table(readback) = self.driver.readTable(displayID, capacity: Self.sampleCapacity)
    else {
      return false
    }
    let ratio = Double(readback.peak / table.peak)
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
    // A reconfiguration is a new machine state, so a display that refused to
    // answer before gets its one log line again if it still refuses.
    self.loggedCaptureFailures.remove(displayID)
    _ = self.defaultTable(for: displayID)
  }

  func resetAllGamma() {
    self.driver.restoreColorSyncSettings()
    // Baselines stay valid (they were captured from the OS-owned table), but
    // nothing of ours is installed anymore.
    self.lastAppliedScale.removeAll()
    Self.log.info("Gamma tables handed back to the OS")
  }

  // MARK: - Default tables

  private func defaultTable(for displayID: CGDirectDisplayID) -> GammaSamples? {
    if let existing = self.defaultTables[displayID] {
      return existing
    }
    guard let captured = self.captureDefaultTable(for: displayID) else {
      self.loggedCaptureFailures.insert(displayID)
      return nil
    }
    self.loggedCaptureFailures.remove(displayID)
    self.defaultTables[displayID] = captured
    return captured
  }

  private func captureDefaultTable(for displayID: CGDirectDisplayID) -> GammaSamples? {
    let quiet = self.loggedCaptureFailures.contains(displayID)
    let captured: GammaSamples
    switch self.driver.readTable(displayID, capacity: Self.sampleCapacity) {
    case let .table(samples):
      captured = samples
    case let .failed(error):
      if !quiet {
        Self.log.error("CGGetDisplayTransferByTable failed for display \(displayID, privacy: .public): \(error.rawValue)")
      }
      return nil
    }
    // DIVERGENCE (fork bug): the fork stores a zero peak without complaint, then
    // divides by it on readback (NaN/inf) and scales an all-zero table into a
    // black screen. A zero-peak capture is a failed capture.
    guard captured.peak > 0 else {
      if !quiet {
        Self.log.error("Captured an all-zero gamma table for display \(displayID, privacy: .public); treating as a failed capture")
      }
      return nil
    }
    return captured
  }
}

/// The shipped driver: the two CoreGraphics transfer-table calls, the ColorSync
/// hand-back, and the activity-enforcer window.
@MainActor
final class CoreGraphicsGammaDriver: GammaTableDriving {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  func readTable(_ displayID: CGDirectDisplayID, capacity: UInt32) -> GammaReadOutcome {
    var red = [CGGammaValue](repeating: 0, count: Int(capacity))
    var green = red
    var blue = red
    var sampleCount: UInt32 = 0
    let result = CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount)
    guard result == .success else { return .failed(result) }
    // A success that filled nothing is a failure with no code of its own; the
    // caller's guard against a zero-sample table used to live here.
    guard sampleCount > 0 else { return .failed(.failure) }
    let filled = Int(sampleCount)
    return .table(GammaSamples(
      red: Array(red.prefix(filled)),
      green: Array(green.prefix(filled)),
      blue: Array(blue.prefix(filled))
    ))
  }

  func writeTable(_ displayID: CGDirectDisplayID, _ samples: GammaSamples) -> CGError {
    CGSetDisplayTransferByTable(
      displayID, samples.sampleCount, samples.red, samples.green, samples.blue
    )
  }

  func restoreColorSyncSettings() {
    CGDisplayRestoreColorSyncSettings()
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
  func moveEnforcer(to displayID: CGDirectDisplayID) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return false
    }
    self.enforcer.setFrameOrigin(screen.frame.origin)
    self.enforcer.orderFrontRegardless()
    return true
  }

  func enforceActivity() {
    // DIVERGENCE (robustness): the fork decides which way to flip by comparing
    // `alphaValue` to a float literal. Tracking the flip in a Bool is the same
    // toggle without the exact float compare.
    self.enforcerToggled.toggle()
    self.enforcer.alphaValue = self.enforcerToggled ? Self.enforcerToggledAlpha : Self.enforcerBaseAlpha
  }
}
