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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

  /// The restore notice as RENDERED, mirroring `coordinator.restoreNotice` one
  /// update behind. The coordinator writes that property from an unattended
  /// restore pass, and neither placement of a keyed `.animation` fades a `Form`
  /// row symmetrically (measured 2026-08-17): on a `Group` wrapping the
  /// conditional row it animates nothing either way, and on an always-present
  /// container inside the row the child fades IN and then SNAPS out. That
  /// snap-out asymmetry is why a container-hung `.animation` is not enough; the
  /// mirror is what puts the arrival AND the dismissal inside one transaction.
  /// Kept in agreement by the two hooks in `savedLayoutSection` and by nothing
  /// else.
  @State private var shownRestoreNotice: ArrangementReapplyNotice?

  private var coordinator: ArrangementCoordinator { model.arrangement }

  /// The panel each synthesis virtual display is standing in for, by the
  /// virtual display's ID (SS12). Runtime IDs, derived per read: the pairing
  /// changes while this pane is open, and display IDs are reassigned across a
  /// replug, so nothing here may be held.
  private static func panels(
    standingBehind pairings: [SynthesisPairing]
  ) -> [CGDirectDisplayID: CGDirectDisplayID] {
    pairings.reduce(into: [:]) { $0[$1.virtualDisplayID] = $1.physicalDisplayID }
  }

  /// What every surface in this pane calls a display: its own name, or (while a
  /// synthesized size is engaged) the name of the panel whose picture the tile
  /// is (SS12). ONE closure for the map, the refusal sentence and the
  /// restore notice, so they cannot disagree about what a display is called.
  private var displayName: (CGDirectDisplayID) -> String {
    let panels = Self.panels(standingBehind: model.synthesis.pairings)
    return { id in
      guard let panel = panels[id] else { return coordinator.displayName(id) }
      let friendly = coordinator.displayName(panel)
      guard friendly.isEmpty else { return friendly }
      // Every caller falls back to the name the topology carries when this
      // answers "", and for a pair that name is the virtual display's: the one
      // string that must never appear on this map. So the fallback is resolved
      // for the PANEL here, where the pairing is still in hand.
      return model.mirrorTopology.topology().displays.first { $0.id == panel }?.name ?? ""
    }
  }

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
      // Inside a transaction, like the write in `onRefuse`: a keyed `.animation`
      // on a `Group` wrapping a conditional `Form` row animates nothing in either
      // direction, and hung on the always-present container inside the row it
      // fades the child in but snaps it out (measured 2026-08-17), so the
      // animation has to travel with the write.
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { refusal = [] }
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
    // Ours by ownership, everyone else's by the optional-returning predicate
    // (nil reads as an ordinary panel). Snapshotted ONCE per render rather
    // than asked per tile: the canvas calls its closure per tile per drag
    // frame, and the predicate behind it fetches a CoreDisplay dictionary.
    let virtualIDs = Set(coordinator.arrangement.tiles.map(\.id).filter { id in
      model.virtualDisplays.ownedDisplayIDs.contains(id)
        || VirtualDisplayDetection.isVirtual(id) == true
    })
    // SS12. Snapshotted here for `virtualIDs`' reason, and read from the pairing
    // rather than from the mirror flags: the pairing is what says a mirror set
    // is a size this app engaged rather than one the user asked for.
    //
    // The pair keeps ONE tile, the virtual display's, and it stays movable: that
    // display owns the desktop, so it is the member of the pair a layout can
    // place (AR6). The panel is its slave and has no tile of its own, which is
    // why the tile has to speak for it.
    let panels = Self.panels(standingBehind: model.synthesis.pairings)
    return Section {
      VStack(alignment: .leading, spacing: 8) {
        ArrangementCanvasView(
          arrangement: coordinator.arrangement,
          name: displayName,
          isVirtual: { virtualIDs.contains($0) },
          isSynthesisPair: { panels[$0] != nil },
          selection: reconciledSelection,
          onPropose: { coordinator.apply($0) },
          onRefuse: { problems in
            // The sentence below is a conditional child of a `Form` row: a keyed
            // `.animation` on a `Group` around it animates nothing, and on the
            // always-present `VStack` inside the row it fades the sentence in but
            // snaps it out (measured 2026-08-17), so the write carries the
            // transaction instead. `refusal` is this view's own state and needs no
            // mirror: the mirror shape exists to get a coordinator's write inside
            // a `withAnimation`, and this write is already inside the view. The
            // whole value moves, so a second refusal with a longer sentence
            // animates its height rather than snapping to it.
            withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
              refusal = problems
            }
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
        //
        // The fade comes from the transaction the two writers of `refusal`
        // carry. The refused-drop write also springs the tile home on the same
        // values, so sentence and spring read as one gesture; the 4 s
        // auto-clear has no drag left to spring.
        //
        // Expect the two directions to differ. This is a conditional child of an
        // always-present `VStack` that is itself a `Form` row, the geometry
        // measured on 2026-08-17 as fading IN and snapping OUT, so the insert
        // reads as a fade and the 4 s removal most likely snaps even though the
        // transaction is present. Confirm by looking before claiming a symmetric
        // fade; the mirror shape is the fix if the snap is unacceptable.
        if !refusal.isEmpty {
          ArrangementCopy.invalidLayout(refusal, name: displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
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
      // The restore notice's mirror hooks hang HERE, on the one row of this
      // section that is always present: hooks on the notice's own container would
      // only exist while the notice does, so nothing would be watching for it to
      // arrive. The appear sync is un-animated on purpose, or a notice left over
      // from an unattended restore would fade in as though it had just happened.
      .onAppear { shownRestoreNotice = coordinator.restoreNotice }
      .onChange(of: coordinator.restoreNotice) { _, notice in
        withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
          shownRestoreNotice = notice
        }
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
      //
      // Rendered from the mirror, so arrival and dismissal fade the same way.
      // `dismissReport()` clears five coordinator properties and the OK click
      // is not the only thing that ends this notice, so the transaction belongs
      // to the mirror write and not to the button.
      if let notice = shownRestoreNotice {
        VStack(alignment: .leading, spacing: 6) {
          ArrangementCopy.restoreNotice(notice, name: displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("OK") { coordinator.dismissReport() }
            .accessibilityLabel("OK")
        }
        .transition(.opacity)
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
