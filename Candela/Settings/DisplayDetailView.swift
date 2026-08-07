import CandelaKit
import SwiftUI

/// One connected external display's settings destination: the hero, then the
/// hub (Task 13). A thin host on purpose — everything with a handler lives in
/// `DisplayHubView`, and the hero writes no pref at all.
///
/// Promoting displays to top-level sidebar destinations is what actually
/// separates this window from the fork's — and it retires the "Advanced"
/// disclosure, because a full window has room to simply show the controls.
///
/// `@MainActor` is load-bearing, not decoration: a plain `struct … : View` has
/// nonisolated stored and computed properties under Swift 6 complete
/// concurrency, and this one reads main-actor types.
@MainActor
struct DisplayDetailView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  @Environment(AppModel.self) private var model

  /// Accessibility contract 1, pop half: focus restores to the chevron row that
  /// pushed. Owned here — beside the `onChange` that watches the path — and
  /// carried into the hub, whose rows tag themselves with it.
  @FocusState private var focusedRow: DisplaySubPage?

  var body: some View {
    Form {
      DisplayHeroView(state: state)
      DisplayHubView(state: state, selection: $selection, path: $path, focusedRow: $focusedRow)
    }
    .formStyle(.grouped)
    // Mode enumeration is several CoreGraphics round-trips, so it runs here
    // rather than per body evaluation. It hangs off the Form, not off a
    // section: a modifier applied to a `Section` inside a grouped `Form` is not
    // reliably applied to the section itself (`listRowInsets` and
    // `listRowSeparator` are both measured no-ops there), and a lifecycle hook
    // that silently never fires would leave the resolution list empty.
    // Any LATER resolution change — ours, System Settings', or a replug —
    // re-enumerates through the coordinator's own screen-parameters observer,
    // which must run whether or not this pane is on screen: a display can
    // depart while the pane is being dismissed for exactly that reason, and its
    // outstanding preview still has to be dropped.
    .task(id: state.id) { model.displayModes.refreshCatalog(for: state.id) }
    // Pop restoration: the row that pushed the page just popped takes focus
    // back. Only ever a SHRINK is acted on — a push moves focus forward via
    // `SubPageHeader`'s own on-appear focus, and fighting it from here would
    // yank the cursor back to the hub mid-push.
    .onChange(of: path) { old, new in
      if new.count < old.count, let popped = old.last {
        focusedRow = popped
      }
    }
  }
}
