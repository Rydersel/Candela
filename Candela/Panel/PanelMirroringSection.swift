import CandelaKit
import CoreGraphics
import SwiftUI

/// Mirroring for one display, inside the menu-bar panel.
///
/// **Not a `Menu`, and it cannot be one.** The panel is a SwiftUI view hosted in
/// a custom-view `NSMenuItem` inside a real `NSMenu`, and a nested SwiftUI `Menu`
/// never opens there: the enclosing menu owns event tracking, so the inner one is
/// dead on arrival. Measured twice, for the HDR control in `PanelView` and for
/// `PanelResolutionSection`. A cycling button is out too, since each press would
/// reconfigure the rig and start a countdown nobody asked for, so this is an
/// inline disclosure: one row collapsed, the action beneath while open.
///
/// **This view never enumerates and never samples.** The topology comes from
/// `MirroringCoordinator`, which re-samples on every screen-parameters
/// notification, outside the tracking session. A `.task` here would be starved
/// while the menu is open, so the section would be wrong on exactly the open that
/// wanted it. `MirrorTopology` is the ONE definition of "mirrored" in this app;
/// this view reads it and never offers a second opinion.
///
/// **The safety answer is not here, and cannot be.** Neither action offers
/// Keep/Revert: this view lives in a tracking session that ends on Escape, on a
/// menu-bar click, and plausibly as a side effect of the very reconfiguration the
/// user just started. `MirrorConfirmationWindow` owns the question because it
/// outlives this menu by construction.
///
/// **Nothing here is persisted.** No `PrefName` case, no `PrefPropagation`
/// row, no `DisplayPrefs` write in this file.
///
/// **Mute-strand conditional.** Nothing here disables, greys or hides a volume, mute or
/// DDC control on the basis of mirror state. Whether an active mirror suppresses
/// a slave's DDC is UNVERIFIED.
///
/// `@MainActor` for the same reason as `PanelResolutionSection`: a `View`'s
/// stored and computed properties other than `body` are nonisolated under
/// complete concurrency checking, and this one stores main-actor types.
@MainActor
struct PanelMirroringSection: View {
  let displayID: CGDirectDisplayID
  let displayName: String
  let coordinator: MirroringCoordinator
  /// One expansion for the whole panel, SHARED with `PanelResolutionSection`
  /// rather than a second binding of the same shape: a multi-display rig must not
  /// be able to open every list at once and push the footer off the screen.
  ///
  /// Keyed by (display, SECTION), not by display alone. A bare
  /// `CGDirectDisplayID?` shared between the two sections does NOT do this job:
  /// both would test it against the same display's id, so opening this row would
  /// leave the resolution list open underneath it.
  @Binding var expanded: PanelDisclosureID?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The coordinator's sample, which since synthesis carries the engine's
  /// pairing. Every predicate below is a synthesis carve-out site and answers
  /// "ordinary mirror set" for everything on an un-stamped one.
  private var topology: MirrorTopology { coordinator.topology }
  private var isExpanded: Bool { expanded == PanelDisclosureID(displayID, .mirroring) }

  /// True when this panel is showing a synthesized size. The ONE predicate
  /// behind this file's carve-outs; it lives in `MirroringPredicates`, shared
  /// with the settings section and the display hero.
  private var isSynthesized: Bool {
    MirroringPredicates.isSynthesized(topology, displayID: displayID)
  }

  /// The displays this section may count and speak about: the virtual displays
  /// synthesis renders onto are not among them. A VD is online and would
  /// otherwise be the second display that makes a lone panel look like a rig
  /// worth offering a mirror control to.
  private var userVisibleDisplays: [ConfiguredDisplay] {
    MirroringPredicates.userVisibleDisplays(topology)
  }

  private var isInSet: Bool {
    !isSynthesized && !topology.setMembers(containing: displayID).isEmpty
  }

  /// Never true for a synthesized panel: `isAlwaysInMirrorSet` drives a caption
  /// about macOS refusing to release a set, and Candela engaged this one.
  private var isLocked: Bool { !isSynthesized && topology.cannotBeUnmirrored(displayID) }

  /// Whether this display is offered the control at all. Two clauses, and the
  /// second is not redundant.
  ///
  /// The first is the panel's standing rule: one usable option is not a choice,
  /// so the control is ABSENT rather than present-and-dead. The popover has no
  /// room to say why a dead control is dead, and a grey row with no sentence
  /// attached is what that rule forbids. Settings shows it in every state,
  /// disabled with words, because there is room there.
  ///
  /// The second gives the control to any display that is IN a set, even where the
  /// first clause would drop it. Without it, a rig of one unlocked display plus
  /// one macOS keeps locked to a set (Sidecar and AirPlay are the suspects;
  /// which displays report `isAlwaysInMirrorSet` on macOS 26 is UNVERIFIED)
  /// would show a mirror slave no mirroring control at all. Mirroring is a HOTKEY
  /// here, so a control that disappeared the instant a set formed would vanish
  /// from exactly the display the user is looking for it on.
  private var isUsable: Bool {
    userVisibleDisplays.filter { !$0.isAlwaysInMirrorSet }.count >= 2 || isInSet || isLocked
  }

  /// The residue of a break that committed exactly what it staged and STILL left
  /// this display's set standing, or nil when there is none to report here.
  ///
  /// Scoped to the set rather than shown in every section. `lastPartialBreak` is
  /// one machine-wide list with no attribution, so rendering it unconditionally
  /// would repeat one sentence per display and claim it was about each of them. A
  /// display is concerned when it is one of the survivors, or the master those
  /// survivors are still showing.
  ///
  /// Rendering it is the point: binding the residue and staying quiet would
  /// report "mirroring off" over a set the user is still looking at, which is the
  /// silent-success defect this feature exists to close.
  private var partialBreak: [CGDirectDisplayID]? {
    let residual = coordinator.lastPartialBreak
    guard !residual.isEmpty else { return nil }
    let concerns = residual.contains(displayID)
      || residual.contains { topology.master(of: $0) == displayID }
    return concerns ? residual : nil
  }

  var body: some View {
    if isUsable {
      VStack(alignment: .leading, spacing: 2) {
        disclosureRow
        if isExpanded {
          // One container so the open block shares one fade: the animated
          // layout supplies the vertical unfurl, same as the resolution list.
          VStack(alignment: .leading, spacing: 2) { actions }
            .transition(.opacity)
        }
        // OUTSIDE the disclosure, deliberately: a report about what did not
        // happen is not something to make someone go looking for.
        partialBreakReport
      }
    } else if partialBreak != nil {
      // The control is absent (one usable display) and a break still had
      // something to say about this one. Same call `PanelResolutionSection` makes
      // for a reapply report on a display with too few sizes to draw a picker.
      VStack(alignment: .leading, spacing: 2) { partialBreakReport }
    }
  }

  // MARK: - Rows

  private var disclosureRow: some View {
    PanelDisclosureRow(
      title: MirroringCopy.sectionTitle,
      // Words rather than a badge, so the state survives a screenshot in a bug
      // report. The same sentence Settings and the confirmation window use.
      //
      // A synthesized panel reads "Not mirrored", the true answer to what this
      // row asks: the user is mirroring nothing, and the set behind the size in
      // force is the size picker's to describe. "Showing <virtual display>" would
      // name a display nobody has, over a row offering to start mirroring.
      detail: MirroringPredicates.statusLine(topology, displayID: displayID, name: name),
      accessibilityName: displayName,
      accessibilityRole: "mirroring",
      isExpanded: isExpanded
    ) {
      // Animated HERE, not via .animation on the container: only the click
      // should animate. The menu-close reset in PanelView and a topology
      // re-sample mid-open must land instantly.
      withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
        expanded = isExpanded ? nil : PanelDisclosureID(displayID, .mirroring)
      }
    }
  }

  /// What the open disclosure offers, in each of the three states it has.
  ///
  /// The locked case shows the SAME "Stop Mirroring" row as the breakable one,
  /// disabled, with the reason under it. It does not replace the control with a
  /// sentence: the control must not vanish out from under a hotkey, and "here is
  /// the button, and here is why it will not work" says something different from
  /// "there is no button".
  @ViewBuilder private var actions: some View {
    if isLocked {
      actionRow(MirroringCopy.stopMirroring, enabled: false) {}
      // Never a bare grey (the rule generalised: no state is carried by shape alone).
      PanelCaption(MirroringCopy.cannotBeUnmirrored, style: .secondary)
    } else if isInSet {
      actionRow(MirroringCopy.stopMirroring) {
        coordinator.disengage(containing: displayID)
      }
    } else {
      actionRow(MirroringCopy.startMirroring) {
        coordinator.engage(master: displayID)
      }
    }
  }

  private func actionRow(
    _ title: LocalizedStringKey, enabled: Bool = true, _ action: @escaping () -> Void
  ) -> some View {
    PanelActionRow(title: title, accessibilityName: displayName) {
      // Fire-and-forget into the coordinator's queue: the queue is what
      // serialises two fast clicks, so a `Task` wrapper would defeat it.
      action()
      // ENDING TRACKING IS THE POINT OF THIS LINE, not a courtesy.
      //
      // Everything the action queues (the reconfiguration, the countdown, the
      // confirmation window) is main-actor work, and a tracking session holds the
      // run loop in event-tracking mode and starves exactly that. `isApplying` is
      // raised synchronously, so a starved click would grey out every display's
      // rows while the screen did not change and nothing said why.
      //
      // Nothing is lost by closing: the answer was never available here, since an
      // engage's Keep/Revert lives in a floating panel built to outlive this
      // menu. Sliders stay put: a drag is an in-place adjustment nothing waits
      // on. The HDR button ends tracking too, for the starvation reason above.
      PanelMenu.endTracking()
    }
    .disabled(!enabled || coordinator.isApplying)
  }

  /// What is STILL mirrored after a break that succeeded only partly. Nothing
  /// failed: the transaction committed exactly what was staged, and a locked
  /// slave was never staged, so this is a statement rather than an error and it
  /// dismisses rather than retrying.
  @ViewBuilder private var partialBreakReport: some View {
    if let residual = partialBreak {
      PanelReportRow(
        text: Text(verbatim: MirroringCopy.partialBreak(residual: residual, name: name))
      ) {
        coordinator.dismissReport()
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - Naming

  /// The user's name for a display, falling back to the name the topology
  /// carries, the same two-step `MirroringSection` uses.
  /// `MirroringCoordinator.displayName` resolves through
  /// `AppModel.allControlledStates`, and a display can be in the topology without
  /// being in that list: `DisplayDiscovery` filters on a non-nil `IOAVService`,
  /// so a virtual, AirPlay or Sidecar display is enumerated by CoreGraphics and
  /// controlled by nothing. Those are exactly the displays that get locked into a
  /// set. Without the fallback the status line reads "Showing " and stops.
  private func name(_ id: CGDirectDisplayID) -> String {
    let friendly = coordinator.displayName(id)
    if !friendly.isEmpty { return friendly }
    return topology.displays.first { $0.id == id }?.name ?? ""
  }
}
