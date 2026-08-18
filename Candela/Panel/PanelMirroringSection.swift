import CandelaKit
import CoreGraphics
import SwiftUI

/// Mirroring for one display, inside the menu-bar panel.
///
/// **Not a `Menu`, and it cannot be one.** The panel is a SwiftUI view hosted in
/// a custom-view `NSMenuItem` inside a real `NSMenu` (see `StatusItemController`),
/// and a nested SwiftUI `Menu` never opens there — the enclosing menu owns event
/// tracking, so the inner one is dead on arrival. Measured twice already: once
/// for the HDR control in `PanelView`, which is a cycling button for exactly this
/// reason, and again for `PanelResolutionSection`. Mirroring cannot be a cycling
/// button either — each press would reconfigure the rig and start a thirty-second
/// countdown nobody asked for — so it is an inline disclosure, the same shape:
/// one row while collapsed, the action beneath while open.
///
/// **This view never enumerates and never samples.** The topology comes from
/// `MirroringCoordinator`, which re-samples on every screen-parameters
/// notification, outside the tracking session. A `.task` here would be starved
/// while the menu is open and the section would be wrong on exactly the open that
/// wanted it. `MirrorTopology` is the ONE definition of "mirrored" in this app and
/// this view is a reader of it, never a second opinion.
///
/// **The safety answer is not here, and cannot be.** Neither action offers
/// Keep/Revert: this view lives in a tracking session that ends on Escape, on a
/// menu-bar click, and plausibly as a side effect of the very reconfiguration the
/// user just started. `MirrorConfirmationWindow` owns the question because it
/// outlives this menu by construction.
///
/// **Nothing here is persisted (DT20).** Mirroring is deliberately not a
/// preference: no `PrefName` case, no `PrefPropagation` row, no `DisplayPrefs`
/// write in this file.
///
/// **D29 conditional.** Nothing here disables, greys or hides a volume, mute or
/// DDC control on the basis of mirror state, and no sentence here claims a mirror
/// slave's hardware control is unavailable. Whether an active mirror suppresses a
/// slave's DDC is UNVERIFIED.
///
/// `@MainActor` for the same reason as `PanelResolutionSection`: a `View`'s
/// stored and computed properties other than `body` are nonisolated under
/// complete concurrency checking, and this one stores main-actor types.
@MainActor
struct PanelMirroringSection: View {
  let displayID: CGDirectDisplayID
  let displayName: String
  let coordinator: MirroringCoordinator
  /// One expansion for the whole panel — SHARED with `PanelResolutionSection`,
  /// not a second binding of the same shape. A four-display rig must not be able
  /// to open eight lists at once and push the footer off the screen, and opening
  /// mirroring closes resolution for the same reason.
  ///
  /// Keyed by (display, SECTION), not by display alone. A bare
  /// `CGDirectDisplayID?` shared between the two sections does NOT do this job:
  /// both would test it against the same display's id, so opening this row would
  /// leave the resolution list open underneath it — one binding, two open lists.
  @Binding var expanded: PanelDisclosureID?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The coordinator's sample, which since synthesis carries the engine's
  /// pairing (SS1). Every predicate below is an SS7 carve-out site and answers
  /// "ordinary mirror set" for everything on an un-stamped one.
  private var topology: MirrorTopology { coordinator.topology }
  private var isExpanded: Bool { expanded == PanelDisclosureID(displayID, .mirroring) }

  /// True when this panel is showing a synthesized size (SS7). The ONE predicate
  /// behind this file's carve-outs: the app engaged that set to render a size,
  /// so there is nothing here to stop, list, or explain, and the size picker is
  /// where it is presented.
  private var isSynthesized: Bool { topology.isSynthesisSet(containing: displayID) }

  /// The displays this section may count and speak about: the virtual displays
  /// synthesis renders onto are not among them. A VD is online and would
  /// otherwise be the second display that makes a lone panel look like a rig
  /// worth offering a mirror control to.
  private var userVisibleDisplays: [ConfiguredDisplay] {
    topology.displays.filter { !topology.synthesisMasters.contains($0.id) }
  }

  private var isInSet: Bool {
    !isSynthesized && !topology.setMembers(containing: displayID).isEmpty
  }

  /// Never true for a synthesized panel: `isAlwaysInMirrorSet` drives a caption
  /// about macOS refusing to release a set, and Candela engaged this one.
  private var isLocked: Bool { !isSynthesized && topology.cannotBeUnmirrored(displayID) }

  /// Whether this display is offered the control at all.
  ///
  /// Two clauses, and the second is not redundant.
  ///
  /// The first is the panel's standing rule, the one `PanelResolutionSection`
  /// follows: one usable option is not a choice, so the control is ABSENT rather
  /// than present-and-dead. There is no room in a 280 pt popover to say why a
  /// dead control is dead, and a grey row with no sentence attached is the thing
  /// R8 forbids. Settings shows it in every state, disabled with words, because
  /// there is room there.
  ///
  /// The second says: a display that is IN a set always gets the control, even
  /// when the first clause would drop it. Without it a rig of one unlocked
  /// display plus one macOS keeps locked to a set — Sidecar and AirPlay are the
  /// suspects, and which displays actually report `isAlwaysInMirrorSet` on
  /// macOS 26 is UNVERIFIED — would show a mirror slave no mirroring control at
  /// all. Mirroring is a HOTKEY in this app (`toggleUnlessSingleDisplay`), so a
  /// control that disappeared the instant a set formed would appear and vanish
  /// under the user's hands, and the display it vanished from is precisely the
  /// one the user is looking for it on.
  private var isUsable: Bool {
    userVisibleDisplays.filter { !$0.isAlwaysInMirrorSet }.count >= 2 || isInSet || isLocked
  }

  /// The residue of a break that committed exactly what it staged and STILL left
  /// this display's set standing, or nil when there is none to report here.
  ///
  /// Scoped to the set rather than shown in every section. `lastPartialBreak`
  /// carries no attribution — it is one machine-wide list — so rendering it
  /// unconditionally would repeat one sentence four times on a four-display rig
  /// and claim it was about each of them in turn. A display is concerned by it
  /// when it is one of the survivors, or when it is the master those survivors
  /// are still showing: a locked slave keeps mirroring, which is exactly what
  /// keeps its master a master.
  ///
  /// It is rendered at all because `MirrorToggleDecision.disengage` carries
  /// `residualMembers` for this sentence alone. Binding the residue and not
  /// rendering it would report "mirroring off" over a set the user is still
  /// looking at — the silent-success defect this whole feature exists to close,
  /// re-created one layer out.
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
      // The control is absent — one usable display — and a break still had
      // something to say about this one. Saying it anyway is the point, and it
      // is the same call `PanelResolutionSection` makes for a reapply report on
      // a display with too few sizes to draw a picker for.
      VStack(alignment: .leading, spacing: 2) { partialBreakReport }
    }
  }

  // MARK: - Rows

  private var disclosureRow: some View {
    PanelDisclosureRow(
      title: MirroringCopy.sectionTitle,
      // "Showing Built-in Display" / "Mirrored to 2 displays" / "Not mirrored" —
      // words rather than a badge, so the state survives a screenshot in a bug
      // report. The same sentence Settings and the confirmation window use.
      //
      // A synthesized panel reads "Not mirrored", the true answer to what this
      // row asks: the user is mirroring nothing, and the set behind the size in
      // force is the size picker's to describe. "Showing <virtual display>"
      // would name a display nobody has, over a row offering to start mirroring.
      detail: isSynthesized
        ? MirroringCopy.notMirroredText
        : MirroringCopy.state(topology: topology, displayID: displayID, name: name),
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
  /// disabled, with the reason under it — it does not replace the control with a
  /// sentence. Settings makes this argument through one shared builder so the
  /// disabled case cannot drift into a different label or shape, and it holds
  /// here for the stronger reason: the control must not vanish out from under a
  /// hotkey, and "the button you know is here, and here is why it will not work"
  /// is a different statement from "there is no button".
  @ViewBuilder private var actions: some View {
    if isLocked {
      actionRow(MirroringCopy.stopMirroring, enabled: false) {}
      // Never a bare grey (R8 generalised: no state is carried by shape alone).
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
      // Fire-and-forget into the coordinator's queue — the queue is what
      // serialises two fast clicks, so wrapping this in a `Task` would defeat it.
      action()
      // ENDING TRACKING IS THE POINT OF THIS LINE, not a courtesy.
      //
      // Everything the action queues — the reconfiguration, the countdown, the
      // confirmation window — is main-actor work, and a tracking session holds
      // the run loop in event-tracking mode and starves exactly that. It is the
      // same fact that keeps enumeration out of this view, and it bites harder
      // here: `isApplying` is raised synchronously, so a starved click would grey
      // out every display's rows while the screen did not change and nothing said
      // why.
      //
      // Nothing is lost by closing. The answer was never available here — an
      // engage's Keep/Revert lives in a floating panel on the master, built to
      // outlive this menu — and dismissing on a choice is what a menu does.
      // Sliders and the HDR toggle stay put because they are in-place
      // adjustments, not choices.
      PanelMenu.endTracking()
    }
    .disabled(!enabled || coordinator.isApplying)
  }

  /// What is STILL mirrored after a break that succeeded only partly. Nothing
  /// failed — the transaction committed exactly what was staged, and a locked
  /// slave was never staged — so this is a statement, not an error, and it
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
  /// carries — the same two-step `MirroringSection` uses, and load-bearing for
  /// the same reason. `MirroringCoordinator.displayName` resolves through
  /// `AppModel.allControlledStates`, and a display can be in the topology
  /// without being in that list at all: `DisplayDiscovery` filters on a non-nil
  /// `IOAVService`, so a virtual, AirPlay or Sidecar display is enumerated by
  /// CoreGraphics and controlled by nothing. Those are precisely the displays
  /// that get locked into a set, i.e. the ones this row most needs to be able to
  /// name. Without the fallback the status line would read "Showing " with
  /// nothing after it.
  private func name(_ id: CGDirectDisplayID) -> String {
    let friendly = coordinator.displayName(id)
    if !friendly.isEmpty { return friendly }
    return topology.displays.first { $0.id == id }?.name ?? ""
  }
}
