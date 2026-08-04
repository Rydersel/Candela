import CandelaKit
import CoreGraphics
import SwiftUI

/// Mirroring for one display.
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

  private var isInSet: Bool { !topology.setMembers(containing: displayID).isEmpty }
  private var isLocked: Bool { topology.cannotBeUnmirrored(displayID) }

  var body: some View {
    let _ = model.prefsRevision
    Section(MirroringCopy.sectionTitle) {
      LabeledContent("Status") {
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
        stopControl(enabled: false, caption: MirroringCopy.cannotBeUnmirrored)
      } else if isInSet {
        stopControl(
          enabled: !coordinator.isApplying,
          caption: "Returns every display in the set to its own desktop. Nothing else changes."
        )
      } else {
        startControls
      }

      // Every refusal states a reason and there are SEVEN of them, each with its
      // own sentence in `MirroringCopy.refusal`, which switches exhaustively.
      // No `default:` arm here or there: one case used to carry three meanings,
      // one of which was false — telling someone who has just named a perfectly
      // good master that no display can be the master is a wrong statement about
      // their machine, not a rounding error.
      if let refusal = coordinator.lastRefusal {
        SettingsCaption(MirroringCopy.refusal(refusal))
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
      if !coordinator.lastPartialBreak.isEmpty {
        Text(verbatim: MirroringCopy.partialBreak(
          residual: coordinator.lastPartialBreak, name: name
        ))
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
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
  private func stopControl(enabled: Bool, caption: LocalizedStringKey) -> some View {
    SettingRow(caption) {
      Button(MirroringCopy.stopMirroring) {
        // Fire-and-forget into the coordinator's queue — the queue is what
        // serialises two fast clicks, so wrapping this in a `Task` here would
        // defeat it.
        coordinator.disengage(containing: displayID)
      }
      .disabled(!enabled)
    }
  }

  // MARK: - Building a set

  @ViewBuilder private var startControls: some View {
    SettingRow("The display you pick shows its picture on every other display. You get fifteen seconds to keep it.") {
      Picker("Show the picture from", selection: Binding(
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

  private var canStart: Bool { cannotStartReason == nil && !coordinator.isApplying }

  /// Why mirroring cannot be started right now, or nil when it can.
  ///
  /// Three different sentences rather than one, for the same reason
  /// `MirrorTopologyPolicy.engage` has three refusals rather than one:
  /// "mirroring needs a second display" is FALSE on a machine that has two, one
  /// of which macOS keeps locked to a set. The Kit already refuses to conflate
  /// those; a UI that conflated them anyway would put the wrong sentence on
  /// screen before the Kit ever got asked.
  private var cannotStartReason: LocalizedStringKey? {
    guard eligibleMasters.count < 2 else { return nil }
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
