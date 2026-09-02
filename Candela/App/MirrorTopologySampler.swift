import AppKit
import CandelaKit

/// The one thing that writes to `MirrorTopologyStore`.
///
/// The store is the engine boundary: everything that needs a display
/// it can actually draw on asks the store, and the AppKit islands keep a
/// judgement-free `NSScreen` lookup. A store nobody updates holds the EMPTY
/// topology, whose `drawableDisplayID` is the identity function, so without this
/// type the seam resolves every ID to itself and fixes nothing.
///
/// **Why `didChangeScreenParameters` and not the debounced topology stream.**
/// The store answers "which display has an `NSScreen`", and AppKit posts this
/// notification around updating `NSScreen.screens` itself, so the store and the
/// list the islands search describe the same machine. `DisplayManager`'s stream
/// waits out a one-second quiet window, which is right for reapplying a
/// resolution to a settling display and a full second of wrongness here. The
/// stream refresh below is a backstop for a change that posts no notification.
///
/// **Sampled synchronously in the notification block, never after a hop.** The
/// hop's delay is unbounded (main-actor work can starve for a whole menu
/// tracking session) and a topology read on the far side describes a different
/// instant. Only `Sendable` values are captured, so nothing here touches a
/// main-actor object off the main actor.
///
/// **The staleness guarantee is ONE-DIRECTIONAL.** Lagging a mirror ENGAGING
/// degrades safely: the store still calls the new slave its own drawable
/// display, the `NSScreen` lookup fails, and the failure is reported rather than
/// faked. Lagging a mirror BREAKING does not: the store resolves the
/// ex-slave to its ex-master, that master IS in `NSScreen.screens`, and a dimming
/// path lands on a real but WRONG display while recording success. Accepted
/// because the window is the gap between the reconfiguration and its
/// notification, and no consumer takes an irreversible action inside it. It is
/// why this samples the raw notification rather than anything debounced.
///
/// **What this does NOT sample: the synthesis pairing.** CoreGraphics does
/// not report which mirror sets the app engaged to serve a synthesized size.
/// `SynthesisCoordinator` notes it on the store and `MirrorTopologyStore.update`
/// stamps every sample with it, deliberately there rather than here: this is not
/// the store's only writer, and a sample published elsewhere would blank the
/// pairing until the next notification.
@MainActor
final class MirrorTopologySampler {
  private let store: MirrorTopologyStore
  private let configurator: any DisplayConfiguring
  /// Held so the block-based registration stays alive. Never removed: this
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
  /// The launch sample matters on its own: the app can start with a mirror set
  /// already engaged, and until a notification lands the store would report every
  /// slave as its own drawable display.
  func start() {
    refresh()
    // A second `start()` would overwrite `observer` and leak the first
    // registration, leaving two blocks writing the store per notification.
    // Harmless today, and called exactly once, which is why the second caller
    // would be the one nobody reasons about.
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      // `nil`, not `.main`: the block runs synchronously at post time instead of
      // queueing behind whatever the main run loop is doing. AppKit posts on the
      // main thread either way, so the queueing is what is avoided, not the hop.
      queue: nil
    ) { [store, configurator] _ in
      store.update(MirrorTopology(configurator.displays()))
    }
  }

  /// Re-samples on demand. One `CGGetOnlineDisplayList` plus a few per-display
  /// calls, cheap enough to run from the debounced topology loop too.
  func refresh() {
    store.update(MirrorTopology(configurator.displays()))
  }
}
