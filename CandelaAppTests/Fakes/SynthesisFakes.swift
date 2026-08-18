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
  /// The mode a display shows when it is NOT a slave, kept so a null-master
  /// change can put it back. Without it a broken mirror leaves the panel
  /// reporting the master's geometry forever, and the engine's unwind check
  /// answers `unwindIncomplete` against a fake that did unwind.
  private var ownModeByID: [CGDirectDisplayID: DisplayMode] = [:]
  private var nativeByID: [CGDirectDisplayID: (width: Int, height: Int)] = [:]
  private(set) var mirrorChanges: [[MirrorChange]] = []
  private var _applies: [(mode: DisplayMode, displayID: CGDirectDisplayID)] = []

  /// Every mode apply the configurator was asked for, in order. The engage
  /// tail's re-time is one of these, and it is the only evidence of it a fake
  /// world can honestly carry.
  var applies: [(mode: DisplayMode, displayID: CGDirectDisplayID)] {
    lock.withLock { _applies }
  }

  func recordApply(_ mode: DisplayMode, to displayID: CGDirectDisplayID) {
    lock.withLock { _applies.append((mode, displayID)) }
  }

  func attach(
    _ display: ConfiguredDisplay, modes: [DisplayMode], current: DisplayMode,
    nativePixels: (width: Int, height: Int)? = nil
  ) {
    lock.withLock {
      if displaysByID[display.id] == nil { order.append(display.id) }
      displaysByID[display.id] = display
      modesByID[display.id] = modes
      currentByID[display.id] = current
      ownModeByID[display.id] = current
      nativeByID[display.id] = nativePixels
    }
  }

  func detach(_ displayID: CGDirectDisplayID) {
    lock.withLock {
      order.removeAll { $0 == displayID }
      displaysByID[displayID] = nil
      modesByID[displayID] = nil
      currentByID[displayID] = nil
      ownModeByID[displayID] = nil
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
  /// what a mirror does at the instant it lands (Phase 0). It models the world
  /// BEFORE the engage tail, deliberately: on hardware the tail re-times the
  /// slave onto its own mode about two seconds later, and `apply` here records
  /// the call without moving the world, so a test that wants the retimed world
  /// asserts on the recorded apply rather than on the readback. A null master
  /// puts the display back on its OWN mode, matching the Kit's
  /// `FakeSynthesisWorld`: without that half, the engine's unwind never sees
  /// the panel return to its own geometry and every disengage answers
  /// `unwindIncomplete` against a fake that did exactly what it was asked.
  ///
  /// `isInMirrorSet` moves with the master, because CoreGraphics reports it for
  /// a slave and every predicate written over "is this display mirrored" reads
  /// that flag rather than `mirrorsDisplay`. A fake that left it false made a
  /// mirrored panel indistinguishable from a standalone one to exactly the
  /// carve-outs this world exists to exercise.
  func applyMirroring(_ changes: [MirrorChange]) {
    lock.withLock {
      mirrorChanges.append(changes)
      for change in changes {
        guard let display = displaysByID[change.display] else { continue }
        displaysByID[change.display] = ConfiguredDisplay(
          id: display.id, identity: display.identity, name: display.name,
          isBuiltIn: display.isBuiltIn, mirrorsDisplay: change.master,
          isInMirrorSet: change.master != kCGNullDirectDisplay
        )
        guard change.master != kCGNullDirectDisplay else {
          currentByID[change.display] = ownModeByID[change.display]
          continue
        }
        guard let master = currentByID[change.master], let own = ownModeByID[change.display]
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
///
/// `@unchecked Sendable` justification: every field this type carries is either
/// the `let world` (which does its own locking) or a plain test KNOB
/// (`refusesMirroring`). The knobs are written on the test's main actor BEFORE
/// the coordinator is asked to do anything, and the call that reads them is
/// spawned by that same actor afterwards, so task creation supplies the
/// happens-before and no read can race the write that configured it. A test that
/// wants to flip a knob MID-operation would break that argument and needs a
/// lock, not a comment.
final class FakeSynthesisDisplayConfigurator: DisplayConfiguring, @unchecked Sendable {
  let world: FakeDisplayWorld
  /// Refuse the mirror, to reach the engine's `mirrorRefused` arm.
  var refusesMirroring = false
  /// Throw from `apply`, to reach the engage tail's bounce fallback.
  var refusesModeApplies = false

  init(_ world: FakeDisplayWorld) { self.world = world }

  /// Every mode apply, in order. Forwarded from the world so a test asserting
  /// on the engage tail reads it off the object it configured.
  var applies: [(mode: DisplayMode, displayID: CGDirectDisplayID)] { world.applies }

  func displays() -> [ConfiguredDisplay] { world.displays() }
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { world.modes(for: displayID) }
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    world.currentMode(for: displayID)
  }

  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    world.nativePixels(for: displayID)
  }

  /// Recorded, and the world is deliberately NOT moved. The engage tail's
  /// re-time is a mode apply on a mirror SLAVE: on hardware the picture keeps
  /// coming from the master while the wire changes timing, which no fake
  /// readback models, so the assertion a test can honestly make is about the
  /// call rather than about a readback. The tail's own achieved-state check
  /// then answers false here, which is what puts the bounce under test.
  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope _: DisplayConfigScope) throws {
    if refusesModeApplies { throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue) }
    world.recordApply(mode, to: displayID)
  }

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
///
/// `@unchecked Sendable` justification, same shape as the configurator's: the
/// mutable state that is READ AND WRITTEN across executors (`handles`,
/// `nextDisplayID`) is under `lock`, and the rest (`isAvailable`, `achieves2x`,
/// `onCreate`) are test knobs set on the main actor before the operation that
/// reads them is spawned, so task creation is the happens-before. `onCreate` is
/// invoked on the ENGINE's executor, which is the point of it: it is the one
/// hook a test has into the middle of an engage, and anything it touches must
/// be safe there on its own terms.
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

/// A scriptable stand-in for the display's own HDR seam, so the engage tail's
/// bounce can be driven without a `BrightnessController`.
///
/// Lock-backed: the driver runs on the generic executor while the test body
/// reads the log from its own task.
final class FakeSynthesisHDR: @unchecked Sendable {
  private let lock = NSLock()
  private var _supports: Bool
  private var _live: Bool?
  /// Every leg the bounce asked for, in order, as (requested, granted).
  private var _legs: [(enabled: Bool, granted: Bool)] = []
  private var _leftStanding: [CGDirectDisplayID] = []
  /// Which legs the display ACHIEVES. An off leg that never achieves is the
  /// stranding path the bounce gives up loudly on.
  private var _achievesOn: Bool
  private var _achievesOff: Bool

  init(supports: Bool = true, live: Bool? = false, achievesOn: Bool = true, achievesOff: Bool = true) {
    _supports = supports
    _live = live
    _achievesOn = achievesOn
    _achievesOff = achievesOff
  }

  var legs: [(enabled: Bool, granted: Bool)] { lock.withLock { _legs } }
  var leftStanding: [CGDirectDisplayID] { lock.withLock { _leftStanding } }

  /// The seam a `SynthesisCoordinator` takes, over this fake.
  var seam: SynthesisHDRBounce {
    SynthesisHDRBounce(
      supportsHDR: { [self] _ in lock.withLock { _supports } },
      measuredHDREnabled: { [self] _ in lock.withLock { _live } },
      setHDR: { [self] _, enabled in
        lock.withLock {
          let granted = enabled ? _achievesOn : _achievesOff
          if granted { _live = enabled }
          _legs.append((enabled, granted))
          return granted
        }
      },
      reportHDRLeftStanding: { [self] displayID in
        lock.withLock { _leftStanding.append(displayID) }
      }
    )
  }
}
