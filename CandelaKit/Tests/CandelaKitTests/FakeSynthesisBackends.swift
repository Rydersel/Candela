import CoreGraphics
import Foundation
@testable import CandelaKit

/// One call the synthesis engine made against either backend, in the order it
/// made it.
///
/// ONE log across both fakes, deliberately. The unwind ordering rule (SS10) is
/// about the relationship between a mirror change and a virtual-display
/// destroy, and two per-fake logs can only prove that each happened.
enum SynthesisCall: Equatable {
  case createVirtualDisplay(slot: Int, name: String, logicalWidth: Int, logicalHeight: Int, hiDPI: Bool)
  case destroyVirtualDisplay(slot: Int)
  case applyMirroring([MirrorChange], scope: DisplayConfigScope)
  /// Something the engine has no business doing. Recorded rather than trapped
  /// so a test can assert its absence and name what happened when it fires.
  case unexpected(String)
}

/// The machine both synthesis fakes describe: the panels, who is mirroring
/// whom, which slots are live, and the call log.
///
/// A shared world rather than two independent fakes because the engine's
/// achieved-state checks read across the seam: it verifies the PHYSICAL's
/// current mode, and what that mode reports depends on the geometry of a
/// virtual display the other fake created. Two fakes that could not see each
/// other would make that check tautological.
///
/// `@unchecked Sendable` is justified by confinement: every stored property
/// lives behind `lock` and the accessors below are the only way in. The tests
/// need that because the engine is an actor, so its calls run on the actor's
/// executor while the test body reads the log from its own task.
final class FakeSynthesisWorld: @unchecked Sendable {
  struct Panel {
    let identity: DisplayConfigIdentity
    let name: String
    let isBuiltIn: Bool
    /// What this display would report if it were showing its own framebuffer.
    var ownMode: DisplayMode
  }

  private let lock = NSLock()
  private var _calls: [SynthesisCall] = []
  private var _panels: [CGDirectDisplayID: Panel] = [:]
  /// Enumeration order for `displays()`; `MirrorTopology` sorts anyway, but a
  /// stable order keeps the fixtures readable.
  private var _order: [CGDirectDisplayID] = []
  private var _mirrors: [CGDirectDisplayID: CGDirectDisplayID] = [:]
  private var _liveSlots: [Int: VirtualDisplayHandle] = [:]

  private var _isAvailable = true
  private var _createFailure: VirtualDisplayFailure?
  private var _virtualDisplayStaysNonHiDPI = false
  private var _destroySucceeds = true
  private var _mirrorFailure: DisplayConfigError?
  private var _acceptMirrorButLeaveTopologyUnchanged = false
  private var _physicalKeepsOwnModeWhileMirrored = false

  // MARK: - Wiring

  /// The display ID a synthesis slot's virtual display gets. Far away from the
  /// physical IDs the fixtures use, so a confusion between the two is visible
  /// in a failure message rather than plausible.
  static func virtualDisplayID(slot: Int) -> CGDirectDisplayID { 900 + CGDirectDisplayID(slot) }

  func addPhysical(
    id: CGDirectDisplayID, vendor: UInt32 = 0x10AC, model: UInt32 = 1, serial: UInt32 = 1,
    logicalWidth: Int, logicalHeight: Int, refreshHz: Double
  ) {
    let identity = DisplayConfigIdentity(vendor: vendor, model: model, serial: serial, isBuiltIn: false)
    lock.withLock {
      _panels[id] = Panel(
        identity: identity, name: "Display \(id)", isBuiltIn: false,
        ownMode: DisplayMode(
          ioModeID: Int32(id), logicalWidth: logicalWidth, logicalHeight: logicalHeight,
          pixelWidth: logicalWidth, pixelHeight: logicalHeight, refreshHz: refreshHz,
          isNative: true
        )
      )
      if !_order.contains(id) { _order.append(id) }
    }
  }

  func identityKey(of id: CGDirectDisplayID) -> String {
    lock.withLock { _panels[id]?.identity.key ?? "" }
  }

  var calls: [SynthesisCall] { lock.withLock { _calls } }
  var mirrors: [CGDirectDisplayID: CGDirectDisplayID] { lock.withLock { _mirrors } }
  var liveSlots: [Int] { lock.withLock { _liveSlots.keys.sorted() } }

  var isAvailable: Bool {
    get { lock.withLock { _isAvailable } }
    set { lock.withLock { _isAvailable = newValue } }
  }

  /// Every create fails with this. The engine must surface it and destroy
  /// nothing: a create that returned a failure never took a slot.
  var createFailure: VirtualDisplayFailure? {
    get { lock.withLock { _createFailure } }
    set { lock.withLock { _createFailure = newValue } }
  }

  /// The measured create-succeeded-but-stayed-1x case the host logs by name.
  /// The display appears, the slot is live, and the achieved mode is not the
  /// size that was asked for, so the engine has something real to catch.
  var virtualDisplayStaysNonHiDPI: Bool {
    get { lock.withLock { _virtualDisplayStaysNonHiDPI } }
    set { lock.withLock { _virtualDisplayStaysNonHiDPI = newValue } }
  }

  /// Release the token, keep the display online. `VirtualDisplayHost` calls
  /// this slot stranded: nothing can destroy it again from this process.
  var destroySucceeds: Bool {
    get { lock.withLock { _destroySucceeds } }
    set { lock.withLock { _destroySucceeds = newValue } }
  }

  var mirrorFailure: DisplayConfigError? {
    get { lock.withLock { _mirrorFailure } }
    set { lock.withLock { _mirrorFailure = newValue } }
  }

  /// Accept the batch, report success, change nothing. This is #53's shape:
  /// `CGCompleteDisplayConfiguration` returning `.success` over a topology it
  /// did not honour.
  var acceptMirrorButLeaveTopologyUnchanged: Bool {
    get { lock.withLock { _acceptMirrorButLeaveTopologyUnchanged } }
    set { lock.withLock { _acceptMirrorButLeaveTopologyUnchanged = newValue } }
  }

  /// The mirror lands in the topology and the panel does not follow it: the
  /// flags say mirrored, `currentMode` still reports the panel's own geometry.
  /// The half of the engage check that a topology snapshot alone cannot catch.
  var physicalKeepsOwnModeWhileMirrored: Bool {
    get { lock.withLock { _physicalKeepsOwnModeWhileMirrored } }
    set { lock.withLock { _physicalKeepsOwnModeWhileMirrored = newValue } }
  }

  // MARK: - Virtual displays

  func record(_ call: SynthesisCall) { lock.withLock { _calls.append(call) } }

  func create(
    _ spec: VirtualDisplaySpec, slot: Int, uuid: UUID
  ) -> Result<VirtualDisplayHandle, VirtualDisplayFailure> {
    lock.withLock {
      _calls.append(.createVirtualDisplay(
        slot: slot, name: spec.name, logicalWidth: spec.logicalWidth,
        logicalHeight: spec.logicalHeight, hiDPI: spec.hiDPI
      ))
      if let _createFailure { return .failure(_createFailure) }
      guard _liveSlots[slot] == nil else { return .failure(.capExceeded) }

      let id = Self.virtualDisplayID(slot: slot)
      let scale = spec.hiDPI && !_virtualDisplayStaysNonHiDPI ? 2 : 1
      _panels[id] = Panel(
        identity: VirtualDisplayIdentity.configIdentity(slot: slot),
        name: spec.name, isBuiltIn: false,
        ownMode: DisplayMode(
          ioModeID: Int32(id), logicalWidth: spec.logicalWidth, logicalHeight: spec.logicalHeight,
          pixelWidth: spec.logicalWidth * scale, pixelHeight: spec.logicalHeight * scale,
          refreshHz: spec.refreshHz, isNative: false
        )
      )
      if !_order.contains(id) { _order.append(id) }
      let handle = VirtualDisplayHandle(
        uuid: uuid, slot: slot, displayID: id,
        identity: VirtualDisplayIdentity.configIdentity(slot: slot), spec: spec
      )
      _liveSlots[slot] = handle
      return .success(handle)
    }
  }

  func destroy(slot: Int) -> Bool {
    lock.withLock {
      _calls.append(.destroyVirtualDisplay(slot: slot))
      guard let handle = _liveSlots[slot] else { return true }
      guard _destroySucceeds else { return false }
      _liveSlots.removeValue(forKey: slot)
      _panels.removeValue(forKey: handle.displayID)
      _order.removeAll { $0 == handle.displayID }
      // A departing master takes its set with it, the way the host's own
      // release path does.
      for (slave, master) in _mirrors where master == handle.displayID {
        _mirrors.removeValue(forKey: slave)
      }
      return true
    }
  }

  func liveHandles() -> [VirtualDisplayHandle] {
    lock.withLock { _liveSlots.values.sorted { $0.slot < $1.slot } }
  }

  func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)? {
    lock.withLock {
      guard let handle = _liveSlots[slot], let panel = _panels[handle.displayID] else { return nil }
      return (
        panel.ownMode.logicalWidth, panel.ownMode.logicalHeight,
        panel.ownMode.pixelWidth >= panel.ownMode.logicalWidth * 2
      )
    }
  }

  // MARK: - Configuration

  func configuredDisplays() -> [ConfiguredDisplay] {
    lock.withLock {
      let mirrors = _mirrors
      return _order.compactMap { id -> ConfiguredDisplay? in
        guard let panel = _panels[id] else { return nil }
        return ConfiguredDisplay(
          id: id, identity: panel.identity, name: panel.name, isBuiltIn: panel.isBuiltIn,
          mirrorsDisplay: mirrors[id] ?? kCGNullDirectDisplay,
          // A master is a set member too, and it is never named in the change
          // list that builds the set, so membership is recomputed over the
          // whole post-state rather than read off the batch.
          isInMirrorSet: mirrors.values.contains(id)
        )
      }
    }
  }

  /// The mode a display reports NOW.
  ///
  /// While mirrored this is Phase 0's synthetic descriptor: the master's
  /// logical and pixel geometry under the slave's OWN refresh, with a
  /// fabricated `ioModeID` that appears in no enumeration.
  func currentMode(for id: CGDirectDisplayID) -> DisplayMode? {
    lock.withLock {
      guard let panel = _panels[id] else { return nil }
      guard !_physicalKeepsOwnModeWhileMirrored,
            let master = _mirrors[id], let masterPanel = _panels[master]
      else { return panel.ownMode }
      return DisplayMode(
        ioModeID: 166,
        logicalWidth: masterPanel.ownMode.logicalWidth,
        logicalHeight: masterPanel.ownMode.logicalHeight,
        pixelWidth: masterPanel.ownMode.pixelWidth,
        pixelHeight: masterPanel.ownMode.pixelHeight,
        refreshHz: panel.ownMode.refreshHz,
        isNative: false
      )
    }
  }

  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    try lock.withLock {
      // The empty-batch guard runs BEFORE the injection point, because
      // `CoreGraphicsDisplayConfigurator.applyMirroring` returns on its own
      // empty guard before it can reach anything that fails.
      guard !changes.isEmpty else { return }
      _calls.append(.applyMirroring(changes, scope: scope))
      if let _mirrorFailure { throw _mirrorFailure }
      guard !_acceptMirrorButLeaveTopologyUnchanged else { return }
      for change in changes {
        if change.master == kCGNullDirectDisplay {
          _mirrors.removeValue(forKey: change.display)
        } else {
          _mirrors[change.display] = change.master
        }
      }
    }
  }
}

/// `VirtualDisplayProviding` plus the achieved-mode readback, over the shared
/// world.
final class FakeSynthesisVirtualDisplays: VirtualDisplayAchievedModeReporting, @unchecked Sendable {
  let world: FakeSynthesisWorld

  init(_ world: FakeSynthesisWorld) { self.world = world }

  var isAvailable: Bool { world.isAvailable }

  var ownedDisplayIDs: Set<CGDirectDisplayID> { Set(world.liveHandles().map(\.displayID)) }

  func live() -> [VirtualDisplayHandle] { world.liveHandles() }

  func create(
    _ spec: VirtualDisplaySpec, slot: Int, uuid: UUID, appearanceTimeout _: TimeInterval
  ) -> Result<VirtualDisplayHandle, VirtualDisplayFailure> {
    world.create(spec, slot: slot, uuid: uuid)
  }

  @discardableResult
  func destroy(slot: Int, departureTimeout _: TimeInterval) -> Bool { world.destroy(slot: slot) }

  @discardableResult
  func destroyAll(departureTimeout: TimeInterval) -> Bool {
    live().map { destroy(slot: $0.slot, departureTimeout: departureTimeout) }.allSatisfy { $0 }
  }

  func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)? {
    world.achievedMode(slot: slot)
  }
}

/// `DisplayConfiguring` over the shared world. Everything the synthesis engine
/// does not use records `.unexpected` rather than answering quietly, so a test
/// can assert the engine never applied a mode or rotated anything.
final class FakeSynthesisConfigurator: DisplayConfiguring, @unchecked Sendable {
  let world: FakeSynthesisWorld

  init(_ world: FakeSynthesisWorld) { self.world = world }

  func displays() -> [ConfiguredDisplay] { world.configuredDisplays() }

  func modes(for _: CGDirectDisplayID) -> [DisplayMode] {
    world.record(.unexpected("modes(for:)"))
    return []
  }

  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
    world.currentMode(for: displayID)
  }

  func nativePixels(for _: CGDirectDisplayID) -> (width: Int, height: Int)? {
    world.record(.unexpected("nativePixels(for:)"))
    return nil
  }

  func apply(_: DisplayMode, to _: CGDirectDisplayID, scope _: DisplayConfigScope) throws {
    world.record(.unexpected("apply(_:to:scope:)"))
  }

  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    try world.applyMirroring(changes, scope: scope)
  }

  var revealsHiddenModes: Bool { false }
  var guardsWireTiming: Bool { true }
  func modesWithheldByWireTimingGuard(for _: CGDirectDisplayID) -> Int { 0 }

  var canRotate: Bool { true }
  func rotation(of _: CGDirectDisplayID) -> DisplayRotation? { .standard }

  func applyRotation(_: DisplayRotation, to _: CGDirectDisplayID) throws {
    world.record(.unexpected("applyRotation(_:to:)"))
  }
}
