import CoreGraphics
import Foundation
import os

/// Synchronous, nonisolated access to the latest mirror topology, for callers
/// that cannot await one.
///
/// **The engine resolves the ID; the islands stay simple (DT16).**
/// A mirror SLAVE is absent from `NSScreen.screens` altogether, so the
/// one-line `NSScreen.screens.first { $0.displayID == id }` that the app's
/// AppKit islands share returns nil for it — `ShadeOverlay` (twice),
/// `GammaController`, `BrightnessHUD` and `ModeConfirmationWindow`; five
/// lookups, not the nine an earlier count here claimed, and
/// `KeyActionExecutor`'s sixth is a mouse-in-rect test that was never broken
/// this way. Two of them failed SILENTLY while recording success: `ShadeOverlay`
/// stopped dimming, and `GammaController` parked its enforcer at a stale origin
/// with `lastAppliedScale` still saying the apply worked. The fix is not a
/// smarter lookup at each of them, and it is deliberately not an
/// `NSScreen`-shaped accessor on the
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
/// `drawableDisplayID` is the identity function — i.e. exactly the pre-seam
/// behaviour. An unwired engine therefore degrades to the status quo (a lookup
/// that fails and is REPORTED, DT17) rather than to a crash or a guess.
///
/// It has TWO writers in the app target, and they write the same kind of value
/// from the same source, so this is last-write-wins over two whole samples and
/// never a field at a time:
///
/// - `MirrorTopologySampler`, which samples at launch and on every
///   `didChangeScreenParameters`;
/// - `MirroringCoordinator`, whose `adoptTopology` republishes whatever it just
///   sampled. It cannot simply read this store instead: its hotkey entry point
///   samples LIVE, because a keypress must not depend on a notification having
///   already landed, and the sample it decided from is the one every drawable-ID
///   resolution should then be reading.
///
/// The staleness this leaves is ONE-DIRECTIONAL and the sampler's doc comment
/// states both halves; the half worth remembering here is that a sample lagging
/// a mirror BREAKING resolves to a real but WRONG display, which is the only
/// case in this design where a caller can succeed at the wrong thing.
public final class MirrorTopologyStore: MirrorTopologyProviding, Sendable {
  /// The published sample and the synthesis pairing it is stamped with, under
  /// ONE lock. Two locks would let an update read a master set a concurrent
  /// note had already replaced, which is the torn read this type exists to
  /// close one level down.
  private struct State {
    var topology: MirrorTopology
    var synthesisMasters: Set<CGDirectDisplayID>
  }

  private let stored: OSAllocatedUnfairLock<State>

  public init(_ topology: MirrorTopology = MirrorTopology([])) {
    stored = OSAllocatedUnfairLock(
      initialState: State(topology: topology, synthesisMasters: topology.synthesisMasters)
    )
  }

  /// Called at launch and on every screen-parameters change. ONE assignment of
  /// a whole sample, never a field at a time, so no reader ever sees a topology
  /// half-way between two machine states — the sampling hazard `MirrorTopology`
  /// exists to close would otherwise walk straight back in here.
  ///
  /// **The synthesis pairing is re-stamped here and the sample's own is
  /// ignored** (SS1). Both writers build their sample from
  /// `configurator.displays()`, and a CoreGraphics sample cannot tell a mirror
  /// set the app engaged to serve a synthesized size from one the user asked
  /// for. Stamping at the door rather than at each construction is what stops
  /// the hotkey's live sample (`MirroringCoordinator.adoptTopology`) from
  /// blanking the pairing until the next notification lands.
  public func update(_ topology: MirrorTopology) {
    stored.withLock { state in
      state.topology = MirrorTopology(
        topology.displays, synthesisMasters: state.synthesisMasters
      )
    }
  }

  /// The virtual displays a synthesized size is mirrored onto right now, from
  /// the engine's pairing table (SS1). Held here rather than passed at every
  /// `MirrorTopology(...)` because the app has two topology writers and neither
  /// can see the engine.
  public func noteSynthesisMasters(_ ids: Set<CGDirectDisplayID>) {
    stored.withLock { state in
      guard state.synthesisMasters != ids else { return }
      state.synthesisMasters = ids
      state.topology = MirrorTopology(state.topology.displays, synthesisMasters: ids)
    }
  }

  public func topology() -> MirrorTopology {
    stored.withLock { $0.topology }
  }

  public func drawableDisplayID(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    // Copied out first: the resolution is pure, and holding the lock across it
    // would serialise every drag-path read behind every other one.
    topology().drawableDisplayID(for: displayID)
  }
}
