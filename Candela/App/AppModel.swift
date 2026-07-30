import CandelaKit
import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  struct DisplayState: Identifiable {
    let display: ExternalDisplay
    let controller: BrightnessController
    var id: CGDirectDisplayID { display.id }
  }

  private(set) var displays: [DisplayState] = []

  /// Epoch authority for reconfiguration/sleep/wake. Owned here so refresh
  /// can wire every controller's epoch pair; StatusItemController activates
  /// it and consumes its topology stream.
  let displayManager = DisplayManager()

  /// Accessibility grant state, owned here so the panel banner observes it
  /// through the model already in the SwiftUI environment (and clears live
  /// when the grant appears while the panel is open).
  let accessibility = AccessibilityPermission()

  var accessibilityGranted: Bool { accessibility.isGranted }

  func stepBrightnessAllExternal(isUp: Bool, isFine: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    displays.map { state in
      (state.id, state.display.name, state.controller.step(isUp: isUp, isFine: isFine))
    }
  }

  /// Watch brightness keys only when an external display is present (fork:
  /// updateMediaKeyTap's disengage rule). Volume keys arrive with Milestone 4.
  var tapConfig: MediaKeyEventTap.WatchConfig {
    .init(
      watchedKeys: displays.isEmpty ? [] : [.brightnessUp, .brightnessDown],
      interceptAlternateBrightnessKeys: !UserDefaults.standard.bool(forKey: "disableAltBrightnessKeys")
    )
  }

  /// The in-flight refresh, if any. Overlapping callers piggyback on it
  /// instead of starting a second pass: each pass runs discovery, and two
  /// concurrent passes would each hold a *different* DDC-service actor for
  /// the same IOAVService, letting their I2C transactions interleave on the
  /// wire (e.g. a discarded coalescer's tail-write racing a fresh read).
  @ObservationIgnored private var refreshTask: Task<[CGDirectDisplayID], Never>?

  /// Returns the IDs of displays that departed in this pass (for HUD panel
  /// cleanup). A piggybacked caller — one that joined an already-running
  /// pass — gets `[]`, not that pass's result: only the caller that started
  /// the pass sees its departures. `@discardableResult` keeps the two bare
  /// launch/menu-close call sites warning-free.
  @discardableResult
  func refresh() async -> [CGDirectDisplayID] {
    if let refreshTask {
      _ = await refreshTask.value
      return []
    }
    let task = Task { await performRefresh() }
    refreshTask = task
    let departed = await task.value
    refreshTask = nil
    return departed
  }

  /// Reconciles `displays` against discovery, keyed by `CGDirectDisplayID`:
  /// still-present displays keep their existing `BrightnessController` (and
  /// its writer/coalescer), so controller identity is stable across refreshes
  /// and long-lived references (Milestone 2 media keys) never go stale —
  /// but they are rebound to the writer discovery just created (a replug can
  /// hand out a fresh IOAVService; keeping the old one risks writing into a
  /// stale service, and rebind also resets the coalescer's duplicate memo,
  /// review I10). Only newly appeared displays get a fresh controller.
  /// Departed displays are dropped and their IDs returned — the controller's
  /// deinit finishes its coalescer, which lands any pending write before the
  /// drain task exits, so no explicit `waitForPendingWrites()` is needed.
  private func performRefresh() async -> [CGDirectDisplayID] {
    var existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.controller) })
    var appeared: [BrightnessController] = []
    var kept: [BrightnessController] = []
    displays = DisplayDiscovery.discover().map { entry in
      if let controller = existing.removeValue(forKey: entry.display.id) {
        kept.append(controller)
        // Fresh DisplayState (name may change), reused controller, fresh writer.
        controller.rebind(writer: entry.writer)
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
    // Every controller — kept and appeared — gets the live epoch pair, so
    // each submit is stamped with the current epoch and the drain refuses
    // targets stamped before a reconfiguration/sleep.
    for state in displays {
      state.controller.setEpochProvider(
        { [displayManager] in displayManager.currentEpoch() },
        isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
      )
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
    return Array(existing.keys)
  }
}
