import CandelaKit
import CoreGraphics
import Foundation

// The two backends a `SynthesisCoordinator` is built from, over one shared
// world (AT3): tests reach the real engine, the real preview session and the
// real gate, and no CoreGraphics call is made.
//
// Stateful on purpose. `ModeSynthesisEngine` verifies achieved state at three
// points (the virtual display reached 2x, the panel is mirroring the master,
// the panel reports the master's geometry), so a world that only records calls
// cannot get past the first engage and nothing built on it would exercise the
// path under test.

/// The attached displays, and what a mirror does to them.
///
/// Lock-backed rather than actor-isolated: `DisplayConfiguring` is synchronous
/// and `Sendable`, and the engine calls it from its own executor.
final class FakeDisplayWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var order: [CGDirectDisplayID] = []
  private var displaysByID: [CGDirectDisplayID: ConfiguredDisplay] = [:]
  private var modesByID: [CGDirectDisplayID: [DisplayMode]] = [:]
  private var currentByID: [CGDirectDisplayID: DisplayMode] = [:]
  private var nativeByID: [CGDirectDisplayID: (width: Int, height: Int)] = [:]
  private(set) var mirrorChanges: [[MirrorChange]] = []

  func attach(
    _ display: ConfiguredDisplay, modes: [DisplayMode], current: DisplayMode,
    nativePixels: (width: Int, height: Int)? = nil
  ) {
    lock.withLock {
      if displaysByID[display.id] == nil { order.append(display.id) }
      displaysByID[display.id] = display
      modesByID[display.id] = modes
      currentByID[display.id] = current
      nativeByID[display.id] = nativePixels
    }
  }

  func detach(_ displayID: CGDirectDisplayID) {
    lock.withLock {
      order.removeAll { $0 == displayID }
      displaysByID[displayID] = nil
      modesByID[displayID] = nil
      currentByID[displayID] = nil
      nativeByID[displayID] = nil
    }
  }

  func displays() -> [ConfiguredDisplay] {
    lock.withLock { order.compactMap { displaysByID[$0] } }
  }

  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
    lock.withLock { modesByID[displayID] ?? [] }
  }

  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    lock.withLock { currentByID[displayID] }
  }

  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    lock.withLock { nativeByID[displayID] ?? nil }
  }

  /// A slave takes its master's geometry and keeps its own refresh, which is
  /// the measured behaviour the whole feature rests on (Phase 0).
  func applyMirroring(_ changes: [MirrorChange]) {
    lock.withLock {
      mirrorChanges.append(changes)
      for change in changes {
        guard let display = displaysByID[change.display] else { continue }
        displaysByID[change.display] = ConfiguredDisplay(
          id: display.id, identity: display.identity, name: display.name,
          isBuiltIn: display.isBuiltIn, mirrorsDisplay: change.master
        )
        guard change.master != kCGNullDirectDisplay,
              let master = currentByID[change.master], let own = currentByID[change.display]
        else { continue }
        currentByID[change.display] = DisplayMode(
          ioModeID: own.ioModeID,
          logicalWidth: master.logicalWidth, logicalHeight: master.logicalHeight,
          pixelWidth: master.pixelWidth, pixelHeight: master.pixelHeight,
          refreshHz: own.refreshHz, isNative: false
        )
      }
    }
  }
}

/// `DisplayConfiguring` over the world. Mode applies and rotation are not part
/// of any synthesis path; they record nothing and do nothing, so a test that
/// wants them has a reason to extend this rather than a silent success.
final class FakeSynthesisDisplayConfigurator: DisplayConfiguring, @unchecked Sendable {
  let world: FakeDisplayWorld
  /// Refuse the mirror, to reach the engine's `mirrorRefused` arm.
  var refusesMirroring = false

  init(_ world: FakeDisplayWorld) { self.world = world }

  func displays() -> [ConfiguredDisplay] { world.displays() }
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { world.modes(for: displayID) }
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    world.currentMode(for: displayID)
  }

  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    world.nativePixels(for: displayID)
  }

  func apply(_: DisplayMode, to _: CGDirectDisplayID, scope _: DisplayConfigScope) throws {}

  func applyMirroring(_ changes: [MirrorChange], scope _: DisplayConfigScope) throws {
    guard !refusesMirroring else { throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue) }
    world.applyMirroring(changes)
  }

  var revealsHiddenModes: Bool { false }
  var guardsWireTiming: Bool { true }
  func modesWithheldByWireTimingGuard(for _: CGDirectDisplayID) -> Int { 0 }
  var canRotate: Bool { false }
  func rotation(of _: CGDirectDisplayID) -> DisplayRotation? { .standard }
  func applyRotation(_: DisplayRotation, to _: CGDirectDisplayID) throws {}
}

/// `VirtualDisplayAchievedModeReporting` over the world: a created display is
/// attached to it, and the achieved mode is the spec's, so the engine's 2x
/// check passes unless a test says otherwise.
final class FakeSynthesisVirtualDisplayHost: VirtualDisplayAchievedModeReporting, @unchecked Sendable {
  let world: FakeDisplayWorld
  var isAvailable = true
  /// Report a mode the spec did not ask for, to reach `virtualModeNotAchieved`.
  var achieves2x = true
  /// Runs on the engine's executor at the top of `create`, before anything
  /// exists. The one hook a test has into the middle of an engage.
  var onCreate: (@Sendable () -> Void)?

  private let lock = NSLock()
  private var handles: [Int: VirtualDisplayHandle] = [:]
  /// Display IDs are handed out from here so a recreated slot gets a new one,
  /// which is what the real host does and what several guards depend on.
  private var nextDisplayID: CGDirectDisplayID = 90

  init(_ world: FakeDisplayWorld) { self.world = world }

  var ownedDisplayIDs: Set<CGDirectDisplayID> {
    Set(lock.withLock { handles.values.map(\.displayID) })
  }

  func live() -> [VirtualDisplayHandle] {
    lock.withLock { handles.values.sorted { $0.slot < $1.slot } }
  }

  func create(
    _ spec: VirtualDisplaySpec, slot: Int, uuid: UUID, appearanceTimeout _: TimeInterval
  ) -> Result<VirtualDisplayHandle, VirtualDisplayFailure> {
    onCreate?()
    let normalized = spec.normalized
    let displayID: CGDirectDisplayID = lock.withLock {
      nextDisplayID += 1
      return nextDisplayID
    }
    let handle = VirtualDisplayHandle(
      uuid: uuid, slot: slot, displayID: displayID,
      identity: DisplayConfigIdentity(
        vendor: 0xCA11, model: UInt32(slot), serial: 0, isBuiltIn: false
      ),
      spec: normalized
    )
    let mode = DisplayMode(
      ioModeID: Int32(1000 + slot),
      logicalWidth: normalized.logicalWidth, logicalHeight: normalized.logicalHeight,
      pixelWidth: normalized.logicalWidth * 2, pixelHeight: normalized.logicalHeight * 2,
      refreshHz: normalized.refreshHz, isNative: true
    )
    world.attach(
      ConfiguredDisplay(
        id: displayID, identity: handle.identity, name: normalized.name, isBuiltIn: false
      ),
      modes: [mode], current: mode,
      nativePixels: (width: mode.pixelWidth, height: mode.pixelHeight)
    )
    lock.withLock { handles[slot] = handle }
    return .success(handle)
  }

  @discardableResult
  func destroy(slot: Int, departureTimeout _: TimeInterval) -> Bool {
    guard let handle = lock.withLock({ handles.removeValue(forKey: slot) }) else { return false }
    world.detach(handle.displayID)
    return true
  }

  @discardableResult
  func destroyAll(departureTimeout: TimeInterval) -> Bool {
    live().map { destroy(slot: $0.slot, departureTimeout: departureTimeout) }.allSatisfy { $0 }
  }

  func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)? {
    guard let handle = lock.withLock({ handles[slot] }) else { return nil }
    guard achieves2x else {
      return (width: handle.spec.logicalWidth, height: handle.spec.logicalHeight, hiDPI: false)
    }
    return (width: handle.spec.logicalWidth, height: handle.spec.logicalHeight, hiDPI: true)
  }
}
