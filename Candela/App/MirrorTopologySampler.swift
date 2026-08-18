import AppKit
import CandelaKit

/// The one thing that writes to `MirrorTopologyStore`.
///
/// The store is the engine boundary (DT15/DT16): every consumer that needs a
/// display it can actually draw on asks it, once, and the AppKit islands keep
/// their one-line `NSScreen.screens.first { $0.displayID == id }` lookup with no
/// judgement in it. But a store nobody updates holds the EMPTY topology, whose
/// `drawableDisplayID` is the identity function — so without this type the whole
/// seam resolves every ID to itself and fixes precisely nothing. It is not
/// optional plumbing; it is the half of the boundary that makes the other half
/// true.
///
/// **Why `didChangeScreenParameters` and not the debounced topology stream.**
/// The question the store answers is "which display has an `NSScreen`", and
/// this notification is the one AppKit posts around updating `NSScreen.screens`
/// itself. Sampling here keeps the store and the list the islands look IDs up in
/// describing the same machine. `DisplayManager`'s stream deliberately waits out
/// a one-second quiet window before reporting — right for reapplying a
/// resolution to a display that is still settling, and a full second of
/// wrongness for this. The stream refresh below is a backstop for a change that
/// somehow posts no notification, not the primary trigger.
///
/// **Sampled synchronously in the notification block, never after a hop.** Same
/// rule `DisplayModeCoordinator`'s observer follows and for the same reason: the
/// hop's delay is unbounded (this codebase documents main-actor work being
/// starved for the whole of a menu tracking session), and a topology read on the
/// far side of one describes a different instant than the notification did. Only
/// `Sendable` values are captured — the store is lock-backed and the
/// configurator is a stateless struct — so nothing here touches a main-actor
/// object off the main actor.
///
/// **The staleness guarantee is ONE-DIRECTIONAL, and the safe half is not the
/// interesting one.** Lagging a mirror ENGAGING degrades safely: the store still
/// calls the new slave its own drawable display, the `NSScreen` lookup fails,
/// and the failure is reported rather than faked (DT17). Lagging a mirror
/// BREAKING does not: the store still resolves the ex-slave to its ex-master,
/// that master IS in `NSScreen.screens`, and a dimming path therefore lands on a
/// real but WRONG display while recording success — the silent-success shape
/// this sub-project exists to close, reproduced one layer up. Judged acceptable
/// because the window is the gap between the reconfiguration and its
/// notification, it closes on that notification, and no consumer takes an
/// irreversible action inside it. It is the reason this samples the raw
/// notification rather than anything debounced.
///
/// **What this does NOT sample: the synthesis pairing (SS1).** Which mirror
/// sets the app engaged to serve a synthesized size is not something
/// CoreGraphics reports, so it cannot be read here. `SynthesisCoordinator`
/// notes it on the store instead, and `MirrorTopologyStore.update` stamps every
/// sample with it. That placement is deliberate rather than incidental: this is
/// not the store's only writer, and a sample published from anywhere else would
/// otherwise blank the pairing until the next notification landed.
@MainActor
final class MirrorTopologySampler {
  private let store: MirrorTopologyStore
  private let configurator: any DisplayConfiguring
  /// Held so the block-based registration stays alive. Never removed — this
  /// object lives as long as the app, like the sleep/wake observers.
  private var observer: (any NSObjectProtocol)?

  init(
    store: MirrorTopologyStore,
    configurator: any DisplayConfiguring = CoreGraphicsDisplayConfigurator()
  ) {
    self.store = store
    self.configurator = configurator
  }

  /// Takes the launch sample and starts following screen-parameters changes.
  ///
  /// The launch sample matters on its own: the app can perfectly well start with
  /// a mirror set already engaged, and until something posts a notification the
  /// store would otherwise report every slave as its own drawable display.
  func start() {
    refresh()
    // Insurance, one line: a second `start()` would otherwise overwrite
    // `observer` and leak the first registration, leaving two blocks writing the
    // store on every notification. Harmless today — the blocks capture only
    // `Sendable` values and write the same whole sample — and called exactly
    // once, which is precisely why the second caller would be the one nobody
    // reasons about.
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      // `nil`, not `.main`: the block then runs synchronously at post time
      // rather than being enqueued behind whatever the main run loop is doing.
      // AppKit posts this on the main thread, so this is the same thread either
      // way — it is the queueing that is being avoided, not the thread.
      queue: nil
    ) { [store, configurator] _ in
      store.update(MirrorTopology(configurator.displays()))
    }
  }

  /// Re-samples on demand. One `CGGetOnlineDisplayList` plus a few per-display
  /// calls, so it is cheap enough to run from the debounced topology loop as
  /// well; a fresher sample is never worse than the one it replaces.
  func refresh() {
    store.update(MirrorTopology(configurator.displays()))
  }
}
