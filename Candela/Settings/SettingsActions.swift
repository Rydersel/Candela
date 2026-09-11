import CandelaKit
import Foundation
import Observation

/// A checkup's failed restore, with the display it happened to. The sentence
/// says "the display" and names none, and the pane is scoped to one display at
/// a time, so the key travels with the text.
struct CheckupRestoreNotice: Equatable {
  let text: String
  /// The persistence key of the display the run moved.
  let identityKey: String
}

/// App-side fan-out for the propagation seam. `StatusItemController`
/// wires the closures; the Settings scene environment carries it so every pane
/// writes through ONE door.
///
/// `@MainActor`, so every `View` that stores or constructs one must be
/// `@MainActor` too: a `View`'s properties other than `body` are nonisolated,
/// and the target builds with `SWIFT_STRICT_CONCURRENCY: complete`.
@MainActor @Observable
final class SettingsActions {
  @ObservationIgnored var rearmTap: () -> Void = {}
  @ObservationIgnored var updateStatusItem: () -> Void = {}
  @ObservationIgnored var recheckPermissions: () -> Void = {}
  @ObservationIgnored var performReset: () -> Void = {}
  @ObservationIgnored var postReset: () -> Void = {}
  @ObservationIgnored var showOnboarding: () -> Void = {}
  /// Opens or re-focuses a display's health window, keyed by
  /// persistence key. A closure because the window is an AppKit island the
  /// views cannot see.
  @ObservationIgnored var openDisplayHealth: (String) -> Void = { _ in }
  /// Opens or re-focuses the checkup window, an AppKit island. No
  /// argument: the flow picks its own target.
  @ObservationIgnored var openCheckup: () -> Void = {}
  /// Cross-pane navigation. A pane changes the sidebar selection
  /// through this, never by owning selection state of its own. The default is a
  /// no-op so a view rendered outside the shell navigates nowhere rather than
  /// crashing.
  @ObservationIgnored var reveal: (SettingsDestination) -> Void = { _ in }
  /// One-shot handoff for the cross-links that promise a display: set
  /// just before `reveal(.pane(.health))`, adopted by the Health pane's
  /// switcher on appearance, cleared on adoption. Nil keeps the pane's scope.
  ///
  /// Not folded into `reveal`'s argument: `.pane(.health)` names a pane, not a
  /// display, and the scope belongs to the link. Without it the Health row
  /// lands on whichever external sorts first and every write below the switcher
  /// names the wrong monitor while the row promised "this display".
  ///
  /// `@ObservationIgnored` on purpose. Nothing observes it: the only writer is
  /// another pane's cross-link, so Health is never on screen when it is set and
  /// a fresh appearance always reads it.
  @ObservationIgnored var pendingHealthScope: String?
  /// A checkup ended early and left its display off the mode it started in.
  /// Published here, not on the run's flow model: both early-exit routes close
  /// the run's window before the restore answers, and this object outlives it.
  ///
  /// Observed, unlike `pendingHealthScope`: the settings window can already be
  /// open behind the run, so the pane has to redraw when this lands.
  var checkupRestoreFailure: CheckupRestoreNotice?
  /// Which run the standing notice belongs to. A restore answers after its own
  /// window has gone, so an earlier run's answer can arrive during a later one.
  @ObservationIgnored private var checkupRunGeneration = 0
  @ObservationIgnored private weak var model: AppModel?

  init(model: AppModel) {
    self.model = model
  }

  /// Clears whatever the last run left and hands back the token this run's
  /// restore has to present. Called as a run is wired.
  func beginCheckupRun() -> Int {
    checkupRunGeneration += 1
    checkupRestoreFailure = nil
    return checkupRunGeneration
  }

  /// Ignores an answer from a superseded run: a late one would put a notice back
  /// on a display the newer run has since restored cleanly.
  func publishCheckupRestoreFailure(_ notice: CheckupRestoreNotice, generation: Int) {
    guard generation == checkupRunGeneration else { return }
    checkupRestoreFailure = notice
  }

  /// Call after EVERY pref write. `persistenceKey` scopes the dimming re-apply
  /// to one display; nil re-applies every external. `virtualSlot` scopes
  /// virtual-display convergence the same way, so one slot's Create cannot
  /// recreate another slot's unapplied edits.
  func prefDidChange(_ name: PrefName, persistenceKey: String? = nil, virtualSlot: Int? = nil) {
    apply(
      PrefPropagation.effects(forChange: name),
      persistenceKey: persistenceKey, virtualSlot: virtualSlot
    )
  }

  /// One fan-out for a batch write. The union is NOT any single member's row
  /// (`hideDisplay` carries `.updateStatusItem`, `forceSw` does not), so never
  /// collapse a batch onto one representative name.
  func prefsDidChange(_ names: [PrefName], persistenceKey: String? = nil, virtualSlot: Int? = nil) {
    apply(
      PrefPropagation.effects(forChanges: names),
      persistenceKey: persistenceKey, virtualSlot: virtualSlot
    )
  }

  private func apply(_ effects: Set<PrefEffect>, persistenceKey: String?, virtualSlot: Int? = nil) {
    if effects.contains(.rearmTap) { rearmTap() }
    if effects.contains(.updateStatusItem) { updateStatusItem() }
    if effects.contains(.recheckPermissions) { recheckPermissions() }
    // One mechanism here: `prefsRevision` invalidates the panes and the panel
    // alike. They stay separate in the table because `.rebuildPanel` records
    // that the menu-bar panel's rendering changes too.
    if effects.contains(.refreshUI) || effects.contains(.rebuildPanel) {
      model?.notePrefsChanged()
    }
    if effects.contains(.reapplyDimming), let model {
      // reapplyAfterPrefChange, never handleReconfigure and never
      // setBrightness(sameValue). The first re-runs only the software leg and
      // no-ops in pure-DDC mode; the second is memo-suppressed. This re-writes
      // BOTH legs at the SAME published value (the no-slam rule) and tears
      // down any abandoned software backend.
      for state in model.displays where persistenceKey == nil
        || state.display.persistenceKey == persistenceKey {
        state.controller.reapplyAfterPrefChange()
      }
    }
    if effects.contains(.reapplyOledCare), let model {
      // Separate from `.reapplyDimming`: OLED care re-arms its own timers and
      // must not put the DDC bus to work on every timeout tweak.
      model.oledCare.reapplyAfterPrefChange(persistenceKey: persistenceKey)
    }
    if effects.contains(.restartBrightnessPoll) { model?.notePollConsumerAppeared() }
    if effects.contains(.syncVirtualDisplays) {
      // Converge live virtual displays to the slot prefs. The model hops
      // off the main actor itself; nothing here blocks.
      model?.syncVirtualDisplays(slot: virtualSlot)
    }
  }
}

/// Mutate the pref, then fan out through the propagation seam. The engine
/// reads prefs
/// at construction and at key time, not reactively, so a write that does not
/// propagate is a broken control. The two steps are not separable here on
/// purpose.
@MainActor
struct DisplayPrefWriter {
  let persistenceKey: String
  let actions: SettingsActions
  let prefs: DisplayPrefs

  init(persistenceKey: String, actions: SettingsActions) {
    self.persistenceKey = persistenceKey
    self.actions = actions
    self.prefs = DisplayPrefs(persistenceKey: persistenceKey)
  }

  /// `name` is the UNSUFFIXED pref name the propagation table keys on
  /// (`.forceSw`, never `"forceSw.<pk>"`). That naming rule closed this name
  /// space because
  /// the old `String` form made `write("forceSW")` a silent no-op: it wrote the
  /// pref and fanned out to nothing.
  func write(_ name: PrefName, _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefDidChange(name, persistenceKey: persistenceKey)
  }

  /// Fans out to the UNION of the names' rows. Never collapse a batch onto one
  /// representative name: the rows are not nested, so a "superset" row silently
  /// drops effects.
  func writeAll(_ names: [PrefName], _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefsDidChange(names, persistenceKey: persistenceKey)
  }
}
