import CandelaKit
import Foundation
import Observation

/// App-side fan-out for the propagation seam (D20). Owned by
/// StatusItemController (which wires the closures — refreshTapConfig stays
/// private there); injected into the Settings scene environment so every
/// pane writes through ONE door.
///
/// This type is `@MainActor`, so every `View` that stores or constructs one
/// must itself be declared `@MainActor` — a `View`'s stored and computed
/// properties (anything but `body`) are nonisolated, and the target builds
/// with `SWIFT_STRICT_CONCURRENCY: complete`.
@MainActor @Observable
final class SettingsActions {
  @ObservationIgnored var rearmTap: () -> Void = {}
  @ObservationIgnored var updateStatusItem: () -> Void = {}
  @ObservationIgnored var recheckPermissions: () -> Void = {}
  @ObservationIgnored var performReset: () -> Void = {}
  @ObservationIgnored var postReset: () -> Void = {}
  @ObservationIgnored var showOnboarding: () -> Void = {}
  /// Opens (or re-focuses) a display's Display Health window (OCR-A1, #185).
  /// A closure for the same reason as `showOnboarding`: the windows are an
  /// AppKit island the views cannot see, wired by `StatusItemController` at
  /// launch. The argument is the display's persistence key.
  @ObservationIgnored var openDisplayHealth: (String) -> Void = { _ in }
  /// Cross-pane navigation for the care cross-links (SC4, SC6): a pane that
  /// points at another destination (OLED Care to Health, Protection to a
  /// display's page) changes the sidebar selection through this, never by
  /// owning selection state of its own. Wired by `SettingsRootView`, which is
  /// where the selection lives; the default is a no-op so a view rendered
  /// outside the shell (tests, previews) navigates nowhere rather than
  /// crashing.
  @ObservationIgnored var reveal: (SettingsDestination) -> Void = { _ in }
  @ObservationIgnored private weak var model: AppModel?

  init(model: AppModel) {
    self.model = model
  }

  /// Call after EVERY pref write. `persistenceKey` scopes the dimming
  /// re-apply to one display; nil (app-level prefs) re-applies every external.
  /// `virtualSlot` scopes the virtual-display convergence the same way: the
  /// pane passes the slot whose `configured` it wrote, so one slot's Create
  /// can never recreate another slot's drifted-but-unapplied edits (VD17).
  func prefDidChange(_ name: PrefName, persistenceKey: String? = nil, virtualSlot: Int? = nil) {
    apply(
      PrefPropagation.effects(forChange: name),
      persistenceKey: persistenceKey, virtualSlot: virtualSlot
    )
  }

  /// One fan-out for a batch write (the per-display reset). The union is NOT
  /// any single member's row — resetting a display writes `hideDisplay`, which
  /// carries `.updateStatusItem` that `forceSw` does not — so a batch must
  /// never be collapsed onto one representative name.
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
    // `.refreshUI` and `.rebuildPanel` are one mechanism in the app —
    // `prefsRevision` invalidates the panes and the panel alike. They stay
    // separate in the table because `.rebuildPanel` documents "this also
    // changes what the menu-bar panel renders", which the completeness
    // invariant on `.refreshUI` deliberately does not.
    if effects.contains(.refreshUI) || effects.contains(.rebuildPanel) {
      model?.notePrefsChanged()
    }
    if effects.contains(.reapplyDimming), let model {
      // D28: reapplyAfterPrefChange, never handleReconfigure and never
      // setBrightness(sameValue) — the first re-runs only the software leg
      // and no-ops in pure-DDC mode, the second is memo-suppressed. This
      // re-writes BOTH legs at the SAME published value (D4's no-slam rule)
      // and tears down any abandoned software backend.
      for state in model.displays where persistenceKey == nil
        || state.display.persistenceKey == persistenceKey {
        state.controller.reapplyAfterPrefChange()
      }
    }
    if effects.contains(.reapplyOledCare), let model {
      // Separate from `.reapplyDimming` on purpose: OLED care re-arms its own
      // timers and re-evaluates its own dim leg, and must not put the DDC bus
      // to work on every timeout tweak.
      model.oledCare.reapplyAfterPrefChange(persistenceKey: persistenceKey)
    }
    if effects.contains(.syncVirtualDisplays) {
      // VD14: converge live virtual displays to the slot prefs, scoped to
      // the written slot when the caller named one. The model hops off the
      // main actor itself; nothing here blocks.
      model?.syncVirtualDisplays(slot: virtualSlot)
    }
  }
}

/// Every Displays-pane write goes through here: mutate the pref, then fan out
/// through the D20 seam. A control that writes a pref and does not propagate is
/// a broken control (the engine reads prefs at construction and at key time,
/// not reactively), so the two steps are deliberately not separable at the
/// call site.
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

  /// `name` is a `PrefName` case, i.e. the UNSUFFIXED pref name the propagation
  /// table keys on (`.forceSw`, never `"forceSw.<pk>"`). D27 closed this name
  /// space precisely because the old `String` form made `write("forceSW")` a
  /// silent no-op that wrote the pref and fanned out to nothing. The
  /// persistence key scopes the dimming re-apply to this display alone.
  func write(_ name: PrefName, _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefDidChange(name, persistenceKey: persistenceKey)
  }

  /// A batch: several prefs written together, fanning out to the UNION of
  /// their rows. Never collapse a batch onto one representative name — the
  /// rows are not nested (`hideDisplay` carries `.updateStatusItem`,
  /// `forceSw` does not), so picking a "superset" row silently drops effects.
  func writeAll(_ names: [PrefName], _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefsDidChange(names, persistenceKey: persistenceKey)
  }
}
