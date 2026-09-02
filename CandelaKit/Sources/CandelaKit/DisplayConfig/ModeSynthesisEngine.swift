import CoreGraphics
import Foundation
import os

/// `VirtualDisplayProviding` plus the one readback the synthesis sequence
/// verifies its virtual display against.
///
/// Separate from the base protocol because achieved mode is not part of a
/// virtual display's lifetime, and only synthesis has to ask.
///
/// **Not a live read, and a conformance must not implement it as one.** The
/// creating process usually cannot read its own virtual display back:
/// `CGDisplayCopyDisplayMode` on it returned nil whenever it mattered
/// [MEASURED 2026-08-17]. A nil answer is indistinguishable from a display that
/// never reached 2x, so a conformance that read live would fail engages on
/// hardware while passing against every fake. `VirtualDisplayHost` answers with
/// the verdict recorded at creation, the only evidence it can hold.
public protocol VirtualDisplayAchievedModeReporting: VirtualDisplayProviding {
  /// The achieved geometry of a live slot, or nil when the slot holds nothing.
  func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)?
}

extension VirtualDisplayHost: VirtualDisplayAchievedModeReporting {}

/// One physical display currently showing a synthesized size, and the virtual
/// display it is mirroring to get it.
///
/// The authority on synthesis topology. Nothing derives it from CG mirror
/// flags, so a driver that stopped reporting them would change nothing here.
public struct SynthesisPairing: Sendable, Equatable {
  public let physicalDisplayID: CGDirectDisplayID
  /// `DisplayConfigIdentity.key`, carried for the reapply bookkeeping that has
  /// to survive the runtime IDs being reassigned across a replug.
  public let physicalIdentityKey: String
  public let virtualDisplayID: CGDirectDisplayID
  public let slot: Int
  public let size: SyntheticSize

  public init(
    physicalDisplayID: CGDirectDisplayID,
    physicalIdentityKey: String,
    virtualDisplayID: CGDirectDisplayID,
    slot: Int,
    size: SyntheticSize
  ) {
    self.physicalDisplayID = physicalDisplayID
    self.physicalIdentityKey = physicalIdentityKey
    self.virtualDisplayID = virtualDisplayID
    self.slot = slot
    self.size = size
  }
}

/// Why a synthesis request produced no engaged size. Every case names a step.
public enum SynthesisFailure: Error, Sendable, Equatable {
  /// The private virtual-display class family is absent. Nothing was
  /// attempted.
  case unavailable
  /// Both synthesis slots are in use. The family is two wide.
  case noFreeSlot
  case createFailed(VirtualDisplayFailure)
  /// The virtual display came up, and not at the requested size at 2x. Measured
  /// shape: it stays 1x with the HiDPI variant never engaged.
  case virtualModeNotAchieved
  /// The mirror transaction refused or diverged.
  case mirrorRefused
  /// The mirror stands and the panel did not follow it: the physical does not
  /// report the master's geometry, so the size is not on the glass.
  case engageNotAchieved
  /// `disengage` was asked about a display that has no pairing.
  case notEngaged
  /// Something the unwind tried to take down is still standing: a virtual
  /// display, a mirror set, or both that Candela could not remove.
  case unwindIncomplete
}

/// The verified engage and disengage sequence for synthesized sizes, and
/// the pairing table every other synthesis-aware surface reads.
///
/// **Non-reentrant by construction.** The methods are not `async`, so they hold
/// no suspension point and the actor runs one engage or disengage to
/// completion: no second sequence can claim a slot this one took but has not
/// recorded. The cost is real. `VirtualDisplayProviding.create` and `destroy`
/// BLOCK while they poll the online list, so a sequence holds a
/// cooperative-pool thread for that long. Callers are not blocked, because
/// reaching an actor from outside suspends them instead.
///
/// Nothing here reads a CG mirror flag to decide what is paired. The flags say
/// only what an apply achieved, which is the one thing a return code cannot.
public actor ModeSynthesisEngine {
  /// The same name for both slots. The colour-profile leak keys on vendor,
  /// product and physical size rather than on this, and a per-slot name would
  /// make the two displays read as different hardware wherever a person looks.
  public static let virtualDisplayName = "Candela Scaled Size"

  /// The virtual display's own refresh, fixed low on purpose. The glass rate
  /// belongs to the engage tail's retime, so the master's rate is pure
  /// compositing cost: created at the panel's 175 Hz it drove WindowServer to
  /// composite the 2x surface 175 times a second, with a lagging cursor, stalls
  /// on OTHER displays, and cursor double-draw at the neighbouring display's
  /// edge [MEASURED 2026-08-18].
  private static let virtualRefreshHz: Double = 60

  /// Session scope, never permanent: a stored configuration naming a virtual
  /// display that will not exist at next login is one nothing can honour. Not
  /// `.preview` either, whose process-exit revert would be a second unwind path
  /// the sequence cannot see; the layer above reverts by calling `disengage`.
  private static let scope: DisplayConfigScope = .session

  private let virtualDisplays: any VirtualDisplayAchievedModeReporting
  private let configurator: any DisplayConfiguring
  private let appearanceTimeout: TimeInterval
  private let departureTimeout: TimeInterval
  /// A settling allowance between re-asks after a nil readback, not a poll for
  /// an event.
  private let readbackRetryDelay: TimeInterval
  /// Called with the virtual display's ID after the display exists and before
  /// the mirror that makes it a master.
  ///
  /// The pairing table is the authority but is written only once the whole
  /// sequence passes. The mirror lands in the MIDDLE of this call and
  /// `didChangeScreenParameters` is posted and sampled synchronously, so until
  /// it returns every carve-out keyed on the pairing reads a synthesis set as
  /// user mirroring, and OLED care's static-region history is wiped irreversibly
  /// on that edge. So the consumer stamps early from here and corrects an
  /// over-stamp from the table afterwards. Over-stamping is the safe direction:
  /// every predicate asks about a SET, so naming a master nobody mirrors changes
  /// nothing.
  ///
  /// Synchronous and `@Sendable` because it runs on this actor's executor
  /// between two steps of the sequence's ordering: it may only touch something
  /// lock-backed and nonisolated, and must never be given work that blocks.
  private let willMirrorOntoVirtualDisplay: (@Sendable (CGDirectDisplayID) -> Void)?
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "synthesis")

  private var table: [CGDirectDisplayID: SynthesisPairing] = [:]

  public init(
    virtualDisplays: any VirtualDisplayAchievedModeReporting,
    configurator: any DisplayConfiguring,
    appearanceTimeout: TimeInterval = 10,
    departureTimeout: TimeInterval = 5,
    readbackRetryDelay: TimeInterval = 0.15,
    willMirrorOntoVirtualDisplay: (@Sendable (CGDirectDisplayID) -> Void)? = nil
  ) {
    self.virtualDisplays = virtualDisplays
    self.configurator = configurator
    self.appearanceTimeout = appearanceTimeout
    self.departureTimeout = departureTimeout
    self.readbackRetryDelay = readbackRetryDelay
    self.willMirrorOntoVirtualDisplay = willMirrorOntoVirtualDisplay
  }

  public func pairings() -> [SynthesisPairing] {
    table.values.sorted { $0.physicalDisplayID < $1.physicalDisplayID }
  }

  public func pairing(forPhysical displayID: CGDirectDisplayID) -> SynthesisPairing? {
    table[displayID]
  }

  // MARK: - Engage

  public func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) -> Result<SynthesisPairing, SynthesisFailure> {
    guard virtualDisplays.isAvailable else { return .failure(.unavailable) }

    // An already-paired display is torn down first: overwriting its entry drops
    // the old slot from the table, and nothing else knows how to destroy the
    // display standing in it.
    if table[displayID] != nil, case let .failure(failure) = disengage(fromPhysical: displayID) {
      return .failure(failure)
    }

    let occupied = Set(table.values.map(\.slot))
    let free = VirtualDisplayIdentity.synthesisSlotRange.filter { !occupied.contains($0) }
    guard !free.isEmpty else { return .failure(.noFreeSlot) }

    let spec = VirtualDisplaySpec(
      name: Self.virtualDisplayName,
      logicalWidth: size.logicalWidth, logicalHeight: size.logicalHeight,
      hiDPI: true, refreshHz: Self.virtualRefreshHz
    )
    let slot: Int
    let handle: VirtualDisplayHandle
    switch createOnFirstUsableSlot(spec, from: free) {
    case let .success(created):
      (slot, handle) = created
    case let .failure(failure):
      log.error("synthesis.engage: create failed \(String(describing: failure))")
      return .failure(.createFailed(failure))
    }

    let pairing = SynthesisPairing(
      physicalDisplayID: displayID, physicalIdentityKey: identityKey,
      virtualDisplayID: handle.displayID, slot: slot, size: size
    )

    // The 2x variant is engaged by the host, not promised by the spec, so the
    // host's recorded verdict decides. Never a live read: it answers nil often
    // enough that nothing may gate on it.
    guard let achieved = virtualDisplays.achievedMode(slot: slot),
          achieved.width == size.logicalWidth,
          achieved.height == size.logicalHeight,
          achieved.hiDPI
    else {
      log.error("synthesis.engage slot=\(slot): the virtual display did not reach 2x")
      return .failure(fail(.virtualModeNotAchieved, unwinding: pairing))
    }

    // The last thing before the mirror, and the position is the point: the
    // mirror lands inside the call below and is reported by a synchronous
    // notification to a store that cannot know this set is ours. After the 2x
    // check, so a display about to be destroyed is never announced as a master.
    // See `willMirrorOntoVirtualDisplay`.
    willMirrorOntoVirtualDisplay?(handle.displayID)

    // The PHYSICAL becomes the slave of the virtual master, the direction
    // `VirtualDisplayHost.breakMasteredMirrors` unwinds on release.
    do {
      try configurator.applyMirroring(
        [MirrorChange(display: displayID, master: handle.displayID)], scope: Self.scope
      )
    } catch {
      log.error("synthesis.engage slot=\(slot): the mirror was refused")
      return .failure(fail(.mirrorRefused, unwinding: pairing))
    }

    guard engageLanded(pairing) else {
      log.error("synthesis.engage slot=\(slot): the panel did not take the master's geometry")
      return .failure(fail(.engageNotAchieved, unwinding: pairing))
    }

    table[displayID] = pairing
    log.info("synthesis.engage slot=\(slot) physical=\(displayID) vd=\(handle.displayID) \(size.logicalWidth)x\(size.logicalHeight)")
    return .success(pairing)
  }

  /// Try each free slot until one takes the spec, falling through on refusals
  /// that are about the SLOT rather than the request.
  ///
  /// `identityInUse` and `capExceeded` are invisible to the pairing table: a
  /// slot whose display did not depart is stranded for the session, and one the
  /// host still holds was never recorded here. Without the fall-through one
  /// stranded slot refuses every synthesis request for the rest of the session
  /// while another sits free. Any other refusal is about the spec, so the next
  /// slot would refuse it the same way.
  private func createOnFirstUsableSlot(
    _ spec: VirtualDisplaySpec, from free: [Int]
  ) -> Result<(slot: Int, handle: VirtualDisplayHandle), VirtualDisplayFailure> {
    // Optional rather than seeded with a refusal nobody made: `engage` guards
    // on a non-empty `free`, so the loop always records one.
    var lastRefusal: VirtualDisplayFailure?
    for slot in free {
      switch virtualDisplays.create(
        spec, slot: slot, uuid: UUID(), appearanceTimeout: appearanceTimeout
      ) {
      case let .success(handle):
        return .success((slot, handle))
      case let .failure(failure):
        lastRefusal = failure
        guard failure == .identityInUse || failure == .capExceeded else {
          return .failure(failure)
        }
        log.error("synthesis.engage slot=\(slot): unusable (\(String(describing: failure))); trying the next")
      }
    }
    // The `??` arm is unreachable; the compiler cannot see `engage`'s
    // non-empty guard.
    return .failure(lastRefusal ?? .capExceeded)
  }

  /// Both halves of the achieved-state check: the topology has to show the
  /// physical mirroring the virtual master, AND the physical has to report the
  /// master's geometry. A commit can return success over a topology it never
  /// moved, and a moved topology does not prove the panel followed.
  ///
  /// Refresh is deliberately not compared. At this instant the physical reports
  /// the master's geometry at its OWN rate, and that lasts about two seconds
  /// until the engage tail re-times the slave. Nothing may persist or
  /// descriptor-round-trip this readback either way.
  private func engageLanded(_ pairing: SynthesisPairing) -> Bool {
    let mirrored = configurator.displays()
      .first { $0.id == pairing.physicalDisplayID }?
      .mirrorsDisplay == pairing.virtualDisplayID
    guard mirrored, let achieved = configurator.currentMode(for: pairing.physicalDisplayID)
    else { return false }
    return achieved.logicalWidth == pairing.size.logicalWidth
      && achieved.logicalHeight == pairing.size.logicalHeight
      && achieved.pixelWidth == pairing.size.pixelWidth
      && achieved.pixelHeight == pairing.size.pixelHeight
  }

  // MARK: - Disengage

  public func disengage(fromPhysical displayID: CGDirectDisplayID) -> Result<Void, SynthesisFailure> {
    guard let pairing = table[displayID] else { return .failure(.notEngaged) }
    guard unwind(pairing) else {
      // RETAINED, not dropped: a pairing whose teardown did not finish still
      // names the slot and the virtual display, so a later disengage can retry
      // and the mirror-set carve-outs keep reading the set as synthesis.
      return .failure(.unwindIncomplete)
    }
    table[displayID] = nil
    log.info("synthesis.disengage slot=\(pairing.slot) physical=\(displayID)")
    return .success(())
  }

  // MARK: - Unwind

  /// Reverse the steps taken, and say whether the machine came all the way back.
  ///
  /// **Break the mirror, then destroy the virtual display, then check the
  /// panel**. Releasing a master first leaves its slaves showing a
  /// framebuffer that is going away.
  ///
  /// The break is staged only when the topology says the physical really is
  /// mirroring this master. A transaction whose changes are all no-ops fails at
  /// the commit with 1001 (measured), so an unconditional break would report an
  /// incomplete unwind for a machine that was already clean.
  private func unwind(_ pairing: SynthesisPairing) -> Bool {
    var complete = true
    if mirrorStands(pairing) {
      do {
        try configurator.applyMirroring(
          [MirrorChange(display: pairing.physicalDisplayID, master: kCGNullDirectDisplay)],
          scope: Self.scope
        )
      } catch {
        complete = false
      }
      if mirrorStands(pairing) { complete = false }
    }

    // Destroyed even when the break failed: a virtual display nothing can reach
    // again is worse than a set that outlived its master.
    //
    // The return value is the departure check, and the only one available: the
    // host drops the slot before releasing the token, so a stranded display
    // leaves `live()` looking clean. Not a bare success code being trusted; the
    // host polls the online list and returns false if the display is still in
    // it at the deadline.
    if !virtualDisplays.destroy(slot: pairing.slot, departureTimeout: departureTimeout) {
      complete = false
    }

    // The sequence's last step, the only one about the GLASS rather than the topology.
    // Skipped when the display is gone: a departure teardown has no panel to
    // ask, and "incomplete" would retain a pairing for absent hardware.
    let attached = configurator.displays().contains { $0.id == pairing.physicalDisplayID }
    if attached {
      switch panelRestoreVerdict(pairing) {
      case .backOnItsOwnMode:
        break
      case .wrong:
        complete = false
      case .unreadable:
        // NOT a failure. This runs right after breaking a mirror and destroying
        // the display the panel was scanning, and a panel's reported state
        // mid-reconfiguration is evidence of nothing. Calling it incomplete
        // would retain the pairing: a slot held for the session, the opt-out
        // refusing, and a failure shown for a teardown that worked. The topology
        // checks above still have to pass.
        log.error("synthesis.unwind slot=\(pairing.slot) physical=\(pairing.physicalDisplayID): the panel would not say what it is running, so the teardown stands on the topology's evidence alone")
      }
    }

    if !complete {
      log.error("synthesis.unwind slot=\(pairing.slot) physical=\(pairing.physicalDisplayID) did NOT complete")
    }
    return complete
  }

  /// What the panel's post-teardown readback says about the glass. "Would not
  /// answer" is a different fact from "answered wrongly", and only the second is
  /// evidence a teardown failed.
  private enum PanelRestoreVerdict {
    /// It reports a mode its OWN enumeration holds, and that mode is not the
    /// size the set was rendering.
    case backOnItsOwnMode
    /// A positive wrong answer: still the rendered size, or a descriptor this
    /// display does not publish, which is what scanning out somebody else's
    /// framebuffer looks like.
    case wrong
    /// No readback at all, after retries.
    case unreadable
  }

  /// The sequence's last step, asked of the glass rather than of the topology.
  ///
  /// The enumeration-membership half is what makes this able to fail at all.
  /// The engage tail re-times the slave, so seconds after an engage the panel
  /// already reports its own geometry: a check that only asked "is this still
  /// the rendered size" was inert by teardown time, and an inert check reads
  /// exactly like a working one.
  ///
  /// Geometry only, never `ioModeID`: mode ids are positional and a
  /// reconfiguration reassigns them, so an id comparison would fail for a panel
  /// that came back perfectly. A nil readback is retried rather than judged; it
  /// is the ordinary shape of a display mid-reconfiguration.
  private func panelRestoreVerdict(_ pairing: SynthesisPairing) -> PanelRestoreVerdict {
    var panel: DisplayMode?
    for attempt in 1...3 {
      panel = configurator.currentMode(for: pairing.physicalDisplayID)
      if panel != nil { break }
      if attempt < 3, readbackRetryDelay > 0 { Thread.sleep(forTimeInterval: readbackRetryDelay) }
    }
    guard let panel else { return .unreadable }
    let isTheRenderedSize = panel.logicalWidth == pairing.size.logicalWidth
      && panel.logicalHeight == pairing.size.logicalHeight
      && panel.pixelWidth == pairing.size.pixelWidth
      && panel.pixelHeight == pairing.size.pixelHeight
    guard !isTheRenderedSize else { return .wrong }
    // The enumeration gets the same patience as the readback: an empty list is
    // CoreGraphics failing to enumerate mid-reconfiguration, and judging it
    // would call that a wrong answer and retain the pairing forever.
    var modes: [DisplayMode] = []
    for attempt in 1...3 {
      modes = configurator.modes(for: pairing.physicalDisplayID)
      if !modes.isEmpty { break }
      if attempt < 3, readbackRetryDelay > 0 { Thread.sleep(forTimeInterval: readbackRetryDelay) }
    }
    guard !modes.isEmpty else { return .unreadable }
    let publishes = modes.contains {
      $0.logicalWidth == panel.logicalWidth
        && $0.logicalHeight == panel.logicalHeight
        && $0.pixelWidth == panel.pixelWidth
        && $0.pixelHeight == panel.pixelHeight
    }
    return publishes ? .backOnItsOwnMode : .wrong
  }

  private func mirrorStands(_ pairing: SynthesisPairing) -> Bool {
    configurator.displays()
      .first { $0.id == pairing.physicalDisplayID }?
      .mirrorsDisplay == pairing.virtualDisplayID
  }

  /// Unwind a half-built engage: the caller hears the step's own failure when
  /// the machine came back, and `.unwindIncomplete` when it did not.
  ///
  /// A failed unwind RECORDS the pairing rather than discarding it. The slot is
  /// occupied by a display that is still standing, so an empty table would hand
  /// the next engage a slot it cannot have and hide the stranded display from
  /// every synthesis-aware carve-out.
  private func fail(
    _ failure: SynthesisFailure, unwinding pairing: SynthesisPairing
  ) -> SynthesisFailure {
    guard unwind(pairing) else {
      table[pairing.physicalDisplayID] = pairing
      return .unwindIncomplete
    }
    return failure
  }
}
