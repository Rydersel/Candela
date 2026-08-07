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

  /// The master the user has picked, or nil while they have picked nothing.
  /// Never read directly — `selectedMaster` reconciles it against the live
  /// topology first, because a display can depart between the pick and the
  /// click.
  @State private var chosenMaster: CGDirectDisplayID?

  private var displayID: CGDirectDisplayID { state.display.id }
  private var topology: MirrorTopology { coordinator.topology }

  /// Displays that can own a set: anything not locked into one. Sorted by id,
  /// like every other list this feature hands out — never enumeration order.
  ///
  /// The built-in is INCLUDED, unlike in the hotkey's automatic scan. A person
  /// naming a master by hand is not a heuristic guessing for them, and
  /// `MirrorTopologyPolicy.engage` accepts it for exactly that reason.
  private var eligibleMasters: [ConfiguredDisplay] {
    topology.displays
      .filter { !$0.isAlwaysInMirrorSet }
      .sorted { $0.id < $1.id }
  }

  /// The set this display belongs to, as `MirrorTopologyPolicy.disengage` will
  /// read it: the members, id-ascending, intersected with the sample.
  private var setMembers: [CGDirectDisplayID] { topology.setMembers(containing: displayID) }

  private var isInSet: Bool { !setMembers.isEmpty }
  private var isLocked: Bool { topology.cannotBeUnmirrored(displayID) }

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
        Text(verbatim: MirroringCopy.state(
          topology: topology, displayID: displayID, name: name
        ))
        .foregroundStyle(.secondary)
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

      // Every refusal states a reason and there are EIGHT of them, each with its
      // own sentence — and three of the eight are the only ones this pane can
      // say without asserting something it does not know. See `refusalCaption`,
      // which switches over all eight with no `default:` arm.
      if let refusal = coordinator.lastRefusal {
        refusalCaption(refusal)
      }
      if let failure = coordinator.lastFailure {
        // The CoreGraphics code is diagnostic and stays out of the sentence.
        SettingsCaption(MirroringCopy.applyFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      // A break that committed exactly what it staged and STILL left a set
      // standing. `MirrorToggleDecision.disengage` carries `residualMembers` for
      // this sentence alone: a locked slave keeps mirroring, which keeps its
      // master a master. Binding that residue and not rendering it would report
      // "mirroring off" over a set the user is still looking at — the
      // silent-success defect this whole feature exists to close, re-created one
      // layer out.
      //
      // Rendered in EVERY display's pane, unlike the five suppressed refusals
      // above, and that is deliberate rather than an oversight: this sentence
      // NAMES the displays it is about (or falls back to a count), so it makes
      // no claim about the pane it lands in and cannot be false there.
      if !coordinator.lastPartialBreak.isEmpty {
        SettingsCaption(verbatim: MirroringCopy.partialBreak(
          residual: coordinator.lastPartialBreak, name: name
        ))
      }
    }
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
      topology.displays.contains(where: \.isAlwaysInMirrorSet)
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
    // `MirrorRefusal.onlyOneDisplay`.
    if topology.displays.count < 2 { return MirroringCopy.needsASecondDisplay }
    if !topology.displays.contains(where: { $0.id == displayID }) {
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
