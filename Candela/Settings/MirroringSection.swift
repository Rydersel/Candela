import CandelaKit
import CoreGraphics
import SwiftUI

/// Mirroring for one display — rows in the hub's Display section (Task 13),
/// no section of its own.
///
/// The state and every decision come from `MirroringCoordinator`; nothing here
/// re-derives a topology, because two samples of one machine disagree exactly
/// when it matters. `MirrorTopology` is the ONE definition of "mirrored" in this
/// app and this section is a reader of it, never a second opinion.
///
/// **Nothing here is persisted (DT20).** Mirroring is deliberately not a
/// preference and is not reapplied at launch or on reconnect, so there is no
/// `PrefName` case, no `PrefPropagation` row and no `DisplayPrefWriter` call in
/// this file. A future edit that adds one is changing shipped on-disk schema and
/// is not a UI change.
///
/// **D29 conditional.** Nothing in here disables, greys or hides a volume, mute
/// or DDC control on the basis of mirror state, and no sentence here claims a
/// mirror slave's hardware control is unavailable. Whether an active mirror
/// suppresses a slave's DDC is UNVERIFIED; treating it as suppressed would put
/// VCP 0x8D out of reach and could strand a display muted with no way back from
/// inside the app.
///
/// `@MainActor` because a `View`'s stored and computed properties other than
/// `body` are nonisolated under complete concurrency checking, and this one
/// stores main-actor types.
@MainActor
struct MirroringSection: View {
  let state: AppModel.DisplayState
  let coordinator: MirroringCoordinator

  /// **`let _ = model.prefsRevision` IS required here**, and the reason is not
  /// obvious: this section reads no pref directly, but every display it NAMES is
  /// named through `coordinator.displayName`, which resolves
  /// `DisplayPrefs.friendlyName` (`PanelView.title(for:)`). `DisplayPrefs` is
  /// plain `UserDefaults` and is not observable, so without the read below,
  /// renaming a display in the section directly above this one would leave the
  /// old name standing in the status line and in the picker. The coordinator
  /// itself is `@Observable` and needs no help.
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The master the user has picked, or nil while they have picked nothing.
  /// Never read directly — `selectedMaster` reconciles it against the live
  /// topology first, because a display can depart between the pick and the
  /// click.
  @State private var chosenMaster: CGDirectDisplayID?

  /// The reason lines as RENDERED, mirroring the coordinator's three signals one
  /// update behind. Neither placement of a keyed `.animation` fades a `Form` row
  /// symmetrically (measured 2026-08-17): on a `Group` wrapping the conditional
  /// row it animates nothing in either direction, and on an always-present
  /// container inside the row the child fades IN and then SNAPS out. A line that
  /// snaps away is the half that matters here, so the only way these fade both
  /// ways is for the write to happen inside a `withAnimation` in this view. Kept
  /// in agreement by the two hooks on the status row and by nothing else.
  @State private var shownReasons = ReasonLines.none

  private var displayID: CGDirectDisplayID { state.display.id }

  /// The coordinator's sample, which since synthesis carries the engine's
  /// pairing (SS1): the predicates below are the SS7 carve-out and they answer
  /// "ordinary mirror set" for everything on an un-stamped one.
  private var topology: MirrorTopology { coordinator.topology }

  /// True when this panel is showing a synthesized size (SS7). The ONE predicate
  /// behind every carve-out in this file; it lives in `MirroringPredicates`, and
  /// the panel's section and the display hero read the same one.
  private var isSynthesized: Bool {
    MirroringPredicates.isSynthesized(topology, displayID: displayID)
  }

  /// The displays this section may speak about: everything except the virtual
  /// displays synthesis is rendering onto. `MirroringPredicates` says why the
  /// physical panel of a synthesis set stays in the list.
  private var userVisibleDisplays: [ConfiguredDisplay] {
    MirroringPredicates.userVisibleDisplays(topology)
  }

  /// Displays that can own a set: anything not locked into one. Sorted by id,
  /// like every other list this feature hands out — never enumeration order.
  ///
  /// The built-in is INCLUDED, unlike in the hotkey's automatic scan. A person
  /// naming a master by hand is not a heuristic guessing for them, and
  /// `MirrorTopologyPolicy.engage` accepts it for exactly that reason. A
  /// synthesis VD is not: nobody chose it, it exists to render one panel's size,
  /// and picking it here would offer to mirror the machine onto a display that
  /// disappears the moment the size does.
  private var eligibleMasters: [ConfiguredDisplay] {
    userVisibleDisplays
      .filter { !$0.isAlwaysInMirrorSet }
      .sorted { $0.id < $1.id }
  }

  /// The set this display belongs to, as `MirrorTopologyPolicy.disengage` will
  /// read it: the members, id-ascending, intersected with the sample. EMPTY for
  /// a synthesis set, which is what keeps this pane's Stop control, its status
  /// line and its locked-member sentences off a set the user did not build.
  private var setMembers: [CGDirectDisplayID] {
    isSynthesized ? [] : topology.setMembers(containing: displayID)
  }

  private var isInSet: Bool { !setMembers.isEmpty }

  /// Never true for a synthesized panel. `isAlwaysInMirrorSet` is macOS refusing
  /// to release a set, and the caption it drives says so; over a set Candela
  /// engaged that sentence blames the wrong party, and the Stop button it
  /// disables is not the control that takes a synthesized size down.
  private var isLocked: Bool { !isSynthesized && topology.cannotBeUnmirrored(displayID) }

  /// Members macOS will not release. Not the same question as `isLocked`, which
  /// is about THIS display only — a perfectly free master can be in a set full
  /// of them, and that is the shape every overclaim below was hiding.
  private var lockedMembers: [ConfiguredDisplay] {
    let members = Set(setMembers)
    return topology.displays.filter { members.contains($0.id) && $0.isAlwaysInMirrorSet }
  }

  /// `MirrorTopologyPolicy.dissolve`'s eligibility rule, re-read here from the
  /// same sample the button will act on: **a set is broken by removing its
  /// SLAVES**, so if no slave can be removed the set survives whatever is
  /// staged, and the policy REFUSES rather than disengaging.
  ///
  /// Read so the button can be dead-with-a-reason instead of live-and-refusing.
  /// Clicking it in that state was reachable and printed a sentence about this
  /// display being mirrored and locked when it is neither — this is the same
  /// judgement, made before the click instead of after it. It is not a second
  /// opinion about the topology: the answer comes from `topology`, the
  /// coordinator's own sample, and the policy re-decides on a fresh one anyway.
  private var canBreakSet: Bool {
    let members = Set(setMembers)
    return topology.displays.contains {
      members.contains($0.id) && $0.isMirrorSlave && !$0.isAlwaysInMirrorSet
    }
  }

  // Rows, not a `Section`, since Task 13: the hub's Display section hosts
  // these inline (spec §4 — "status row + the existing three-branch control").
  var body: some View {
    let _ = model.prefsRevision
    Group {
      LabeledContent(MirroringCopy.statusLabel) {
        // A synthesized panel reads "Not mirrored" here, and it is the true
        // answer to what this row asks: the user is mirroring nothing. The set
        // it is in belongs to the size in force, which the size picker states in
        // its own words. "Showing <virtual display>" would name a display nobody
        // has, two rows under a control offering to start mirroring.
        Text(verbatim: MirroringPredicates.statusLine(
          topology, displayID: displayID, name: name
        ))
        .foregroundStyle(.secondary)
      }
      // The mirror's two hooks hang HERE, on the one row of this section that is
      // always present: a hook on the reason lines' own container would only
      // exist while a reason does, so nothing would be watching for the arrival.
      // The appear sync is deliberately un-animated, or a reason still standing
      // when the pane opens would fade in as though it had just happened.
      .onAppear { shownReasons = reasonLines }
      .onChange(of: reasonLines) { _, lines in
        withAnimation(Motion.notice(reduceMotion: reduceMotion)) { shownReasons = lines }
      }

      if isLocked {
        // Named and DISABLED, never hidden, and the words travel in the SAME
        // `Form` row as the dead button. `DisplayModeCoordinator` makes this
        // argument for the mode picker and it holds here with more force:
        // mirroring is a hotkey in this app, so a control that vanished when a
        // set formed would appear and vanish under the user's hands. Which
        // displays actually report `isAlwaysInMirrorSet` on macOS 26 is
        // UNVERIFIED — Sidecar and AirPlay are the suspects — which is exactly
        // why it is a stated reason rather than a bare grey button.
        stopControl(enabled: false, caption: SettingsCaption(MirroringCopy.cannotBeUnmirrored))
      } else if isInSet {
        stopControl(enabled: canBreakSet && !coordinator.isApplying, caption: stopCaption)
      } else {
        startControls
      }

      // The three reason lines are the only rows here that arrive and leave on
      // their own, so they are the only ones that animate, and they render from
      // the mirror rather than from the coordinator. The control block above
      // swaps `_ConditionalContent` branches and rebuilds its control, reading
      // the coordinator directly. It is observed to stay instant, and the reason
      // is timing rather than a guarantee: today the topology change lands in the
      // commit before the mirror write, so the branch swap is already outside the
      // animated transaction. Reorder those two and the control could pick the
      // fade up.
      // Every refusal states a reason and there are EIGHT of them, each with its
      // own sentence; three of the eight are the only ones this pane can say
      // without asserting something it does not know. See `refusalCaption`,
      // which switches over all eight with no `default:` arm.
      if let refusal = shownReasons.refusal {
        refusalCaption(refusal)
          .transition(.opacity)
      }
      if let failure = shownReasons.failure {
        // The CoreGraphics code is diagnostic and stays out of the sentence.
        SettingsCaption(MirroringCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
          .transition(.opacity)
      }
      // A break that committed exactly what it staged and STILL left a set
      // standing. `MirrorToggleDecision.disengage` carries `residualMembers` for
      // this sentence alone: a locked slave keeps mirroring, which keeps its
      // master a master. Binding that residue and not rendering it would report
      // "mirroring off" over a set the user is still looking at: the
      // silent-success defect this whole feature exists to close, re-created one
      // layer out.
      //
      // Rendered in EVERY display's pane, unlike the five suppressed refusals
      // above, and that is deliberate rather than an oversight: this sentence
      // NAMES the displays it is about (or falls back to a count), so it makes
      // no claim about the pane it lands in and cannot be false there.
      if !shownReasons.partialBreak.isEmpty {
        SettingsCaption(verbatim: MirroringCopy.partialBreak(
          residual: shownReasons.partialBreak, name: name
        ))
        .transition(.opacity)
      }
    }
  }

  /// The three reason signals, carried WHOLE rather than as three bools: one
  /// refusal replacing another is a different sentence, five of the eight
  /// refusals render nothing at all, and the sentences differ in height, so the
  /// mirror has to move for a change that leaves the row count alone.
  private struct ReasonLines: Equatable {
    var refusal: MirrorRefusal?
    var failure: DisplayConfigError?
    var partialBreak: [CGDirectDisplayID]

    static let none = ReasonLines(refusal: nil, failure: nil, partialBreak: [])
  }

  private var reasonLines: ReasonLines {
    ReasonLines(
      refusal: coordinator.lastRefusal,
      failure: coordinator.lastFailure,
      partialBreak: coordinator.lastPartialBreak
    )
  }

  /// The refusals this pane can state TRUTHFULLY, and no others.
  ///
  /// `lastRefusal` is ONE property on the coordinator, written by the hotkey and
  /// by every display's pane alike, and nothing on it records which display it
  /// was about. Five of the eight sentences name a display deictically, and this
  /// pane cannot vouch for the referent: a hotkey refusal of `.notInASet` would
  /// otherwise render "This display is not mirroring anything." inside the pane
  /// of a display that IS mirroring, contradicting the Status row two rows above
  /// it. Even a refusal this pane caused can be about a different display — the
  /// picker names the master, and `.masterIsAlwaysMirrored` is a fact about that
  /// display, not about this one.
  ///
  /// Nothing is unreachable as a result. `MirroringCoordinator.syncConfirmation`
  /// presents the report window for exactly the condition that sets any of these
  /// three properties, so every refusal is on screen — with the button that
  /// clears it — whether or not this section repeats it.
  ///
  /// The complete fix is a coordinator change: attribute each signal to the
  /// display it concerns, then gate on that instead of on the phrasing. Until
  /// then this is the half a view can do without asserting something it does not
  /// know. NO `default:` arm — a new case must be a compile error here, not a
  /// silent suppression.
  @ViewBuilder private func refusalCaption(_ refusal: MirrorRefusal) -> some View {
    switch refusal {
    // A statement about the MACHINE. True in any pane on it.
    case .onlyOneDisplay: SettingsCaption(MirroringCopy.needsASecondDisplay)
    // Also about the machine: no display on it can own a set.
    case .noEligibleMaster: SettingsCaption(MirroringCopy.noEligibleMaster)
    // Names its members, so it asserts nothing about this display.
    case let .setCannotBeBroken(members):
      SettingsCaption(verbatim: MirroringCopy.setCannotBeBroken(members: members, name: name))
    // "That display is no longer connected." — no referent in a pane that did
    // not necessarily ask about it.
    case .noSuchDisplay: EmptyView()
    // "macOS keeps this display mirrored to another one…" — about the master
    // that was named, which is frequently not this display.
    case .masterIsAlwaysMirrored: EmptyView()
    // "…mirrored onto this one" — same problem, same direction.
    case .nothingToMirror: EmptyView()
    // "Every display that can mirror this one already is." — "this one" is the
    // named master, frequently not this pane's display. Same suppression as
    // its neighbours.
    case .alreadyMirrored: EmptyView()
    // "This display is not mirroring anything." — the one that contradicts the
    // Status row outright.
    case .notInASet: EmptyView()
    }
  }

  // MARK: - Breaking a set

  /// The break button, in both states it is ever offered in. ONE builder so the
  /// disabled case cannot drift into a different LABEL or a different shape from
  /// the enabled one — the whole point of never hiding it is that the user sees
  /// the same control either way. Only the sentence under it differs, because
  /// "what this button does" and "why this button is dead" are different facts.
  ///
  /// The caption is the row's own caption, never a `SettingsCaption` placed
  /// after it: a caption as its own row gets a divider above it and full row
  /// padding, so it reads as a separate setting rather than as the explanation
  /// for the button — measured in the forced-render capture for this task.
  private func stopControl(enabled: Bool, caption: SettingsCaption) -> some View {
    SettingRow(caption: caption) {
      Button(MirroringCopy.stopMirroring) {
        // Fire-and-forget into the coordinator's queue — the queue is what
        // serialises two fast clicks, so wrapping this in a `Task` here would
        // defeat it.
        coordinator.disengage(containing: displayID)
      }
      .accessibilityLabel(Text(MirroringCopy.stopMirroring))
      .disabled(!enabled)
    }
  }

  /// What the Stop button will actually do, or why it will do nothing — one of
  /// four sentences, because there are four shapes and the brief's single
  /// sentence ("Returns every display in the set to its own desktop. Nothing
  /// else changes.") is a promise only the first of them keeps.
  ///
  /// Ordered by which fact outlives the others: a set that cannot be broken
  /// stays unbreakable after the current apply finishes, so that reason comes
  /// first; `isApplying` is transient and comes next; the two working shapes
  /// differ only in what the apply will leave behind.
  private var stopCaption: SettingsCaption {
    if !canBreakSet {
      // The same members `dissolve` would refuse with, named the same way — the
      // sentence is about them, never about this display, which in this shape is
      // typically an unlocked master that is neither mirrored nor locked.
      return SettingsCaption(
        verbatim: MirroringCopy.setCannotBeBroken(members: setMembers, name: name)
      )
    }
    if coordinator.isApplying { return SettingsCaption(MirroringCopy.applyInProgress) }
    return SettingsCaption(
      lockedMembers.isEmpty
        ? MirroringCopy.stopExplanation
        : MirroringCopy.stopExplanationSomeLocked
    )
  }

  // MARK: - Building a set

  @ViewBuilder private var startControls: some View {
    // "on every other display" is what `MirrorTopologyPolicy.engage` does only
    // when nothing on the machine is locked into a set: a locked display is
    // never staged, because the change cannot succeed and one failed stage
    // cancels the whole transaction. On a rig that has one, the promise is
    // narrower and the sentence says so.
    SettingRow(
      userVisibleDisplays.contains(where: \.isAlwaysInMirrorSet)
        ? MirroringCopy.startExplanationSomeLocked
        : MirroringCopy.startExplanation
    ) {
      Picker(MirroringCopy.pickMaster, selection: Binding(
        get: { selectedMaster },
        set: { chosenMaster = $0 }
      )) {
        ForEach(eligibleMasters) { display in
          Text(verbatim: name(display.id)).tag(Optional(display.id))
        }
      }
      .disabled(!canStart)
    }
    // The reason the button is dead travels IN the button's row, not as a row of
    // its own — a control that is grey with nothing attached is a control nobody
    // can act on, and a sentence a divider away from it reads as a different
    // setting rather than as its explanation.
    SettingRow(cannotStartReason) {
      Button(MirroringCopy.startMirroring) {
        guard let selectedMaster else { return }
        coordinator.engage(master: selectedMaster)
      }
      .accessibilityLabel(Text(MirroringCopy.startMirroring))
      .disabled(!canStart || selectedMaster == nil)
    }
  }

  private var canStart: Bool { cannotStartReason == nil }

  /// Why mirroring cannot be started right now, or nil when it can.
  ///
  /// Four different sentences rather than one, for the same reason
  /// `MirrorTopologyPolicy.engage` has four refusals rather than one:
  /// "mirroring needs a second display" is FALSE on a machine that has two, one
  /// of which macOS keeps locked to a set. The Kit already refuses to conflate
  /// those; a UI that conflated them anyway would put the wrong sentence on
  /// screen before the Kit ever got asked.
  ///
  /// The fourth is `isApplying`, and it is here rather than in a separate
  /// `.disabled` because that is what made the button grey with NOTHING attached
  /// while a change was in flight — the one shape R8 forbids outright. It is
  /// checked last: the structural reasons still hold once the apply finishes,
  /// and this one does not.
  private var cannotStartReason: LocalizedStringKey? {
    guard eligibleMasters.count < 2 else {
      return coordinator.isApplying ? MirroringCopy.applyInProgress : nil
    }
    // An empty sample lands here too, and this is the truth on the rig it
    // actually happens on — a laptop with nothing plugged in. Same reading as
    // `MirrorRefusal.onlyOneDisplay`. Counted over the displays the user has:
    // a lone panel rendering a synthesized size would otherwise count its own
    // virtual display as the second one and be told macOS keeps the rest locked.
    if userVisibleDisplays.count < 2 { return MirroringCopy.needsASecondDisplay }
    if !userVisibleDisplays.contains(where: { $0.id == displayID }) {
      return MirroringCopy.noSuchDisplay
    }
    return MirroringCopy.nothingToMirror
  }

  /// The picker's value, reconciled against the live topology on every read
  /// rather than seeded once.
  ///
  /// Seeding in `.onAppear` is not enough: displays come and go while this pane
  /// is open, and a `Picker` whose selection names a display no longer in its
  /// options renders EMPTY, which reads as a bug. Falling back to this display —
  /// the one the user opened — is the useful default.
  private var selectedMaster: CGDirectDisplayID? {
    if let chosenMaster, eligibleMasters.contains(where: { $0.id == chosenMaster }) {
      return chosenMaster
    }
    return eligibleMasters.first { $0.id == displayID }?.id ?? eligibleMasters.first?.id
  }

  // MARK: - Naming

  /// The user's name for a display, falling back to the name the topology
  /// carries.
  ///
  /// The fallback is load-bearing rather than defensive.
  /// `MirroringCoordinator.displayName` resolves through
  /// `AppModel.allControlledStates`, and a display can be in the topology
  /// without being in that list at all — `DisplayDiscovery` filters on a
  /// non-nil `IOAVService`, so a virtual, AirPlay or Sidecar display is
  /// enumerated by CoreGraphics and controlled by nothing. Those are precisely
  /// the displays that can be locked into a set, i.e. the ones this section most
  /// needs to be able to name. Without the fallback they would render as blank
  /// picker rows and as "Showing " with nothing after it.
  private func name(_ id: CGDirectDisplayID) -> String {
    let friendly = coordinator.displayName(id)
    if !friendly.isEmpty { return friendly }
    return topology.displays.first { $0.id == id }?.name ?? ""
  }
}
