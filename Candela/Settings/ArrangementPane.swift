import CandelaKit
import CoreGraphics
import SwiftUI

/// Where the displays are, and where they should be.
///
/// A top-level destination rather than a section in `DisplayDetailView`: an
/// arrangement is a property of the display SET, so there is no display whose
/// pane it belongs in.
///
/// The pane exists with one display too, showing the single tile and a caption.
/// A pane that came and went with the hardware is the failure the
/// vanishing-subject rule guards against.
///
/// `@MainActor` because a `View`'s properties other than `body` are nonisolated
/// under complete concurrency checking, and this one stores main-actor types.
@MainActor
struct ArrangementPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Reconciled against the live layout on every read: displays come and go
  /// while this pane is open, and a selection naming a departed display would
  /// leave "Use as Main Display" live over nothing.
  @State private var selection: CGDirectDisplayID?

  /// Why the last drop was refused. Held here because it is the SECTION
  /// that says it in words; colour is never allowed to be the only signal.
  @State private var refusal: [ArrangementProblem] = []
  /// Bumped on every refusal so an identical second refusal restarts the timer
  /// rather than inheriting the tail of the first one's.
  @State private var refusalToken = 0

  /// The restore notice as RENDERED, one update behind
  /// `coordinator.restoreNotice`. The coordinator writes that from an unattended
  /// restore pass, outside any transaction of ours, so the mirror is what puts
  /// the arrival AND the dismissal inside one. Synced by the two hooks in
  /// `savedLayoutSection` and by nothing else.
  @State private var shownRestoreNotice: ArrangementReapplyNotice?

  /// The layout a requested change is animating INTO, held while the apply is in
  /// flight. Without it the map keeps drawing `coordinator.arrangement`, the
  /// layout the change started FROM, so a dropped tile slides back to where it
  /// was picked up and only then jumps forward.
  ///
  /// It lives HERE rather than in the canvas because it is a fact about the
  /// coordinator. While the canvas owned it, "Use as Main Display" could not
  /// reach the state and stepped to its result instead of animating into it.
  ///
  /// Showing a requested layout is what the countdown already does, so it is no
  /// claim about achieved state, and a failed apply corrects the map as it
  /// finishes.
  @State private var settling: DisplayArrangement?

  private var coordinator: ArrangementCoordinator { model.arrangement }

  /// What the map is drawing from, and what every proposal is composed against:
  /// the requested layout while one is outstanding, the achieved one otherwise.
  private var displayedArrangement: DisplayArrangement {
    settling ?? coordinator.arrangement
  }

  /// The panel each synthesis virtual display is standing in for, by the
  /// virtual display's ID. Runtime IDs, derived per read: the pairing
  /// changes while this pane is open, and display IDs are reassigned across a
  /// replug, so nothing here may be held.
  private static func panels(
    standingBehind pairings: [SynthesisPairing]
  ) -> [CGDirectDisplayID: CGDirectDisplayID] {
    pairings.reduce(into: [:]) { $0[$1.virtualDisplayID] = $1.physicalDisplayID }
  }

  /// What every surface in this pane calls a display: its own name, or (while a
  /// synthesized size is engaged) the name of the panel whose picture the tile is
  /// ONE closure for the map, the refusal sentence and the restore
  /// notice, so they cannot disagree.
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

  /// The resolution itself, pure so the fallback can be pinned without a window.
  ///
  /// NEVER "" for a pair: the canvas answers an empty name with the name the TILE
  /// carries, which for a pair is the virtual display's, the one string that must
  /// not appear on this map. So the panel's friendly name, then its topology
  /// name, then the app's last-resort wording.
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
    // NAMED through it, so without this read a rename elsewhere in the window
    // would leave the old name standing on the map.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(title: "Arrangement", subtitle: Self.pageSubtitle)
      mapCard
      mainDisplaySection
      savedLayoutSection
    }
    // ONE signal ends the settle, and it is positive: the coordinator finished
    // the work it was given. No timer, because a deadline long enough for a slow
    // reconfiguration is also long enough to show a failed one as though it
    // worked.
    //
    // `coordinator.arrangement` changing is deliberately NOT watched: it is not
    // evidence about THIS settle. With two changes outstanding the first apply's
    // re-read would clear the second's settle and snap the map back one change
    // stale. The refusal paths still arrive here, so a refused proposal drops the
    // map back to achieved state.
    .onChange(of: coordinator.isApplying) { _, applying in
      guard !applying else { return }
      withAnimation(Motion.settle(reduceMotion: reduceMotion)) { settling = nil }
    }
    .task(id: refusalToken) {
      guard !refusal.isEmpty else { return }
      // Long enough to read a sentence, short enough not to outlive the state it
      // describes. Restarted by `id:` on the next refusal.
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      // Inside a transaction, like the write in `onRefuse`, so both directions
      // fade the same way.
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { refusal = [] }
    }
  }

  // MARK: - The map

  /// Says the map is draggable at all, and names the arrow keys, the only way to
  /// move a display without a pointer.
  ///
  /// The page's subtitle rather than a caption inside the card: a caption that
  /// hides once something is selected takes the instructions with it, and an
  /// accessibility hint alone never reaches a sighted keyboard-only user.
  static let pageSubtitle =
    "Where the displays are, and where they should be. Drag a display to move it, or tab to one and move it with the arrow keys."

  /// Headerless on purpose: the page title already reads "Arrangement", and a
  /// card kicker repeating it word for word is a duplicated title no structural
  /// check can see.
  private var mapCard: some View {
    // Ours by ownership, everyone else's by the optional-returning predicate
    // (nil reads as an ordinary panel). Snapshotted ONCE per render: the canvas
    // calls its closure per tile per drag frame, and the predicate behind it
    // fetches a CoreDisplay dictionary.
    let virtualIDs = Set(coordinator.arrangement.tiles.map(\.id).filter { id in
      model.virtualDisplays.ownedDisplayIDs.contains(id)
        || VirtualDisplayDetection.isVirtual(id) == true
    })
    // Snapshotted for `virtualIDs`' reason, and read from the pairing
    // rather than from the mirror flags: the pairing is what says a mirror set is
    // a size this app engaged rather than one the user asked for.
    //
    // The pair keeps ONE tile, the virtual display's, and it stays movable: that
    // display owns the desktop, so it is the member of the pair a layout can
    // place. The panel has no tile, so the tile speaks for it.
    let panels = Self.panels(standingBehind: model.synthesis.pairings)
    // Drawn as a laptop rather than as a monitor. Snapshotted for
    // `virtualIDs`' reason, and read from the model rather than the tile: an
    // arrangement tile knows a rect, not what kind of glass it is.
    let builtInID = model.builtIn?.id
    return SettingsCardSection {
      VStack(alignment: .leading, spacing: 10) {
        // The stage: a dark recessed floor the displays stand on, spanning the
        // card while the map itself keeps its fixed size (the
        // screenshot checks) and is centred on it.
        ArrangementCanvasView(
          arrangement: displayedArrangement,
          name: displayName,
          isVirtual: { virtualIDs.contains($0) },
          isSynthesisPair: { panels[$0] != nil },
          isBuiltIn: { $0 == builtInID },
          // Not for the settle, which is this pane's: the canvas refuses to
          // compose a new request from a layout only requested, because a refused
          // request is never achieved.
          isApplying: coordinator.isApplying,
          selection: reconciledSelection,
          onPropose: { propose($0) },
          onRefuse: { problems in
            // The animation travels with the write. `refusal` is this view's own
            // state and needs no mirror: the mirror shape exists to get a
            // coordinator's write inside a `withAnimation`.
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
        if coordinator.arrangement.tiles.count < 2 {
          SettingsCaption("Connect another display to arrange them.")
        }

        // The same refusal, in words. Built from the problems themselves, so it names the
        // displays, and it is the SAME sentence the confirmation window uses:
        // two spellings of one statement are two things to keep true.
        //
        // The fade comes from the transaction both writers of `refusal` carry.
        // The refused-drop write also springs the tile home on the same values,
        // so sentence and spring read as one gesture.
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

  /// Setting the main display is a BUTTON, not a drag on a 4 pt strip: the
  /// strip is undiscoverable enough to be a recurring support question on
  /// Apple's own implementation, and it is not operable by keyboard or
  /// VoiceOver. The same action is on the tile's context menu and as a VoiceOver
  /// custom action.
  ///
  /// The whole card waits for a second display. No button rather than a
  /// permanently dead one: with one display there is nothing to choose
  /// between. The vanishing-subject rule is about a control whose SUBJECT is
  /// still there, so it does not apply.
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
            // Through `propose`, like every other route.
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
  /// second change would be measured from a layout no longer on screen.
  private func propose(_ next: DisplayArrangement) {
    coordinator.apply(next)
    // A proposal equal to what is already showing arms nothing.
    //
    // `isApplying` DOES rise for one and comes straight back down: `performApply`
    // reaches its no-op `return` with no `await` in front of it, so the whole
    // true-then-false transition can complete before SwiftUI evaluates a body.
    // `onChange` may then never fire, and a settle set here would be held for the
    // life of the pane, leaving `displayedArrangement` ignoring the coordinator.
    //
    // Compared on the ANCHORED form, the comparison the coordinator's own guard
    // makes. Raw equality is narrower, and the gap is reachable with one display:
    // dragging the only tile is a pure unanchored translation, which passes here
    // and is dropped there, on that same no-await path.
    guard (next.anchored(preservingMainOf: displayedArrangement) ?? next) != displayedArrangement
    else { return }
    withAnimation(Motion.settle(reduceMotion: reduceMotion)) { settling = next }
  }

  private var canMakeMain: Bool {
    guard !coordinator.isApplying, let id = reconciledSelection.wrappedValue else { return false }
    return id != coordinator.arrangement.mainDisplayID
  }

  /// What the button will do, or why it will not, never a bare grey button.
  /// Ordered by which fact outlives the others: `isApplying` is transient, so
  /// the structural reasons are stated first.
  ///
  /// The waiting sentence is therefore reached only with a non-main display
  /// selected. It explains THIS button; nothing in the canvas may lean on it to
  /// put a refusal into words.
  private var mainDisplayCaption: SettingsCaption {
    guard let id = reconciledSelection.wrappedValue else {
      // A click selects; the button is what moves the menu bar. Copy that
      // promises the button's effect to a click is half of why a selected-looking
      // tile beside a dead button reads as broken.
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
  /// Its OWN section rather than another row under the map: the map is what the
  /// user is doing now, this is what the app does when nobody is watching. Its
  /// kicker carries information the page title does not, which is why the map's
  /// card has none.
  ///
  /// Present with one display attached, for the reason the whole pane is.
  /// What changes is the caption, not the control.
  private var savedLayoutSection: some View {
    SettingsCardSection(title: "Saved Arrangements") {
      SettingRow(caption: rememberCaption) {
        Toggle("Remember how these displays are arranged", isOn: Binding(
          get: { coordinator.isRestoringLayout },
          set: { restoring in
            // Only the FLAG is announced here. Turning it on ALSO saves the
            // layout, and that write announces itself from inside the coordinator
            // (`didSaveArrangement`); announcing it here too would put the rule
            // in two places.
            coordinator.setRestoringLayout(restoring)
            actions.prefDidChange(.restoreArrangement)
          }
        ))
        .themedSwitch()
        .accessibilityLabel("Remember how these displays are arranged")
        .prefIdentifier(.restoreArrangement)
      }
      // The mirror hooks hang HERE, on the one row of this section that is
      // always present: on the notice's own container they would exist only while
      // it does, so nothing would watch for it to arrive. The appear sync is
      // un-animated, or a notice left over from an unattended restore would fade
      // in as though it had just happened.
      .onAppear { shownRestoreNotice = coordinator.restoreNotice }
      .onChange(of: coordinator.restoreNotice) { _, notice in
        withAnimation(Motion.notice(reduceMotion: reduceMotion)) {
          shownRestoreNotice = notice
        }
      }

      // Safe Mode suppresses the restore pass, so this control would otherwise
      // describe behavior that is not happening. Symbol AND text; never
      // state by colour alone.
      if model.isSafeMode {
        notice {
          Text("Safe Mode is on for this session, so no arrangement will be restored.")
            .font(.callout.weight(.medium))
            .foregroundStyle(SettingsTheme.titleColor)
            .fixedSize(horizontal: false, vertical: true)
          SettingsCaption("Shift was held at launch. Relaunch without holding Shift to restore normal startup behavior. Your setting above is unchanged and will be used then.")
        }
      }

      // The only account an unattended restore ever gives. It waits until the
      // user dismisses it or a later restore pass supersedes it, never taken away
      // by a departure alone, in the section whose control made the
      // promise.
      //
      // Rendered from the mirror, so arrival and dismissal fade the same way. The
      // OK click is not the only thing that ends this notice, so the transaction
      // belongs to the mirror write and not to the button.
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

  /// What the toggle will do, and with one display attached, what there is to
  /// do it to.
  private var rememberCaption: SettingsCaption {
    // Composed rather than one literal, which would be unreadable in source.
    // `SettingsCaption`'s `verbatim` initialiser keeps the pane's caption
    // styling on a composed sentence.
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
