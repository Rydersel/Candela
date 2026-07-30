import CandelaKit
import CoreGraphics
import Observation

@MainActor @Observable
final class AppModel {
  struct DisplayState: Identifiable {
    let display: ExternalDisplay
    let controller: BrightnessController
    var id: CGDirectDisplayID { display.id }
  }

  private(set) var displays: [DisplayState] = []

  /// The in-flight refresh, if any. Overlapping callers piggyback on it
  /// instead of starting a second pass: each pass runs discovery, and two
  /// concurrent passes would each hold a *different* DDC-service actor for
  /// the same IOAVService, letting their I2C transactions interleave on the
  /// wire (e.g. a discarded coalescer's tail-write racing a fresh read).
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  func refresh() async {
    if let refreshTask {
      await refreshTask.value
      return
    }
    let task = Task { await performRefresh() }
    refreshTask = task
    await task.value
    refreshTask = nil
  }

  /// Reconciles `displays` against discovery, keyed by `CGDirectDisplayID`:
  /// still-present displays keep their existing `BrightnessController` (and
  /// its writer/coalescer), so controller identity is stable across refreshes
  /// and long-lived references (Milestone 2 media keys) never go stale. Only
  /// newly appeared displays get a fresh controller. Departed displays are
  /// simply dropped — the controller's deinit finishes its coalescer, which
  /// lands any pending write before the drain task exits, so no explicit
  /// `waitForPendingWrites()` is needed for them.
  private func performRefresh() async {
    var existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.controller) })
    var appeared: [BrightnessController] = []
    var kept: [BrightnessController] = []
    displays = DisplayDiscovery.discover().map { entry in
      if let controller = existing.removeValue(forKey: entry.display.id) {
        kept.append(controller)
        // Fresh DisplayState (name may change), reused controller. The
        // writer discovery just created for this display is discarded unused.
        return DisplayState(display: entry.display, controller: controller)
      }
      let controller = BrightnessController(
        writer: entry.writer,
        store: UserDefaultsBrightnessStore(),
        storageKey: "brightness.\(entry.display.persistenceKey)"
      )
      appeared.append(controller)
      return DisplayState(display: entry.display, controller: controller)
    }
    for controller in appeared {
      await controller.refreshFromHardware()
    }
    for controller in kept {
      // Let any coalesced tail-write land before reading back, then resync
      // from hardware. Harmless no-op on write-only panels (MAG341C): the
      // read fails its guard and the last-written state stands.
      await controller.waitForPendingWrites()
      await controller.refreshFromHardware()
    }
  }
}
