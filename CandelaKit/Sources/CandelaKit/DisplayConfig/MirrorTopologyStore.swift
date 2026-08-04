import CoreGraphics
import Foundation
import os

/// Synchronous, nonisolated access to the latest mirror topology, for callers
/// that cannot await one.
///
/// **The engine resolves the ID; the islands stay simple (DT16).**
/// A mirror SLAVE is absent from `NSScreen.screens` altogether, so the
/// one-line `NSScreen.screens.first { $0.displayID == id }` that nine AppKit
/// sites in the app share returns nil for it — and two of those sites fail
/// SILENTLY while recording success: `ShadeOverlay` stops dimming, and
/// `GammaController` parks its enforcer at a stale origin with `lastAppliedScale`
/// still saying the apply worked. The fix is not a smarter lookup at each of
/// the nine, and it is deliberately not an `NSScreen`-shaped accessor on the
/// engine seam — `NSScreen` is an AppKit-island problem, and `CandelaKit`
/// imports neither AppKit nor SwiftUI. It is this: hand every island an ID that
/// is already guaranteed drawable, once, at the boundary. The islands keep
/// their one-line lookup and exercise no judgement.
///
/// **Why a lock and not an actor.** The readers cannot await.
/// `BrightnessController.applySoftware` is synchronous and inline on the drag
/// path, and the AppKit islands it drives are main-actor objects called from
/// inside it. An actor here would put a suspension in the hottest path in the
/// app for a value that changes a handful of times a session — and a
/// suspension mid-drag is exactly the shape of the round-1 coalescer defect,
/// where a @MainActor caller could not hop while the run loop sat in
/// event-tracking mode.
public protocol MirrorTopologyProviding: Sendable {
  /// The display that actually owns the pixels for `displayID` — see
  /// `MirrorTopology.drawableDisplayID(for:)`. An ID this provider knows
  /// nothing about comes back UNCHANGED: a topology never invents a target.
  func drawableDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID
  /// The whole current sample, as a value. For callers needing more than the
  /// drawable ID — set membership, masters, the toggle decision.
  func topology() -> MirrorTopology
}

/// The one holder of the current topology, written wherever topology changes
/// arrive and read from the main actor.
///
/// **Checked `Sendable`, not `@unchecked`.** The single stored property is an
/// `OSAllocatedUnfairLock<MirrorTopology>`, which is itself `Sendable` over a
/// `Sendable` value, so the compiler verifies this conformance rather than
/// being told to trust it. That is the same mechanism `DisplayManager`'s epoch
/// state and the write coalescer's submission slot use — one lock, one value
/// behind it, public synchronous readers — and preferring it here means house
/// rule 9 (never an `@unchecked` without a justification) simply does not come
/// up. Verified under `swift test --sanitize=thread`.
///
/// Readers get a VALUE, so a caller keeps reasoning about the instant it read
/// rather than about a topology that moved under it mid-decision.
///
/// A store nobody has updated holds an EMPTY topology, whose
/// `drawableDisplayID` is the identity function — i.e. exactly today's
/// behaviour. An unwired engine therefore degrades to the status quo (a lookup
/// that fails and is REPORTED, DT17) rather than to a crash or a guess.
public final class MirrorTopologyStore: MirrorTopologyProviding, Sendable {
  private let stored: OSAllocatedUnfairLock<MirrorTopology>

  public init(_ topology: MirrorTopology = MirrorTopology([])) {
    stored = OSAllocatedUnfairLock(initialState: topology)
  }

  /// Called at launch and on every screen-parameters change. ONE assignment of
  /// a whole sample, never a field at a time, so no reader ever sees a topology
  /// half-way between two machine states — the sampling hazard `MirrorTopology`
  /// exists to close would otherwise walk straight back in here.
  public func update(_ topology: MirrorTopology) {
    stored.withLock { $0 = topology }
  }

  public func topology() -> MirrorTopology {
    stored.withLock { $0 }
  }

  public func drawableDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    // Copied out first: the resolution is pure, and holding the lock across it
    // would serialise every drag-path read behind every other one.
    topology().drawableDisplayID(for: displayID)
  }
}
