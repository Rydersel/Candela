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
  @ObservationIgnored var performReset: () -> Void = {} // wired in Task 8
  @ObservationIgnored var postReset: () -> Void = {} // wired in Task 8
  @ObservationIgnored var showOnboarding: () -> Void = {} // wired in Task 15
  @ObservationIgnored private weak var model: AppModel?

  init(model: AppModel) {
    self.model = model
  }

  /// Call after EVERY pref write. `persistenceKey` scopes the dimming
  /// re-apply to one display; nil (app-level prefs) re-applies every external.
  func prefDidChange(_ name: PrefName, persistenceKey: String? = nil) {
    apply(PrefPropagation.effects(forChange: name), persistenceKey: persistenceKey)
  }

  /// One fan-out for a batch write (the per-display reset). The union is NOT
  /// any single member's row — resetting a display writes `hideDisplay`, which
  /// carries `.updateStatusItem` that `forceSw` does not — so a batch must
  /// never be collapsed onto one representative name.
  func prefsDidChange(_ names: [PrefName], persistenceKey: String? = nil) {
    apply(PrefPropagation.effects(forChanges: names), persistenceKey: persistenceKey)
  }

  private func apply(_ effects: Set<PrefEffect>, persistenceKey: String?) {
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
  }
}
