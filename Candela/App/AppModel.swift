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

  /// The built-in panel, in its own slot — deliberately NOT inside `displays`
  /// (re-review T10-A): `stepBrightnessAllExternal`, `tapConfig`, and the
  /// panel's external iteration all walk `displays` and must stay
  /// external-only, because plain brightness key presses must never step the
  /// MacBook panel (fork rule; the built-in is driven by macOS's own keys or
  /// Ctrl-directed steps). `DisplayState.display` reuses `ExternalDisplay` as
  /// a plain id/name/persistenceKey value carrier despite the name — renaming
  /// the struct is M4 cleanup.
  private(set) var builtIn: DisplayState?

  /// Epoch authority for reconfiguration/sleep/wake. Owned here so refresh
  /// can wire every controller's epoch pair; StatusItemController activates
  /// it and consumes its topology stream.
  let displayManager = DisplayManager()

  /// One HDR service shared by every display's controller (MPDisplayMgr
  /// enumeration + its 2 s state cache live behind one actor).
  let hdrToggling: any HDRToggling

  /// Software-dimming islands (AppKit lives in the app target behind
  /// CandelaKit protocols). Constructed by StatusItemController and injected
  /// here — implementer's choice per the Task 6 brief, so tests can hand the
  /// model fakes (or nil for "feature degraded").
  @ObservationIgnored private let shade: (any ShadeRendering)?
  @ObservationIgnored private let gamma: (any GammaApplying)?

  /// Accessibility grant state, owned here so the panel banner observes it
  /// through the model already in the SwiftUI environment (and clears live
  /// when the grant appears while the panel is open).
  let accessibility = AccessibilityPermission()

  var accessibilityGranted: Bool { accessibility.isGranted }

  init(
    shade: (any ShadeRendering)? = nil,
    gamma: (any GammaApplying)? = nil,
    hdrToggling: (any HDRToggling)? = nil
  ) {
    self.shade = shade
    self.gamma = gamma
    self.hdrToggling = hdrToggling ?? MonitorPanelService()
  }

  func stepBrightnessAllExternal(isUp: Bool, isFine: Bool, isFresh: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    displays.map { state in
      (state.id, state.display.name, state.controller.step(isUp: isUp, isFine: isFine, isFresh: isFresh))
    }
  }

  /// Steps the built-in panel (Ctrl-directed keys only — plain presses target
  /// externals). Returns nil when no built-in display is online.
  func stepBrightnessBuiltIn(isUp: Bool, isFine: Bool, isFresh: Bool) -> (id: CGDirectDisplayID, name: String, newValue: Double)? {
    guard let builtIn else { return nil }
    return (builtIn.id, builtIn.display.name,
            builtIn.controller.step(isUp: isUp, isFine: isFine, isFresh: isFresh))
  }

  /// Watch brightness keys only when an EXTERNAL display is present (fork:
  /// updateMediaKeyTap's disengage rule) — with only the built-in, macOS
  /// handles its own keys. Volume keys arrive with Milestone 4.
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

  /// The CC-sync poll job. Cancelled and recreated after every refresh: its
  /// targets capture a fixed controller set, so a departed display's target
  /// must never outlive the pass that dropped it.
  @ObservationIgnored private var pollerTask: Task<Void, Never>?

  deinit {
    pollerTask?.cancel()
  }

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
      let persistenceKey = entry.display.persistenceKey
      let controller = BrightnessController(
        writer: entry.writer,
        backends: BrightnessBackends(
          // T3 handoff: the applier's closure runs inside the coalescer's
          // single drain, which already serializes per display — pass the
          // shim directly, no extra queue.
          applierNative: NativeBrightnessApplier(
            displayID: entry.display.id, apply: DisplayServices.setBrightness
          ),
          hdr: hdrToggling,
          shade: shade,
          gamma: gamma
        ),
        prefs: DisplayPrefs(persistenceKey: persistenceKey),
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(),
        // M3 key; the M2 key is read once for migration, then ignored.
        storageKey: "combinedBrightness.\(persistenceKey)",
        legacyKey: "brightness.\(persistenceKey)"
      )
      appeared.append(controller)
      return DisplayState(display: entry.display, controller: controller)
    }
    refreshBuiltIn()
    // Every controller — kept and appeared — gets the live epoch pair, so
    // each submit is stamped with the current epoch and the drain refuses
    // targets stamped before a reconfiguration/sleep.
    for state in displays {
      state.controller.setEpochProvider(
        { [displayManager] in displayManager.currentEpoch() },
        isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
      )
    }
    builtIn?.controller.setEpochProvider(
      { [displayManager] in displayManager.currentEpoch() },
      isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
    )
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
    // Resync the built-in from its native read (cheap; a freshly created
    // controller already seeded from the same read at init).
    await builtIn?.controller.refreshFromHardware()
    restartPoller()
    return Array(existing.keys)
  }

  /// Reconciles the built-in slot against discovery. Same identity rule as
  /// externals: a still-present built-in keeps its controller (fresh
  /// DisplayState for the name); no writer rebind — there is no DDC wire, the
  /// writer is a permanent `NoopDDCWriter`.
  private func refreshBuiltIn() {
    guard let found = BuiltInDisplayDiscovery.discover() else {
      builtIn = nil
      return
    }
    let display = ExternalDisplay(id: found.id, name: found.name, persistenceKey: "builtIn")
    if let existing = builtIn, existing.id == found.id {
      builtIn = DisplayState(display: display, controller: existing.controller)
      return
    }
    let controller = BrightnessController(
      writer: NoopDDCWriter(), // no DDC wire; always-fails stub (re-review T10-D)
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(
          displayID: found.id, apply: DisplayServices.setBrightness
        ),
        // No HDR/shade/gamma backends: role .builtIn never routes HDR or the
        // software leg, and `handleReconfigure` correctly no-ops on nils.
        hdr: nil,
        shade: nil,
        gamma: nil,
        readNative: DisplayServices.getBrightness(for:)
      ),
      prefs: DisplayPrefs(persistenceKey: "builtIn"), // role .builtIn ignores prefs
      displayID: found.id,
      role: .builtIn
      // store/storageKey/legacyKey stay nil (re-review T10-E): macOS owns
      // built-in brightness across launches; the controller seeds from a
      // native read at init.
    )
    builtIn = DisplayState(display: display, controller: controller)
  }

  /// Rebuilds the native-brightness poll job for the current display set
  /// (spec §5 CC-sync: Control Center and ambient changes bypass us entirely,
  /// so the only way to stay in sync on the native path is to look).
  private func restartPoller() {
    pollerTask?.cancel()
    guard !displays.isEmpty || builtIn != nil else {
      pollerTask = nil
      return
    }
    // Built-in first: its `isNativeActive()` is constitutively true for role
    // .builtIn, so CC-sync polls the MacBook panel from the very first tick.
    let states = (builtIn.map { [$0] } ?? []) + displays
    let targets = states.map { state -> BrightnessPoller.Target in
      let controller = state.controller
      return BrightnessPoller.Target(
        displayID: state.id,
        expected: { controller.expectedNative() },
        isNativeActive: { controller.isNativeActive() },
        // A starved adoption Task that fires late is discarded by
        // adoptExternal's generation check (review I9).
        // Parked T6-minor-2: after an HDR settle the expected-native slot and
        // the hardware can briefly disagree. The poller does NOT recover the
        // interim input — it CONVERGES PUBLISHED STATE ONTO THE RE-ASSERTED
        // value, i.e. anything the user typed inside the settle window is
        // ratified over, not restored. Confirm against hardware verification
        // item 7 before deciding whether that is acceptable.
        adopt: { [weak self] value, generation in
          Task { @MainActor in
            let delta = controller.adoptExternal(value, generation: generation)
            guard let self else { return }
            // Display set read at fan-out time, not at target-build time: a
            // refresh between ticks must not replicate onto a departed
            // controller. The built-in is added explicitly — it lives in its
            // own slot, outside `displays` (re-review T10-A).
            BrightnessSync.fanOut(
              delta: delta,
              from: controller,
              to: self.displays.map(\.controller) + [self.builtIn?.controller].compactMap { $0 },
              isEnabled: UserDefaults.standard.bool(forKey: "enableBrightnessSync")
            )
          }
        },
        isConverging: { controller.isConvergingFromExternal() }
      )
    }
    let poller = BrightnessPoller(
      targets: targets,
      read: { id in DisplayServices.getBrightness(for: id).map(Double.init) },
      // Current-epoch-against-itself is false exactly while the manager is
      // suspended (mid-reconfigure burst or asleep) — the poller's skip rule.
      isEpochCurrent: { [displayManager] in
        displayManager.isEpochCurrent(displayManager.currentEpoch())
      }
    )
    pollerTask = Task { await poller.run() }
  }
}
