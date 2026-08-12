import CandelaKit
import CoreGraphics
import SwiftUI

/// Where the displays are, and where they should be.
///
/// A top-level destination rather than a section in `DisplayDetailView`, because
/// an arrangement is a property of the display **set**, not of one display:
/// there is no display whose pane it belongs in. That is one `PaneID` case, one
/// `SettingsRegistry` row and one view file — the shape the settings redesign was
/// built for.
///
/// The pane **exists with one display too**, showing the single tile and a
/// caption. A pane that appeared and disappeared as hardware came and went is
/// the failure R16 already ruled against for the built-in row.
///
/// `@MainActor` because a `View`'s stored and computed properties other than
/// `body` are nonisolated under complete concurrency checking, and this one
/// stores main-actor types.
@MainActor
struct ArrangementPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Reconciled against the live layout on every read rather than seeded once —
  /// displays come and go while this pane is open, and a selection naming a
  /// display that has departed would leave "Use as Main Display" live over a
  /// display that is not there.
  @State private var selection: CGDirectDisplayID?

  /// AR7: why the last drop was refused. Held here rather than in the canvas
  /// because it is the SECTION that says it — a red border communicates "no"
  /// and nothing else, and colour is never allowed to be the only signal.
  @State private var refusal: [ArrangementProblem] = []
  /// Bumped on every refusal so an identical second refusal restarts the timer
  /// rather than inheriting the tail of the first one's.
  @State private var refusalToken = 0

  private var coordinator: ArrangementCoordinator { model.arrangement }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, and every tile is
    // NAMED through it (`PanelView.title(for:)` resolves `friendlyName`). Without
    // this read, renaming a display elsewhere in the window would leave the old
    // name standing on the map. The coordinator itself is `@Observable` and
    // needs no help.
    let _ = model.prefsRevision
    Form {
      arrangementSection
      savedLayoutSection
    }
    .formStyle(.grouped)
    .task(id: refusalToken) {
      guard !refusal.isEmpty else { return }
      // Long enough to read a sentence, short enough that it does not outlive
      // the state it describes. Cancelled and restarted by `id:` on the next
      // refusal, and cancelled outright when the pane goes away.
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      refusal = []
    }
  }

  // MARK: - The section

  /// Headerless on purpose. The pane's toolbar title already reads
  /// "Arrangement", and a section header repeating it word for word is the
  /// duplicated-title defect the settings redesign shipped once and had to be
  /// looked at to catch — a structural check cannot see two identical words at
  /// two altitudes. The pane has one group, so the header carried no
  /// information beyond the repetition.
  private var arrangementSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        ArrangementCanvasView(
          arrangement: coordinator.arrangement,
          name: coordinator.displayName,
          selection: reconciledSelection,
          onPropose: { coordinator.apply($0) },
          onRefuse: { problems in
            refusal = problems
            refusalToken &+= 1
          }
        )
        .frame(maxWidth: .infinity, alignment: .center)

        if coordinator.arrangement.tiles.count < 2 {
          // No button at all, rather than a permanently dead one: with one
          // display there is nothing to choose between, and a grey control with
          // nothing to say is the shape R8 forbids.
          SettingsCaption("Connect another display to arrange them.")
        } else {
          mainDisplayControl
        }

        // AR7 in words. Built from the problems themselves, so it names the
        // displays — and it is the SAME sentence the confirmation window uses
        // for the same fact, because two spellings of one statement are two
        // things to keep true.
        if !refusal.isEmpty {
          ArrangementCopy.invalidLayout(refusal, name: coordinator.displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// AR9. Setting the main display is a **button**, not a drag on a 4 pt strip:
  /// the strip affordance is undiscoverable enough to be a recurring support
  /// question on Apple's own implementation, it is not operable by keyboard or
  /// VoiceOver, and a second drag semantic on the tile is the most feel-dependent
  /// interaction in the riskiest view here. The same action is on the tile's
  /// context menu and is a VoiceOver custom action.
  @ViewBuilder private var mainDisplayControl: some View {
    // The reason the button is dead travels IN its row. A grey control a
    // divider away from its explanation reads as a different setting.
    SettingRow(caption: mainDisplayCaption) {
      Button("Use as Main Display") {
        guard let id = reconciledSelection.wrappedValue else { return }
        // A pure translation of the whole layout, so relative geometry is
        // provably unchanged — "make main" cannot rearrange anything.
        coordinator.apply(coordinator.arrangement.makingMain(id))
      }
      .accessibilityLabel("Use as Main Display")
      .disabled(!canMakeMain)
    }
  }

  private var canMakeMain: Bool {
    guard !coordinator.isApplying, let id = reconciledSelection.wrappedValue else { return false }
    return id != coordinator.arrangement.mainDisplayID
  }

  /// What the button will do, or why it will not — never a bare grey button.
  /// Ordered by which fact outlives the others: `isApplying` is transient, so
  /// the structural reasons are stated first.
  private var mainDisplayCaption: SettingsCaption {
    guard let id = reconciledSelection.wrappedValue else {
      // It said "click one to make it the main display", which is not what a
      // click does — a click selects, and the button is the thing that moves the
      // menu bar. Copy that promises the button's effect to a click is half of
      // why a selected-looking tile beside a dead button reads as broken.
      return SettingsCaption(
        "Drag a display to move it, or click one to select it. Tab to a display and press Space to select it, then use the arrow keys to move it. Displays have to touch along an edge and cannot overlap."
      )
    }
    if id == coordinator.arrangement.mainDisplayID {
      return SettingsCaption(
        "This display already shows the menu bar. Select another one to move it."
      )
    }
    if coordinator.isApplying {
      return SettingsCaption("Waiting for the last change to finish.")
    }
    return SettingsCaption(
      "Moves the menu bar and the Dock to this display. You will be asked to keep or undo the change."
    )
  }

  // MARK: - Saved layouts

  /// The unattended half of the feature: what happens to this layout when the
  /// displays come back.
  ///
  /// Its OWN section rather than another row under the map, because it is a
  /// different concern — the map is what the user is doing now, this is what the
  /// app does when nobody is watching — and grouping is what tells two concerns
  /// apart (layout.md, "group related items"). The header carries information
  /// the pane's toolbar title does not, which is why this section has one and
  /// the map's section does not.
  ///
  /// It is present with one display attached, for the reason the whole pane is:
  /// a control that appears and disappears as hardware comes and goes is the
  /// failure R16 ruled against. What changes is the caption, not the control.
  private var savedLayoutSection: some View {
    Section("Saved Arrangements") {
      SettingRow(caption: rememberCaption) {
        Toggle("Remember how these displays are arranged", isOn: Binding(
          get: { coordinator.isRestoringLayout },
          set: { restoring in
            // Only the FLAG is announced here. Turning it on ALSO saves the
            // layout on screen, and that write announces itself from inside the
            // coordinator (`didSaveArrangement`) — naming `.savedArrangements`
            // here as well would put the rule in two places, which is exactly
            // how the stored-mode announcement was lost the first time.
            coordinator.setRestoringLayout(restoring)
            actions.prefDidChange(.restoreArrangement)
          }
        ))
      }

      // The restore pass is one of the things Safe Mode suppresses, so in a
      // safe-mode session this control describes behavior that is not happening.
      // D11: say so where it changes what the control means, rather than leaving
      // the pane quietly claiming otherwise. Symbol AND text — never state by
      // colour alone (color.md).
      if model.isSafeMode {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Text("Safe Mode is on for this session, so no arrangement will be restored.")
        }
        SettingsCaption("Shift was held at launch. Relaunch without holding Shift to restore normal startup behavior. Your setting above is unchanged and will be used then.")
      }

      // The only account an unattended restore ever gives, and it waits here
      // until the user dismisses it or a later restore pass supersedes it —
      // never taken away by a departure alone (SO8) — rendered in the
      // section whose control made the promise, exactly as the stored-mode
      // reapply banner sits under "Remember this resolution".
      if let notice = coordinator.restoreNotice {
        VStack(alignment: .leading, spacing: 6) {
          ArrangementCopy.restoreNotice(notice, name: coordinator.displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("OK") { coordinator.dismissReport() }
            .accessibilityLabel("OK")
        }
      }
    }
  }

  /// What the toggle will do — and, with one display attached, what there is to
  /// do it to. Never a control whose effect the user has to guess.
  private var rememberCaption: SettingsCaption {
    // Built rather than written as one literal: the sentences are long enough
    // that a single line is unreadable in source, and `SettingsCaption` has the
    // `verbatim` initialiser precisely so a composed sentence still gets the
    // pane's caption styling by construction.
    let restores = coordinator.arrangement.tiles.count > 1
      ? "Puts these displays back this way when they reconnect or \(AppInfo.productName) launches."
      : "Puts a set of displays back the way you left them when that set reconnects or \(AppInfo.productName) launches."
    guard coordinator.arrangement.tiles.count > 1 else {
      return SettingsCaption(verbatim: "\(restores) With one display connected there is no arrangement to save yet.")
    }
    let updates = "Turning it on saves the arrangement on screen now, and keeping a change you make here updates it."
    let elsewhere = "Changes you make in System Settings are left alone until the displays reconnect."
    return SettingsCaption(verbatim: "\(restores) \(updates) \(elsewhere)")
  }

  // MARK: - Selection

  /// The selection, reconciled against the layout on every read. A display can
  /// depart between the click and the button press, and a selection naming one
  /// that is gone must not survive as a live target.
  private var reconciledSelection: Binding<CGDirectDisplayID?> {
    Binding(
      get: {
        guard let selection, coordinator.arrangement.tile(selection) != nil else { return nil }
        return selection
      },
      set: { selection = $0 }
    )
  }
}
