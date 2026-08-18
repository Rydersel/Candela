import CoreGraphics
import Foundation
import os

/// `VirtualDisplayProviding` plus the one readback the synthesis sequence
/// verifies its virtual display against.
///
/// A refinement rather than a member of the base protocol because the achieved
/// mode is not part of a virtual display's LIFETIME: everything else on that
/// seam creates, destroys or enumerates, and `VirtualDisplaySpec` is
/// deliberately the source of truth for what a display IS (VD5). This asks a
/// different question, and only synthesis has to ask it.
///
/// **Not a live read, and a conformance must not implement it as one.** The
/// creating process usually cannot read its own virtual display back:
/// `CGDisplayCopyDisplayMode` on it returned nil whenever it mattered (measured
/// 2026-08-17). "Usually" rather than "never" on purpose, because
/// `VirtualDisplayHost.create` still tries in-process before spawning its
/// helper and that leg is not dead code; what "usually" costs is the ability to
/// GATE on such a read, since a nil answer is indistinguishable from a display
/// that never reached 2x. A conformance that read live would therefore fail
/// engages on hardware while passing against every fake. `VirtualDisplayHost`
/// answers with the verdict established at creation instead, which is the only
/// evidence the creating process can hold.
public protocol VirtualDisplayAchievedModeReporting: VirtualDisplayProviding {
  /// The achieved geometry of a live slot, or nil when the slot holds nothing.
  func achievedMode(slot: Int) -> (width: Int, height: Int, hiDPI: Bool)?
}

extension VirtualDisplayHost: VirtualDisplayAchievedModeReporting {}

/// One physical display currently showing a synthesized size, and the virtual
/// display it is mirroring to get it.
///
/// The AUTHORITY on synthesis topology (SS1). Nothing derives it from CG mirror
/// flags: Phase 0 measured that a virtual master does report them, and the
/// pairing is still what every carve-out consults, so a driver that stopped
/// reporting them would change nothing here.
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

/// Why a synthesis request produced no engaged size. Every case names a step,
/// so a caller can say which one rather than "it did not work".
public enum SynthesisFailure: Error, Sendable, Equatable {
  /// The private virtual-display class family is absent (VD10). Nothing was
  /// attempted.
  case unavailable
  /// Both synthesis slots are in use. The family is two wide (SS6).
  case noFreeSlot
  case createFailed(VirtualDisplayFailure)
  /// The virtual display came up, and not at the requested size at 2x. The
  /// measured shape of this is a display that stays 1x with its HiDPI variant
  /// never engaged.
  case virtualModeNotAchieved
  /// The mirror transaction refused or diverged.
  case mirrorRefused
  /// The mirror stands and the panel did not follow it: the physical does not
  /// report the master's geometry, so the size is not on the glass.
  case engageNotAchieved
  /// `disengage` was asked about a display that has no pairing.
  case notEngaged
  /// Something the unwind tried to take down is still standing. The loudest
  /// answer in this enum: the caller has a virtual display, a mirror set, or
  /// both that Candela could not remove.
  case unwindIncomplete
}

/// The verified engage and disengage sequence for synthesized sizes (SS10), and
/// the pairing table every other synthesis-aware surface reads (SS1).
///
/// **Non-reentrant by construction.** Its methods are not `async`, so they
/// cannot contain a suspension point, so the actor runs one engage or disengage
/// to completion before it starts another: no second sequence can pick a slot
/// this one has claimed but not yet recorded. The cost is real and deliberate.
/// `VirtualDisplayProviding.create` and `destroy` BLOCK while they poll the
/// online list, so a sequence holds a cooperative-pool thread for as long as
/// that takes. Callers stay off the main actor for free, because reaching an
/// actor from outside suspends the caller rather than blocking it.
///
/// **Nothing here reads a CG mirror flag to decide what is paired.** The flags
/// are read only to check what an apply ACHIEVED, which is a different question
/// and the one thing a return code cannot answer.
public actor ModeSynthesisEngine {
  /// The same name for both slots, deliberately. The colour-profile leak keys
  /// on vendor, product and physical size rather than on this, and a name that
  /// varied per slot or per size would make the two displays read as different
  /// hardware everywhere a person can see them.
  public static let virtualDisplayName = "Candela Scaled Size"

  /// The fallback for the virtual display's refresh when the panel's own
  /// rate cannot be read. The master's rate is NOT cosmetic: the wire runs
  /// the panel's timing, but frame delivery to a mirror is paced by the
  /// master, and a 60 Hz master pacing a faster panel produced visible
  /// flashing that tracked content updates on the MAG 341C
  /// [MEASURED 2026-08-18, from both 175 and 100 Hz]. The spec therefore
  /// carries the panel's current refresh whenever it is known.
  private static let fallbackVirtualRefreshHz: Double = 60

  /// Session scope, never permanent: a stored configuration naming a virtual
  /// display that will not exist at the next login is one nothing can honour.
  /// Not `.preview` either, whose process-exit revert would be a second unwind
  /// path nothing in the sequence can see; the preview layer above reverts by
  /// calling `disengage`.
  private static let scope: DisplayConfigScope = .session

  private let virtualDisplays: any VirtualDisplayAchievedModeReporting
  private let configurator: any DisplayConfiguring
  private let appearanceTimeout: TimeInterval
  private let departureTimeout: TimeInterval
  /// Called with the virtual display's ID at the one instant that closes a
  /// window nothing outside this actor can see: after the display exists and
  /// before the mirror that makes it a master.
  ///
  /// The pairing table is the authority on synthesis topology (SS1), and it is
  /// written only once the whole sequence has passed its checks. That is right
  /// for the table and wrong for everything watching the machine: the mirror
  /// engages in the MIDDLE of this call, and `didChangeScreenParameters` is
  /// posted and sampled synchronously, so between the mirror landing and this
  /// method returning, every carve-out keyed on the pairing reads a synthesis
  /// set as user mirroring. OLED care's static-region history is wiped
  /// irreversibly on that edge, and the mirroring surfaces are exposed to it.
  ///
  /// So the consumer stamps EARLY, from here, and its post-sequence refresh
  /// from the authoritative table is what corrects an over-stamp. Over-stamping
  /// is the safe direction on purpose: calling a display a synthesis master
  /// while nobody is mirroring it changes no predicate, because every one of
  /// them asks about a SET.
  ///
  /// Synchronous and `@Sendable` because it runs on this actor's executor
  /// between two steps of SS10's ordering: it may only touch something
  /// lock-backed and nonisolated, and it must never be given work that blocks.
  private let willMirrorOntoVirtualDisplay: (@Sendable (CGDirectDisplayID) -> Void)?
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "synthesis")

  private var table: [CGDirectDisplayID: SynthesisPairing] = [:]

  public init(
    virtualDisplays: any VirtualDisplayAchievedModeReporting,
    configurator: any DisplayConfiguring,
    appearanceTimeout: TimeInterval = 10,
    departureTimeout: TimeInterval = 5,
    willMirrorOntoVirtualDisplay: (@Sendable (CGDirectDisplayID) -> Void)? = nil
  ) {
    self.virtualDisplays = virtualDisplays
    self.configurator = configurator
    self.appearanceTimeout = appearanceTimeout
    self.departureTimeout = departureTimeout
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

    // A display that is already paired is torn down first. Overwriting its
    // entry instead would drop the old slot out of the table, and nothing else
    // knows how to destroy the display standing in it.
    if table[displayID] != nil, case let .failure(failure) = disengage(fromPhysical: displayID) {
      return .failure(failure)
    }

    let occupied = Set(table.values.map(\.slot))
    let free = VirtualDisplayIdentity.synthesisSlotRange.filter { !occupied.contains($0) }
    guard !free.isEmpty else { return .failure(.noFreeSlot) }

    // The panel's rate at the moment of engage, so the master paces frames
    // at the rate the glass runs. Read before the mirror stands: an engaged
    // panel's descriptor is synthetic and answers for the master.
    let panelHz = configurator.currentMode(for: displayID)
      .map { DisplayMode.quantizedRefresh($0.refreshHz) }
    let spec = VirtualDisplaySpec(
      name: Self.virtualDisplayName,
      logicalWidth: size.logicalWidth, logicalHeight: size.logicalHeight,
      hiDPI: true,
      refreshHz: (panelHz ?? 0) > 0 ? panelHz! : Self.fallbackVirtualRefreshHz
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

    // The virtual display's 2x variant is ENGAGED by the host rather than
    // promised by the spec, so what it achieved is what decides. Asked through
    // the host's recorded verdict, never a read: a read from this process
    // answers nil often enough that nothing may gate on it.
    guard let achieved = virtualDisplays.achievedMode(slot: slot),
          achieved.width == size.logicalWidth,
          achieved.height == size.logicalHeight,
          achieved.hiDPI
    else {
      log.error("synthesis.engage slot=\(slot): the virtual display did not reach 2x")
      return .failure(fail(.virtualModeNotAchieved, unwinding: pairing))
    }

    // The LAST thing before the mirror, and the position is the whole point:
    // the mirror lands inside the call below, is reported by a synchronous
    // notification, and is sampled by a store that has no way to know this set
    // is ours. See `willMirrorOntoVirtualDisplay`.
    //
    // After the 2x check rather than straight after the create, so a virtual
    // display that is about to be destroyed for never reaching 2x is not
    // announced as a master. Both positions satisfy the rule; this one
    // announces less.
    willMirrorOntoVirtualDisplay?(handle.displayID)

    // The PHYSICAL becomes the slave of the virtual master: the direction
    // `VirtualDisplayHost.breakMasteredMirrors` already unwinds when a virtual
    // display is released.
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

  /// Try each free slot until one takes the spec, and fall through on the
  /// refusals that are ABOUT THE SLOT rather than about the request.
  ///
  /// `identityInUse` and `capExceeded` are both conditions the pairing table
  /// cannot see: a slot whose display did not depart is stranded for the whole
  /// session, and one the host still holds is occupied by something this table
  /// never recorded. Without the fall-through a single stranded slot 4 refuses
  /// every synthesis request for the rest of the session while slot 5 sits
  /// free. Every other refusal is about the SPEC, and would be refused the same
  /// way by the next slot, so it is reported rather than retried.
  private func createOnFirstUsableSlot(
    _ spec: VirtualDisplaySpec, from free: [Int]
  ) -> Result<(slot: Int, handle: VirtualDisplayHandle), VirtualDisplayFailure> {
    // Optional rather than seeded with a refusal nobody made: `engage` guards on
    // a non-empty `free`, so the loop always records one before the return
    // below, and the seed only ever read as a real answer to somebody skimming.
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
    // The `??` arm is unreachable and is here only because the compiler cannot
    // see `engage`'s non-empty guard.
    return .failure(lastRefusal ?? .capExceeded)
  }

  /// Both halves of the achieved-state check for a landed engage.
  ///
  /// The topology has to show the physical mirroring the virtual master, AND
  /// the physical has to report the master's logical and pixel geometry.
  /// Neither alone is enough: a commit can return success over a topology it
  /// never moved, and a topology that moved does not prove the panel followed.
  ///
  /// **Refresh is deliberately not compared.** While mirrored the physical
  /// reports the master's geometry at its OWN rate (Phase 0), which is the
  /// point of the whole feature: the panel keeps its refresh. Nothing here may
  /// persist or descriptor-round-trip this readback either; it is a synthetic
  /// descriptor under a fabricated mode ID that appears in no enumeration.
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
      // and every SS7 carve-out keeps reading the set as synthesis rather than
      // as mirroring the user built.
      return .failure(.unwindIncomplete)
    }
    table[displayID] = nil
    log.info("synthesis.disengage slot=\(pairing.slot) physical=\(displayID)")
    return .success(())
  }

  // MARK: - Unwind

  /// Reverse the steps that have been taken, and say whether the machine came
  /// all the way back.
  ///
  /// **Break the mirror, then destroy the virtual display, then check the
  /// panel** (SS10). That order is the contract: releasing a master first
  /// leaves its slaves showing a framebuffer that is going away, and the host's
  /// own release path breaks mastered mirrors for exactly that reason.
  ///
  /// The break is staged only when the topology says the physical is actually
  /// mirroring this master, rather than when our bookkeeping says it should be.
  /// A transaction whose changes are all no-ops fails at the commit with 1001
  /// after every stage succeeded (measured), so an unconditional break would
  /// report an incomplete unwind for a machine that was already clean.
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

    // Destroyed even when the break failed. The host releases a display whose
    // mirror set it could not break for the same reason: a virtual display
    // nothing can reach again is worse than a set that outlived its master.
    //
    // The RETURN VALUE is the departure check, and the only one available: the
    // host drops the slot before it releases the token, so a stranded display
    // leaves `live()` looking clean while the display is still online. This is
    // not a bare success code being trusted; the host polls the online list and
    // returns false when the display was still in it at the deadline.
    if !virtualDisplays.destroy(slot: pairing.slot, departureTimeout: departureTimeout) {
      complete = false
    }

    // SS10's last step. A panel still reporting the master's logical and pixel
    // geometry is still showing the synthesized size, whatever the topology
    // says about who mirrors whom. The panel's own native size cannot collide
    // with this: SS2 drops any stop an existing row already serves, and every
    // stop is strictly smaller than native.
    if let panel = configurator.currentMode(for: pairing.physicalDisplayID),
       panel.logicalWidth == pairing.size.logicalWidth,
       panel.logicalHeight == pairing.size.logicalHeight,
       panel.pixelWidth == pairing.size.pixelWidth,
       panel.pixelHeight == pairing.size.pixelHeight {
      complete = false
    }

    if !complete {
      log.error("synthesis.unwind slot=\(pairing.slot) physical=\(pairing.physicalDisplayID) did NOT complete")
    }
    return complete
  }

  private func mirrorStands(_ pairing: SynthesisPairing) -> Bool {
    configurator.displays()
      .first { $0.id == pairing.physicalDisplayID }?
      .mirrorsDisplay == pairing.virtualDisplayID
  }

  /// Unwind a half-built engage and decide what the caller hears: the step's
  /// own failure when the machine came back, and `.unwindIncomplete` when it
  /// did not.
  ///
  /// A failed unwind RECORDS the pairing rather than discarding it. The slot is
  /// occupied by a display that is still standing, so leaving the table empty
  /// would hand the next engage a slot it cannot have and leave the stranded
  /// display invisible to every synthesis-aware carve-out. It means "something
  /// may still be up", never "this is working".
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
