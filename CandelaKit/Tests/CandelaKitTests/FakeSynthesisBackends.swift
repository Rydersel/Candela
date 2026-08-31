import CoreGraphics
import Foundation
@testable import CandelaKit

/// One call the engine made against either backend, in order. One log across both
/// fakes deliberately: the unwind ordering rule (SS10) is about the relationship
/// between a mirror change and a virtual-display destroy, which two logs cannot show.
enum SynthesisCall: Equatable {
  case createVirtualDisplay(slot: Int, name: String, logicalWidth: Int, logicalHeight: Int, hiDPI: Bool)
  case destroyVirtualDisplay(slot: Int)
  case applyMirroring([MirrorChange], scope: DisplayConfigScope)
  /// Something the engine has no business doing. Recorded rather than trapped
  /// so a test can assert its absence and name what happened when it fires.
  case unexpected(String)
}

/// The machine both synthesis fakes describe: panels, mirror topology, live slots
/// and the call log. Shared rather than two independent fakes because the engine's
/// achieved-state checks read across the seam, so two fakes that could not see each
/// other would make those checks tautological.
///
/// `@unchecked Sendable` is justified by confinement: every stored property lives
/// behind `lock` and the accessors below are the only way in. Needed because the
/// engine is an actor, so its calls run on the actor's executor while the test body
/// reads the log from its own task.
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
  /// The geometry each display was LAST given by a master, kept after the
  /// mirror comes off so `panelStaysOnMasterGeometryAfterUnmirror` has
  /// something to keep reporting.
  private var _lastMasterMode: [CGDirectDisplayID: DisplayMode] = [:]
  private var _liveSlots: [Int: VirtualDisplayHandle] = [:]
  /// What each live slot ACHIEVED, recorded at creation the way
  /// `VirtualDisplayHost` records its engage helper's verdict. Never derived
  /// from a read: the creating process cannot read its own virtual display.
  private var _achievedModes: [Int: (width: Int, height: Int, hiDPI: Bool)] = [:]
  /// Slots whose destroy released the token while the display stayed online,
  /// recorded exactly as `VirtualDisplayHost` records them. The slot entry is
  /// dropped either way, so this is the only thing a LATER destroy of the same
  /// slot can answer from.
  private var _stranded: Set<Int> = []

  private var _isAvailable = true
  private var _createFailure: VirtualDisplayFailure?
  private var _createFailureSlots: Set<Int>?
  private var _hiDPIEngageVerdict = true
  private var _destroySucceeds = true
  private var _mirrorFailure: DisplayConfigError?
  private var _acceptMirrorButLeaveTopologyUnchanged = false
  private var _physicalKeepsOwnModeWhileMirrored = false
  private var _displaysHidesTheMirror = false
  private var _panelStaysOnMasterGeometryAfterUnmirror = false
  private var _panelReportsAnUnlistedModeAfterUnmirror = false
  private var _panelReadbackIsUnreadable = false

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

  /// The panel is unplugged. Everything about it goes, including its place in
  /// `displays()`, which is what a teardown for a departed display sees.
  func removePhysical(_ id: CGDirectDisplayID) {
    lock.withLock {
      _panels.removeValue(forKey: id)
      _order.removeAll { $0 == id }
      _mirrors.removeValue(forKey: id)
      _lastMasterMode.removeValue(forKey: id)
    }
  }

  func identityKey(of id: CGDirectDisplayID) -> String {
    lock.withLock { _panels[id]?.identity.key ?? "" }
  }

  var calls: [SynthesisCall] { lock.withLock { _calls } }
  var mirrors: [CGDirectDisplayID: CGDirectDisplayID] { lock.withLock { _mirrors } }
  var liveSlots: [Int] { lock.withLock { _liveSlots.keys.sorted() } }

  /// Virtual displays that are still ONLINE, whether or not a slot still holds
  /// them. A stranded slot leaves one of these behind with nothing able to
  /// destroy it.
  var onlineVirtualDisplayIDs: [CGDirectDisplayID] {
    lock.withLock { _order.filter { $0 >= Self.virtualDisplayID(slot: 0) } }
  }

  var isAvailable: Bool {
    get { lock.withLock { _isAvailable } }
    set { lock.withLock { _isAvailable = newValue } }
  }

  /// Fail creates with this. The engine must surface it and destroy nothing: a
  /// create that returned a failure never took a slot.
  var createFailure: VirtualDisplayFailure? {
    get { lock.withLock { _createFailure } }
    set { lock.withLock { _createFailure = newValue } }
  }

  /// Narrows `createFailure` to particular slots, so a refusal that is about
  /// ONE slot can be told apart from one that is about the spec.
  var createFailureSlots: Set<Int>? {
    get { lock.withLock { _createFailureSlots } }
    set { lock.withLock { _createFailureSlots = newValue } }
  }

  /// What the 2x engage helper reported for a create. False is the measured
  /// create-succeeded-but-stayed-1x case: the display appears, the slot is live, and
  /// the achieved mode is not the size asked for. A recorded verdict rather than a
  /// derived read, because the creating process cannot read its own virtual display.
  var hiDPIEngageVerdict: Bool {
    get { lock.withLock { _hiDPIEngageVerdict } }
    set { lock.withLock { _hiDPIEngageVerdict = newValue } }
  }

  /// Release the token and keep the display online: `VirtualDisplayHost` calls
  /// that slot stranded. The slot entry is dropped anyway, exactly as the host
  /// drops it before releasing, so the RETURN VALUE is the only signal there is.
  var destroySucceeds: Bool {
    get { lock.withLock { _destroySucceeds } }
    set { lock.withLock { _destroySucceeds = newValue } }
  }

  var mirrorFailure: DisplayConfigError? {
    get { lock.withLock { _mirrorFailure } }
    set { lock.withLock { _mirrorFailure = newValue } }
  }

  /// Accept the batch and change nothing: the platform shape where a configuration
  /// returns success without honouring the request. Production catches it, since
  /// `applyMirroring` runs `MirrorVerification.unhonoured` and throws.
  var acceptMirrorButLeaveTopologyUnchanged: Bool {
    get { lock.withLock { _acceptMirrorButLeaveTopologyUnchanged } }
    set { lock.withLock { _acceptMirrorButLeaveTopologyUnchanged = newValue } }
  }

  /// The mirror lands in the topology and the panel does not follow it: the
  /// flags say mirrored, `currentMode` still reports the panel's own geometry.
  var physicalKeepsOwnModeWhileMirrored: Bool {
    get { lock.withLock { _physicalKeepsOwnModeWhileMirrored } }
    set { lock.withLock { _physicalKeepsOwnModeWhileMirrored = newValue } }
  }

  /// The opposite half: `displays()` reports nobody mirroring while the mirror really
  /// stands. The apply is honoured, so `MirrorVerification` passes and only the
  /// caller's own snapshot check can catch it.
  var displaysHidesTheMirror: Bool {
    get { lock.withLock { _displaysHidesTheMirror } }
    set { lock.withLock { _displaysHidesTheMirror = newValue } }
  }

  /// The mirror comes off and the panel stays on the master's geometry. SS10's
  /// last disengage step is the only thing that looks at this.
  var panelStaysOnMasterGeometryAfterUnmirror: Bool {
    get { lock.withLock { _panelStaysOnMasterGeometryAfterUnmirror } }
    set { lock.withLock { _panelStaysOnMasterGeometryAfterUnmirror = newValue } }
  }

  /// The mirror comes off and the panel reports a descriptor in no enumeration of its
  /// own: a fabricated mode surviving the break. Its geometry is not the rendered
  /// size either, so only "the panel reports a mode it publishes" catches it.
  var panelReportsAnUnlistedModeAfterUnmirror: Bool {
    get { lock.withLock { _panelReportsAnUnlistedModeAfterUnmirror } }
    set { lock.withLock { _panelReportsAnUnlistedModeAfterUnmirror = newValue } }
  }

  /// `currentMode` answers nil for a display that is still online: the ordinary
  /// shape of a panel mid-reconfiguration, which is where the teardown's last
  /// check runs. Evidence of nothing, and the engine has to treat it that way.
  var panelReadbackIsUnreadable: Bool {
    get { lock.withLock { _panelReadbackIsUnreadable } }
    set { lock.withLock { _panelReadbackIsUnreadable = newValue } }
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
      if let _createFailure, _createFailureSlots?.contains(slot) ?? true {
        return .failure(_createFailure)
      }
      guard _liveSlots[slot] == nil else { return .failure(.capExceeded) }

      let id = Self.virtualDisplayID(slot: slot)
      let engaged = spec.hiDPI && _hiDPIEngageVerdict
      _panels[id] = Panel(
        identity: VirtualDisplayIdentity.configIdentity(slot: slot),
        name: spec.name, isBuiltIn: false,
        ownMode: DisplayMode(
          ioModeID: Int32(id), logicalWidth: spec.logicalWidth, logicalHeight: spec.logicalHeight,
          pixelWidth: spec.logicalWidth * (engaged ? 2 : 1),
          pixelHeight: spec.logicalHeight * (engaged ? 2 : 1),
          refreshHz: spec.refreshHz, isNative: false
        )
      )
      if !_order.contains(id) { _order.append(id) }
      let handle = VirtualDisplayHandle(
        uuid: uuid, slot: slot, displayID: id,
        identity: VirtualDisplayIdentity.configIdentity(slot: slot), spec: spec
      )
      _liveSlots[slot] = handle
      _achievedModes[slot] = (spec.logicalWidth, spec.logicalHeight, engaged)
      return .success(handle)
    }
  }

  /// The host's shape exactly: the slot entry is dropped BEFORE the release, so a
  /// display that did not depart leaves the slot looking free while still online.
  /// Only the return value says what happened, and a slot already recorded as
  /// stranded keeps saying so: there is no entry left to find it by.
  func destroy(slot: Int) -> Bool {
    lock.withLock {
      _calls.append(.destroyVirtualDisplay(slot: slot))
      _achievedModes.removeValue(forKey: slot)
      guard let handle = _liveSlots.removeValue(forKey: slot)
      else { return !_stranded.contains(slot) }
      guard _destroySucceeds else {
        _stranded.insert(slot)
        return false
      }
      _stranded.remove(slot)
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
      guard _liveSlots[slot] != nil else { return nil }
      return _achievedModes[slot]
    }
  }

  // MARK: - Configuration

  func configuredDisplays() -> [ConfiguredDisplay] {
    lock.withLock {
      let mirrors = _displaysHidesTheMirror ? [:] : _mirrors
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

  /// The mode a display reports now. While mirrored that is a synthetic descriptor:
  /// the master's geometry under the slave's own refresh, with a fabricated
  /// `ioModeID` that appears in no enumeration.
  func currentMode(for id: CGDirectDisplayID) -> DisplayMode? {
    lock.withLock {
      guard let panel = _panels[id] else { return nil }
      if _panelReadbackIsUnreadable, _mirrors[id] == nil { return nil }
      guard !_physicalKeepsOwnModeWhileMirrored else { return panel.ownMode }
      if _panelReportsAnUnlistedModeAfterUnmirror, _mirrors[id] == nil {
        return DisplayMode(
          ioModeID: 166,
          logicalWidth: panel.ownMode.logicalWidth - 8,
          logicalHeight: panel.ownMode.logicalHeight - 8,
          pixelWidth: panel.ownMode.pixelWidth - 8,
          pixelHeight: panel.ownMode.pixelHeight - 8,
          refreshHz: panel.ownMode.refreshHz, isNative: false
        )
      }
      let masterMode: DisplayMode? = if let master = _mirrors[id] {
        _panels[master]?.ownMode
      } else if _panelStaysOnMasterGeometryAfterUnmirror {
        _lastMasterMode[id]
      } else {
        nil
      }
      guard let masterMode else { return panel.ownMode }
      return DisplayMode(
        ioModeID: 166,
        logicalWidth: masterMode.logicalWidth, logicalHeight: masterMode.logicalHeight,
        pixelWidth: masterMode.pixelWidth, pixelHeight: masterMode.pixelHeight,
        refreshHz: panel.ownMode.refreshHz,
        isNative: false
      )
    }
  }

  /// What a display PUBLISHES, which is a different question from what it is
  /// reporting right now: the list does not change under a mirror. SS10's last
  /// disengage step asks it whether the panel came back to a mode of its own,
  /// so a fake that answered nothing would report every unwind incomplete.
  func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
    lock.withLock { _panels[id].map { [$0.ownMode] } ?? [] }
  }

  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    try lock.withLock {
      // The empty-batch guard runs BEFORE the injection point, because
      // `CoreGraphicsDisplayConfigurator.applyMirroring` returns on its own
      // empty guard before it can reach anything that fails.
      guard !changes.isEmpty else { return }
      _calls.append(.applyMirroring(changes, scope: scope))
      if let _mirrorFailure { throw _mirrorFailure }
      if !_acceptMirrorButLeaveTopologyUnchanged {
        for change in changes {
          if change.master == kCGNullDirectDisplay {
            _mirrors.removeValue(forKey: change.display)
          } else {
            _mirrors[change.display] = change.master
            if let masterMode = _panels[change.master]?.ownMode {
              _lastMasterMode[change.display] = masterMode
            }
          }
        }
      }
      // The same post-commit check production runs, deliberately last: the batch is
      // recorded and the topology has moved before this throws, because a commit that
      // diverged still committed. Without it the fake accepts a topology CoreGraphics
      // would have refused.
      if MirrorVerification.unhonoured(in: changes, achievedParent: { id in
        _mirrors[id] ?? kCGNullDirectDisplay
      }) != nil {
        throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
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

/// `DisplayConfiguring` over the shared world. Everything the synthesis engine does
/// not use records `.unexpected` rather than answering quietly, so a test can assert
/// the engine never applied a mode or rotated anything.
final class FakeSynthesisConfigurator: DisplayConfiguring, @unchecked Sendable {
  let world: FakeSynthesisWorld

  init(_ world: FakeSynthesisWorld) { self.world = world }

  func displays() -> [ConfiguredDisplay] { world.configuredDisplays() }

  /// Answered rather than recorded as unexpected: the engine reads the panel's
  /// own list to decide whether a teardown put it back on a mode it publishes.
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
    world.modes(for: displayID)
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
