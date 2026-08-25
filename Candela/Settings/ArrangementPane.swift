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
  /// restore pass, outside any transaction of ours, so a `.animation` hung on
  /// the notice's container has nothing to travel with: the mirror is what puts
  /// the arrival AND the dismissal inside one. Kept in agreement by the two
  /// hooks in `savedLayoutSection` and by nothing else.
  @State private var shownRestoreNotice: ArrangementReapplyNotice?

  /// The layout a requested change is animating INTO, held while the apply is
  /// in flight.
  ///
  /// Without it, the map goes on drawing `coordinator.arrangement`, which is
  /// still the layout the change started FROM: a dropped tile slides back to
  /// where it was picked up and only then jumps forward when the apply lands,
  /// and a move has to travel toward its result rather than away from it.
  ///
  /// It lives HERE rather than in the canvas because it is a fact about the
  /// coordinator, not about a map: "a layout has been asked for and the apply is
  /// outstanding". While the canvas owned it, the routes that went through the
  /// canvas animated and this pane's own "Use as Main Display" button did not,
  /// because it had no way to reach the state. Every route now goes through
  /// `propose`.
  ///
  /// Showing the requested layout while the request is outstanding is the same
  /// thing the countdown does, so it is not a claim about achieved state, and an
  /// apply that fails corrects the map as it finishes rather than leaving it
  /// lying.
  @State private var settling: DisplayArrangement?

  private var coordinator: ArrangementCoordinator { model.arrangement }

  /// What the map is drawing from, and what every proposal is composed against:
  /// the requested layout while one is outstanding, the achieved one otherwise.
  private var displayedArrangement: DisplayArrangement {
    settling ?? coordinator.arrangement
  }

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
      Self.name(
        of: id, standingBehind: panels, friendly: coordinator.displayName,
        fromTopology: { panel in
          model.mirrorTopology.topology().displays.first { $0.id == panel }?.name
        }
      )
    }
  }

  /// The resolution itself, pure so the fallback can be pinned without a window
  /// (AT10).
  ///
  /// NEVER "" for a pair, which is why the last resort is spelled out rather
  /// than left to the caller: the canvas answers an empty name with the name the
  /// TILE carries, and for a pair that is the virtual display's, the one string
  /// that must not appear on this map. So the panel's friendly name, then the
  /// panel's own name from the topology, and behind those the wording the app
  /// already uses for a display nothing can name.
  static func name(
    of id: CGDirectDisplayID, standingBehind panels: [CGDirectDisplayID: CGDirectDisplayID],
    friendly: (CGDirectDisplayID) -> String,
    fromTopology: (CGDirectDisplayID) -> String?
  ) -> String {
    guard let panel = panels[id] else { return friendly(id) }
    let friendlyName = friendly(panel)
    guard friendlyName.isEmpty else { return friendlyName }
    let panelName = fromTopology(panel) ?? ""
    return panelName.isEmpty ? unnamedDisplay : panelName
  }

  /// The app's last-resort wording for a display nothing can name.
  static let unnamedDisplay = "Display"

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, and every tile is
    // NAMED through it (`PanelView.title(for:)` resolves `friendlyName`). Without
    // this read, renaming a display elsewhere in the window would leave the old
    // name standing on the map. The coordinator itself is `@Observable` and
    // needs no help.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(title: "Arrangement", subtitle: Self.pageSubtitle)
      mapCard
      mainDisplaySection
      savedLayoutSection
    }
    // ONE signal ends the settle, and it is positive: the coordinator has
    // finished the work it was given. No timer, because a deadline long enough
    // for a slow reconfiguration is also long enough to show a failed one as
    // though it worked.
    //
    // `coordinator.arrangement` changing is deliberately NOT watched, because it
    // is not evidence about THIS settle. `performApply` re-reads the layout
    // before its queue task decrements the in-flight count, so the arrangement
    // is already current by the time this fires and a second hook would buy
    // nothing; and with two changes outstanding the count keeps `isApplying`
    // true, so the first apply's re-read would clear the second's settle and
    // snap the map back to a layout one change stale. The refusal paths (a
    // no-op, an invalid layout, the four-way gate of AR12) return before that
    // re-read and still arrive here, so a refused proposal correctly drops the
    // map back to achieved state.
    .onChange(of: coordinator.isApplying) { _, applying in
      guard !applying else { return }
      withAnimation(Motion.settle(reduceMotion: reduceMotion)) { settling = nil }
    }
    .task(id: refusalToken) {
      guard !refusal.isEmpty else { return }
      // Long enough to read a sentence, short enough that it does not outlive
      // the state it describes. Cancelled and restarted by `id:` on the next
      // refusal, and cancelled outright when the pane goes away.
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      // Inside a transaction, like the write in `onRefuse`, so both directions
      // fade the same way.
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { refusal = [] }
    }
  }

  // MARK: - The map

  /// Says the map is draggable at all, and names the arrow keys, which are the
  /// only way to move a display without a pointer.
  ///
  /// It is the page's subtitle rather than a caption inside the card for the
  /// reason it stopped being the button's caption: that caption shows only
  /// while nothing is selected, so the instructions explaining the whole
  /// control disappeared as soon as anyone used it. The arrow keys were then
  /// carried for a while by a per-tile accessibility hint alone, which a
  /// sighted keyboard-only user never hears: that user is the gap the keyboard
  /// route exists to close, so the instruction is visible copy that nothing
  /// takes away.
  static let pageSubtitle =
    "Where the displays are, and where they should be. Drag a display to move it, or tab to one and move it with the arrow keys."

  /// Headerless on purpose. The page's own title already reads "Arrangement",
  /// and a card kicker repeating it word for word is the duplicated-title
  /// defect the settings redesign shipped once and had to be looked at to
  /// catch: a structural check cannot see two identical words at two
  /// altitudes.
  private var mapCard: some View {
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
    // Drawn as a laptop rather than as a monitor (SV9). One ID, snapshotted for
    // `virtualIDs`' reason, and read from the model rather than from the tile:
    // an arrangement tile knows a rect, not what kind of glass it is.
    let builtInID = model.builtIn?.id
    return SettingsCardSection {
      VStack(alignment: .leading, spacing: 10) {
        // The stage: a dark recessed floor the displays stand on, spanning the
        // card while the map itself keeps its fixed size (AR2, and the
        // screenshot checks) and is centred on it.
        ArrangementCanvasView(
          arrangement: displayedArrangement,
          name: displayName,
          isVirtual: { virtualIDs.contains($0) },
          isSynthesisPair: { panels[$0] != nil },
          isBuiltIn: { $0 == builtInID },
          // Not for the settle, which is this pane's: the canvas refuses to
          // compose a new request from a layout that has only been requested,
          // because a refused request is never achieved. That covers the drag,
          // the arrow keys, the tile's context menu and its VoiceOver action.
          isApplying: coordinator.isApplying,
          selection: reconciledSelection,
          onPropose: { propose($0) },
          onRefuse: { problems in
            // The animation travels with the write. `refusal` is this view's own
            // state and needs no mirror: the mirror shape exists to get a
            // coordinator's write inside a `withAnimation`, and this write is
            // already inside the view. The whole value moves, so a second
            // refusal with a longer sentence animates its height rather than
            // snapping to it.
            withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
              refusal = problems
            }
            refusalToken &+= 1
          }
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
        .background(
          RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
            .fill(Color.black.opacity(0.32))
        )
        .overlay(
          RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
            .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )

        // The two facts the map states that the tiles' shapes cannot: what the
        // strip on a face means, and the rule a drop has to satisfy.
        SettingsCaption(
          "The strip along the top of a display marks the one showing the menu bar. Displays have to touch along an edge and cannot overlap."
        )

        // Under the MAP, because arranging them is what the sentence is about.
        // Under the Main Display kicker it answered a question that card is not
        // asking.
        if coordinator.arrangement.tiles.count < 2 {
          SettingsCaption("Connect another display to arrange them.")
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
        if !refusal.isEmpty {
          ArrangementCopy.invalidLayout(refusal, name: displayName)
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - Main display

  /// AR9. Setting the main display is a **button**, not a drag on a 4 pt strip:
  /// the strip affordance is undiscoverable enough to be a recurring support
  /// question on Apple's own implementation, it is not operable by keyboard or
  /// VoiceOver, and a second drag semantic on the tile is the most feel-dependent
  /// interaction in the riskiest view here. The same action is on the tile's
  /// context menu and is a VoiceOver custom action.
  ///
  /// The whole card, kicker included, waits for a second display. No button at
  /// all rather than a permanently dead one: with one display there is nothing
  /// to choose between, and a grey control with nothing to say is the shape R8
  /// forbids. This is not the appearing-and-disappearing control R16 rules
  /// against either, which is about a control whose SUBJECT is still there: a
  /// heading over an empty card would be one, and the map above says what is
  /// missing.
  @ViewBuilder private var mainDisplaySection: some View {
    if coordinator.arrangement.tiles.count > 1 {
      SettingsCardSection(title: "Main Display") {
        // The reason the button is dead travels IN its row. A grey control a
        // divider away from its explanation reads as a different setting.
        SettingRow(caption: mainDisplayCaption) {
          Button("Use as Main Display") {
            guard let id = reconciledSelection.wrappedValue else { return }
            // A pure translation of the whole layout, so relative geometry is
            // provably unchanged: "make main" cannot rearrange anything.
            //
            // Through `propose`, like every other route: this button is the
            // reason the settle was lifted out of the canvas, since it was the
            // one way of asking for a layout that could not reach the state and
            // so stepped to its result instead of animating into it.
            propose(displayedArrangement.makingMain(id))
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel("Use as Main Display")
          .disabled(!canMakeMain)
        }
      }
    }
  }

  /// The one place a layout is asked for, so the drop, the arrow keys, the
  /// context menu, the VoiceOver action and the button above all behave alike.
  ///
  /// Composed against `displayedArrangement`, never against the coordinator's:
  /// during a settle the coordinator still holds the pre-change layout, so a
  /// second change measured from it would be measured from a layout that is no
  /// longer the one on screen.
  private func propose(_ next: DisplayArrangement) {
    coordinator.apply(next)
    // A proposal equal to what is already showing arms nothing.
    //
    // `isApplying` DOES rise for one: `ArrangementCoordinator.apply` raises it
    // synchronously and unconditionally before it enqueues anything. What makes
    // the guard load-bearing is that it comes straight back down again.
    // `performApply` reaches its no-op `return` with no `await` in front of it,
    // so the whole true-then-false transition can complete before SwiftUI
    // evaluates a body; `onChange` compares against the value captured at the
    // last evaluation, so it may never fire, and a settle set here would then be
    // held for the life of the pane. `displayedArrangement` would go on ignoring
    // the coordinator, and connecting a second display would leave the map
    // drawing one tile.
    //
    // Compared on the ANCHORED form, which is the comparison the coordinator's
    // own guard makes. Raw equality is narrower, and the gap is reachable with a
    // single display attached: dragging the only tile anywhere produces a pure
    // unanchored translation, which passes here and is dropped there, on that
    // same no-await path. Two guards that disagree about what a no-op is are
    // exactly one guard too many.
    guard (next.anchored(preservingMainOf: displayedArrangement) ?? next) != displayedArrangement
    else { return }
    withAnimation(Motion.settle(reduceMotion: reduceMotion)) { settling = next }
  }

  private var canMakeMain: Bool {
    guard !coordinator.isApplying, let id = reconciledSelection.wrappedValue else { return false }
    return id != coordinator.arrangement.mainDisplayID
  }

  /// What the button will do, or why it will not — never a bare grey button.
  /// Ordered by which fact outlives the others: `isApplying` is transient, so
  /// the structural reasons are stated first.
  ///
  /// A consequence of that order worth naming, because it has been read the
  /// other way: the waiting sentence is reached only with a display selected
  /// that is not already main. It explains THIS button, and it is not a general
  /// account of why the canvas refuses a gesture. Nothing in the canvas may lean
  /// on it to put a refusal into words.
  private var mainDisplayCaption: SettingsCaption {
    guard let id = reconciledSelection.wrappedValue else {
      // It said "click one to make it the main display", which is not what a
      // click does: a click selects, and the button is the thing that moves the
      // menu bar. Copy that promises the button's effect to a click is half of
      // why a selected-looking tile beside a dead button reads as broken.
      //
      // The dragging half of this sentence now lives in the page's subtitle,
      // where it stays visible once something is selected.
      return SettingsCaption(
        "Select a display to move the menu bar to it. Click one, or tab to it and press Space."
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
    // Named, not "this display". The button acts on the selection, and the
    // selection is a blue fill a long way up the section; the row has to say
    // which display it means in words.
    let name = displayName(id)
    guard !name.isEmpty else {
      return SettingsCaption(
        "Moves the menu bar and the Dock to the selected display. You will be asked to keep or undo the change."
      )
    }
    return SettingsCaption(
      verbatim: "Moves the menu bar and the Dock to \(name). You will be asked to keep or undo the change."
    )
  }

  // MARK: - Saved layouts

  /// The unattended half of the feature: what happens to this layout when the
  /// displays come back.
  ///
  /// Its OWN section rather than another row under the map, because it is a
  /// different concern — the map is what the user is doing now, this is what the
  /// app does when nobody is watching — and grouping is what tells two concerns
  /// apart (layout.md, "group related items"). The kicker carries information
  /// the page title does not, which is why this card has one and the map's does
  /// not.
  ///
  /// It is present with one display attached, for the reason the whole pane is:
  /// a control that appears and disappears as hardware comes and goes is the
  /// failure R16 ruled against. What changes is the caption, not the control.
  private var savedLayoutSection: some View {
    SettingsCardSection(title: "Saved Arrangements") {
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
        .themedSwitch()
        .prefIdentifier(.restoreArrangement)
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
        notice {
          Text("Safe Mode is on for this session, so no arrangement will be restored.")
            .font(.callout.weight(.medium))
            .foregroundStyle(SettingsTheme.titleColor)
            .fixedSize(horizontal: false, vertical: true)
          SettingsCaption("Shift was held at launch. Relaunch without holding Shift to restore normal startup behavior. Your setting above is unchanged and will be used then.")
        }
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
      if let report = shownRestoreNotice {
        notice(symbol: "clock.arrow.circlepath") {
          ArrangementCopy.restoreNotice(report, name: displayName)
            .font(.callout)
            .foregroundStyle(SettingsTheme.titleColor)
            .fixedSize(horizontal: false, vertical: true)
          Button("OK") { coordinator.dismissReport() }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("OK")
            .padding(.top, 2)
        }
        .transition(.opacity)
      }
    }
  }

  /// The theme's notice, plus this card's spacing around it.
  private func notice(
    symbol: String = "exclamationmark.triangle", @ViewBuilder content: () -> some View
  ) -> some View {
    SettingsNotice(symbol: symbol) { content() }
      .padding(.top, 10)
      .padding(.bottom, 4)
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
