import CandelaKit
import CoreGraphics
import SwiftUI

/// Mirroring for one display: rows in the hub's Display section, no section of
/// its own. Every decision comes from `MirroringCoordinator`, the ONE definition
/// of "mirrored" in this app; nothing here re-derives a topology, because two
/// samples of one machine disagree exactly when it matters.
///
/// Nothing here is persisted (DT20). Mirroring is not a preference and is not
/// reapplied at launch or on reconnect, so there is no `PrefName` case, no
/// `PrefPropagation` row and no `DisplayPrefWriter` call in this file. Adding
/// one changes shipped on-disk schema.
///
/// D29 conditional: nothing here disables or greys a volume, mute or DDC control
/// on the basis of mirror state. Whether an active mirror suppresses a slave's
/// DDC is UNVERIFIED, and treating it as suppressed would put VCP 0x8D out of
/// reach and could strand a display muted with no way back from inside the app.
///
/// `@MainActor`: a `View`'s non-`body` properties are nonisolated under complete
/// concurrency checking, and this one stores main-actor types.
@MainActor
struct MirroringSection: View {
  let state: AppModel.DisplayState
  let coordinator: MirroringCoordinator

  /// `let _ = model.prefsRevision` IS required here, and the reason is not
  /// obvious: this section reads no pref directly, but every display it NAMES
  /// resolves `DisplayPrefs.friendlyName`, which is plain `UserDefaults` and not
  /// observable. Without it, a rename in the section directly above leaves the
  /// old name standing in the status line and in the picker.
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The master the user has picked, or nil. Never read directly:
  /// `selectedMaster` reconciles it against the live topology first, because a
  /// display can depart between the pick and the click.
  @State private var chosenMaster: CGDirectDisplayID?

  /// The reason lines as RENDERED, one update behind the coordinator's signals.
  /// Neither placement of a keyed `.animation` fades these symmetrically
  /// (measured 2026-08-17): on the wrapping `Group` nothing animates in either
  /// direction, and on an always-present container the child fades IN and SNAPS
  /// out. The only way to get both directions is to write inside a
  /// `withAnimation` here. Kept in agreement by the two hooks on the status row.
  @State private var shownReasons = ReasonLines.none

  private var displayID: CGDirectDisplayID { state.display.id }

  /// The coordinator's sample, carrying the engine's synthesis pairing (SS1).
  /// The predicates below are the SS7 carve-out; on an un-stamped sample they
  /// answer "ordinary mirror set" for everything.
  private var topology: MirrorTopology { coordinator.topology }

  /// True when this panel is showing a synthesized size (SS7). The ONE predicate
  /// behind every carve-out here; the panel's section and the display hero read
  /// the same one.
  private var isSynthesized: Bool {
    MirroringPredicates.isSynthesized(topology, displayID: displayID)
  }

  /// The displays this section may speak about: everything except the virtual
  /// displays synthesis is rendering onto. `MirroringPredicates` says why the
  /// physical panel of a synthesis set stays in the list.
  private var userVisibleDisplays: [ConfiguredDisplay] {
    MirroringPredicates.userVisibleDisplays(topology)
  }

  /// Displays that can own a set: anything not locked into one, sorted by id
  /// rather than enumeration order.
  ///
  /// The built-in is INCLUDED, unlike in the hotkey's automatic scan: a person
  /// naming a master by hand is not a heuristic guessing for them, and
  /// `MirrorTopologyPolicy.engage` accepts it. A synthesis VD is not, because it
  /// disappears the moment the size does.
  private var eligibleMasters: [ConfiguredDisplay] {
    userVisibleDisplays
      .filter { !$0.isAlwaysInMirrorSet }
      .sorted { $0.id < $1.id }
  }

  /// The set this display belongs to, as `MirrorTopologyPolicy.disengage` will
  /// read it. EMPTY for a synthesis set, which keeps the Stop control, the status
  /// line and the locked-member sentences off a set the user did not build.
  private var setMembers: [CGDirectDisplayID] {
    isSynthesized ? [] : topology.setMembers(containing: displayID)
  }

  private var isInSet: Bool { !setMembers.isEmpty }

  /// Never true for a synthesized panel. `isAlwaysInMirrorSet` is macOS refusing
  /// to release a set, so over a set Candela engaged the caption it drives blames
  /// the wrong party and the button it disables is the wrong control.
  private var isLocked: Bool { !isSynthesized && topology.cannotBeUnmirrored(displayID) }

  /// Members macOS will not release. Not the same question as `isLocked`, which
  /// is about THIS display only: a free master can sit in a set full of locked
  /// members, the shape every overclaim below was hiding.
  private var lockedMembers: [ConfiguredDisplay] {
    let members = Set(setMembers)
    return topology.displays.filter { members.contains($0.id) && $0.isAlwaysInMirrorSet }
  }

  /// `MirrorTopologyPolicy.dissolve`'s eligibility rule, re-read from the sample
  /// the button will act on: a set is broken by removing its SLAVES, so with no
  /// removable slave the policy REFUSES rather than disengaging.
  ///
  /// Read so the button is dead-with-a-reason instead of live-and-refusing. Not
  /// a second opinion about the topology: the answer comes from the coordinator's
  /// own sample, and the policy re-decides on a fresh one anyway.
  private var canBreakSet: Bool {
    let members = Set(setMembers)
    return topology.displays.contains {
      members.contains($0.id) && $0.isMirrorSlave && !$0.isAlwaysInMirrorSet
    }
  }

  // Rows, not a `Section`: the hub's Display section hosts these inline.
  var body: some View {
    let _ = model.prefsRevision
    Group {
      LabeledContent(MirroringCopy.statusLabel) {
        // A synthesized panel reads "Not mirrored", the true answer to what
        // this row asks: the user is mirroring nothing, and the set belongs to
        // the size in force. "Showing <virtual display>" would name a display
        // nobody has, two rows under a control offering to start mirroring.
        Text(verbatim: MirroringPredicates.statusLine(
          topology, displayID: displayID, name: name
        ))
        .foregroundStyle(SettingsTheme.bodyColor)
      }
      // Both hooks hang on the one row that is ALWAYS present: a hook on the
      // reason lines' own container would only exist while a reason does, so
      // nothing would watch for the arrival. The appear sync is un-animated, or
      // a reason still standing when the pane opens would fade in as though it
      // had just happened.
      .onAppear { shownReasons = reasonLines }
      .onChange(of: reasonLines) { _, lines in
        withAnimation(Motion.notice(reduceMotion: reduceMotion)) { shownReasons = lines }
      }

      // The status row above is always drawn, so this divider always has two
      // sides.
      SettingsCardDivider()

      if isLocked {
        // Named and DISABLED, never hidden, with the words in the SAME row as
        // the dead button: mirroring is a hotkey in this app, so a control that
        // vanished when a set formed would appear and vanish under the user's
        // hands. Which displays report `isAlwaysInMirrorSet` on macOS 26 is
        // UNVERIFIED (Sidecar and AirPlay are the suspects), which is why the
        // reason is stated rather than left as a bare grey button.
        stopControl(enabled: false, caption: SettingsCaption(MirroringCopy.cannotBeUnmirrored))
      } else if isInSet {
        stopControl(enabled: canBreakSet && !coordinator.isApplying, caption: stopCaption)
      } else {
        startControls
      }

      // The reason lines are the only rows that arrive and leave on their own,
      // so they are the only ones that animate, and they render from the mirror
      // rather than from the coordinator. The control block above stays instant
      // by timing, not by guarantee: the topology change lands in the commit
      // before the mirror write, so its branch swap is already outside the
      // animated transaction. Reorder those two and the control picks up the
      // fade. Which refusals this pane may say at all is `refusalCaption`.
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
      // standing: a locked slave keeps mirroring, which keeps its master a
      // master. Binding that residue and not rendering it would report
      // "mirroring off" over a set the user is still looking at, the
      // silent-success defect this feature exists to close.
      //
      // Rendered in EVERY display's pane, unlike the suppressed refusals above:
      // this sentence NAMES the displays it is about, so it makes no claim about
      // the pane it lands in and cannot be false there.
      if !shownReasons.partialBreak.isEmpty {
        SettingsCaption(verbatim: MirroringCopy.partialBreak(
          residual: shownReasons.partialBreak, name: name
        ))
        .transition(.opacity)
      }
    }
  }

  /// The three signals carried WHOLE rather than as three bools: one refusal
  /// replacing another is a different sentence at a different height, so the
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
  /// by every display's pane alike, with nothing on it recording which display it
  /// was about. Most of the sentences name a display deictically and this pane
  /// cannot vouch for the referent: a hotkey refusal of `.notInASet` would render
  /// "This display is not mirroring anything." in the pane of a display that IS
  /// mirroring. Nothing is unreachable as a result, because
  /// `MirroringCoordinator.syncConfirmation` puts every refusal in the report
  /// window with the button that clears it.
  ///
  /// The complete fix is a coordinator change: attribute each signal to the
  /// display it concerns. NO `default:` arm, so a new case is a compile error
  /// here rather than a silent suppression.
  @ViewBuilder private func refusalCaption(_ refusal: MirrorRefusal) -> some View {
    switch refusal {
    // About the MACHINE, so true in any pane on it.
    case .onlyOneDisplay: SettingsCaption(MirroringCopy.needsASecondDisplay)
    // Also about the machine: no display on it can own a set.
    case .noEligibleMaster: SettingsCaption(MirroringCopy.noEligibleMaster)
    // Names its members, so it asserts nothing about this display.
    case let .setCannotBeBroken(members):
      SettingsCaption(verbatim: MirroringCopy.setCannotBeBroken(members: members, name: name))
    // "That display is no longer connected." No referent in a pane that did
    // not necessarily ask about it.
    case .noSuchDisplay: EmptyView()
    // About the master that was named, frequently not this display.
    case .masterIsAlwaysMirrored: EmptyView()
    // Same problem, same direction.
    case .nothingToMirror: EmptyView()
    // "this one" is the named master, frequently not this pane's display.
    case .alreadyMirrored: EmptyView()
    // The one that contradicts the Status row outright.
    case .notInASet: EmptyView()
    }
  }

  // MARK: - Breaking a set

  /// The break button in both states it is ever offered in. ONE builder so the
  /// disabled case cannot drift into a different label or shape; only the
  /// sentence under it differs.
  ///
  /// The caption rides the row rather than following as a `SettingsCaption`: a
  /// caption on its own row gets a hairline above it and full row padding, so it
  /// reads as a separate setting rather than as the button's explanation.
  private func stopControl(enabled: Bool, caption: SettingsCaption) -> some View {
    SettingRow(caption: caption) {
      Button(MirroringCopy.stopMirroring) {
        // Fire-and-forget into the coordinator's queue: the queue is what
        // serialises two fast clicks, so a `Task` here would defeat it.
        coordinator.disengage(containing: displayID)
      }
      .buttonStyle(SettingsSecondaryButtonStyle())
      .accessibilityLabel(Text(MirroringCopy.stopMirroring))
      .disabled(!enabled)
    }
  }

  /// What the Stop button will do, or why it will do nothing: one sentence per
  /// shape, since "returns every display in the set to its own desktop" is a
  /// promise only the first shape keeps.
  ///
  /// Ordered by which fact outlives the others: an unbreakable set stays
  /// unbreakable after the current apply finishes, while `isApplying` does not.
  private var stopCaption: SettingsCaption {
    if !canBreakSet {
      // The same members `dissolve` would refuse with: the sentence is about
      // them, never about this display, which in this shape is typically an
      // unlocked master that is neither mirrored nor locked.
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
    // never staged, and one failed stage cancels the whole transaction. On a rig
    // that has one, the promise is narrower and the sentence says so.
    SettingRow(
      userVisibleDisplays.contains(where: \.isAlwaysInMirrorSet)
        ? MirroringCopy.startExplanationSomeLocked
        : MirroringCopy.startExplanation
    ) {
      ThemedChoiceRow(label: MirroringCopy.pickMaster, selection: Binding(
        get: { selectedMaster },
        set: { chosenMaster = $0 }
      )) {
        ForEach(eligibleMasters) { display in
          Text(verbatim: name(display.id)).tag(Optional(display.id))
        }
      }
      .disabled(!canStart)
    }
    // The reason the button is dead travels IN the button's row: a sentence a
    // divider away from it reads as a different setting rather than as its
    // explanation.
    SettingRow(cannotStartReason) {
      Button(MirroringCopy.startMirroring) {
        guard let selectedMaster else { return }
        coordinator.engage(master: selectedMaster)
      }
      .buttonStyle(SettingsSecondaryButtonStyle())
      .accessibilityLabel(Text(MirroringCopy.startMirroring))
      .disabled(!canStart || selectedMaster == nil)
    }
  }

  private var canStart: Bool { cannotStartReason == nil }

  /// Why mirroring cannot be started right now, or nil when it can.
  ///
  /// Several sentences rather than one, for the reason
  /// `MirrorTopologyPolicy.engage` has several refusals: "mirroring needs a
  /// second display" is FALSE on a machine that has two, one of which macOS keeps
  /// locked to a set.
  ///
  /// `isApplying` lives here rather than in a separate `.disabled`, which is what
  /// left the button grey with NOTHING attached while a change was in flight (the
  /// shape R8 forbids). Checked last: the structural reasons outlive it.
  private var cannotStartReason: LocalizedStringKey? {
    guard eligibleMasters.count < 2 else {
      return coordinator.isApplying ? MirroringCopy.applyInProgress : nil
    }
    // An empty sample lands here too, which is the truth on a laptop with
    // nothing plugged in. Counted over the displays the user HAS: a lone panel
    // rendering a synthesized size would otherwise count its own virtual display
    // as the second one and be told macOS keeps the rest locked.
    if userVisibleDisplays.count < 2 { return MirroringCopy.needsASecondDisplay }
    if !userVisibleDisplays.contains(where: { $0.id == displayID }) {
      return MirroringCopy.noSuchDisplay
    }
    return MirroringCopy.nothingToMirror
  }

  /// Reconciled against the live topology on every read, not seeded in
  /// `.onAppear`: displays come and go while this pane is open, and a `Picker`
  /// whose selection names a missing display renders EMPTY, which reads as a bug.
  /// The fallback is the display the user opened.
  private var selectedMaster: CGDirectDisplayID? {
    if let chosenMaster, eligibleMasters.contains(where: { $0.id == chosenMaster }) {
      return chosenMaster
    }
    return eligibleMasters.first { $0.id == displayID }?.id ?? eligibleMasters.first?.id
  }

  // MARK: - Naming

  /// The user's name for a display, falling back to the topology's.
  ///
  /// The fallback is load-bearing, not defensive.
  /// `MirroringCoordinator.displayName` resolves through
  /// `AppModel.allControlledStates`, and `DisplayDiscovery` filters that on a
  /// non-nil `IOAVService`, so a virtual, AirPlay or Sidecar display is
  /// enumerated by CoreGraphics and controlled by nothing. Those are exactly the
  /// displays that get locked into a set; without the fallback they render as
  /// blank picker rows and as "Showing " with nothing after it.
  private func name(_ id: CGDirectDisplayID) -> String {
    let friendly = coordinator.displayName(id)
    if !friendly.isEmpty { return friendly }
    return topology.displays.first { $0.id == id }?.name ?? ""
  }
}
