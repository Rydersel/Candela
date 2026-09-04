import CandelaKit
import CoreGraphics
import SwiftUI

/// Quick resolution switching for one display, inside the menu-bar panel.
///
/// **Not a `Menu`, and it cannot be one.** The panel is a SwiftUI view hosted in
/// a custom-view `NSMenuItem` inside a real `NSMenu`, and a nested SwiftUI `Menu`
/// never opens there: the enclosing menu owns event tracking, so the inner one is
/// dead on arrival. Measured for the HDR control in `PanelView`, which is a
/// cycling button for exactly this reason. A resolution list cannot be a cycling
/// button either, since each press would start a countdown on a mode nobody asked
/// for, so it is an inline disclosure: one row collapsed, the top few sizes open.
///
/// The full list, the refresh-rate picker, the badges and the remember toggle
/// stay in Settings, where there is room.
///
/// **Which surface is the headline, settled once:** this one is the most SEEN,
/// which is why a reapply report renders here even when the list does not. The
/// settings hub's Size pop-up is the offering surface of record, holding every
/// curated size against this list's five-row shortcut, so a mark that exists to
/// be read while choosing goes there first and comes here only if it fits
/// without truncating a 280 pt row. Neither curated list carries the "Added by
/// Candela" source mark; it lives on Settings' All Sizes page.
///
/// The density model's "Recommended" mark DOES come here, because the two marks
/// answer different questions. The source mark explains why a row is on the list,
/// worth a sentence and no hurry; "Recommended" names the row worth pressing,
/// which is the whole point of a five-row shortcut, and it is one word riding in
/// the bracket the tags already occupy.
///
/// This view never enumerates: `StatusItemController.warmModeCatalogs` does it
/// outside the tracking session, because a `.task` here would be starved while
/// the menu is open and the section would be missing on the open that wanted it.
///
/// `@MainActor` for the same reason as `DisplayHubView`: it stores
/// main-actor types and reads them from computed properties, which are
/// nonisolated on a plain `View` under complete concurrency checking.
@MainActor
struct PanelResolutionSection: View {
  /// Enough to switch between the sizes someone actually alternates between,
  /// without turning the panel into a wall.
  static let maximumRows = 5

  let displayID: CGDirectDisplayID
  let displayName: String
  let coordinator: DisplayModeCoordinator
  /// One expansion for the whole panel: a rig with four displays must not be
  /// able to open four lists at once and push the footer off the screen.
  ///
  /// Keyed by (display, SECTION) rather than by display alone, since mirroring
  /// has a disclosure of its own. With a bare id, opening this display's
  /// mirroring row would open its resolution list underneath at the same time,
  /// because both tests are `== displayID`.
  @Binding var expanded: PanelDisclosureID?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }
  private var isExpanded: Bool { expanded == PanelDisclosureID(displayID, .resolution) }

  /// True while this display has a preview waiting to be kept or reverted. The
  /// answer is in the confirmation panel on the display itself, so the rows
  /// here stand down rather than offering a second, competing change.
  private var isAwaitingAnswer: Bool { coordinator.preview?.displayID == displayID }

  private var report: DisplayModeCoordinator.ReapplyReport? {
    coordinator.report(for: displayID)
  }

  var body: some View {
    // One usable size is not a choice, so the control is absent rather than
    // present-and-dead. A nil catalog is "not enumerated yet" (never "no
    // modes"), and renders as nothing for the same reason.
    if let catalog, catalog.rows.count > 1 {
      VStack(alignment: .leading, spacing: 2) {
        disclosureRow(catalog)
        if isExpanded {
          // One container so the whole list shares one fade: the rows dim as a
          // block while the animated layout supplies the vertical unfurl.
          VStack(alignment: .leading, spacing: 2) {
            ForEach(catalog.rows.prefix(Self.maximumRows)) { row in
              PanelModeRow(
                // Tagged and marked, like every other surface that OFFERS a
                // size to choose from: the size label is bare, so these words
                // are the whole of the copy rule here.
                //
                // Width, measured at 280 pt: "1440 × 2560 (HiDPI, Scaled)" on
                // the Dell fit with room to spare, and the row truncates rather
                // than wraps, so the worst case is "1440 × 2560 (Scaled,
                // Recommended)".
                title: catalog.badgedSize(row.mode),
                accessibilityName: displayName,
                isCurrent: catalog.isCurrentSize(row.mode)
              ) {
                apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
              }
            }
            .disabled(coordinator.isApplying || isAwaitingAnswer)
            overflowCaption(catalog)
          }
          .transition(.opacity)
        }
        if isAwaitingAnswer {
          PanelCaption("Waiting for you to keep or revert the new resolution on \(displayName).", style: .tertiary)
        }
        startFailure
        synthesisRefusal
        reapplyReport
      }
    } else if report != nil || refusal != nil {
      // The list is absent (one usable size, or none) and a reapply still had
      // something to say about this display. This is the surface most people
      // see, and a report that renders only when a picker is worth drawing goes
      // missing exactly on the displays with the fewest options. A synthesis
      // refusal joins it for the same reason, plus one of its own: the
      // unattended reapply at launch can produce one on a short list.
      VStack(alignment: .leading, spacing: 2) {
        synthesisRefusal
        reapplyReport
      }
    }
  }

  // MARK: - Rows

  private func disclosureRow(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    PanelDisclosureRow(
      title: "Resolution",
      // The size the display is actually running, not the row that happens to
      // be checked: they differ when the current size fell below the curation
      // floor, and the summary must describe the display, not our list.
      //
      // The only place in the app that offers a size WITHOUT its tags, and
      // deliberately: it is not an offer, it reports what the display is
      // running, and the tags are one click away on the rows this expands to.
      // Width agrees: this shares a 280 pt row with the word "Resolution" and a
      // chevron, and "1296 × 2304 (HiDPI, Scaled)" truncated on the Dell.
      //
      // The RATE does ride along: "resolution" is a size and a refresh rate, and
      // this row is the only place the menu bar states either. A 175 Hz panel
      // quietly running at 60 is exactly what someone opens this to find out. It
      // costs 50 pt of the row's slack (measured at 12 pt system: 72.4 to 122.2,
      // against the 161.6 that truncated).
      // `onScreen`, never the raw readback: while a size this app renders is
      // engaged the readback names the display's native geometry, and this row
      // is the only place in the menu bar that states what is running.
      detail: catalog.onScreen.map(summary),
      spokenDetail: catalog.onScreen.map(spokenSummary),
      accessibilityName: displayName,
      accessibilityRole: "resolution",
      isExpanded: isExpanded
    ) {
      // Animated HERE, not via .animation on the container: only the click
      // should animate. The menu-close reset in PanelView and a catalog
      // refresh mid-open must land instantly.
      withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
        expanded = isExpanded ? nil : PanelDisclosureID(displayID, .resolution)
      }
    }
  }

  private func summary(_ mode: DisplayMode) -> String {
    "\(DisplayModeCopy.size(mode)) · \(DisplayModeCopy.refresh(mode.refreshHz))"
  }

  /// The same statement in words. "×" and "·" are read inconsistently at most
  /// verbosities, and unseparated digits are read one at a time.
  private func spokenSummary(_ mode: DisplayMode) -> String {
    ModeSpeech.spoken(
      logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight,
      refreshHz: mode.refreshHz
    )
  }

  /// Says where the rest are: the panel shows the top few by design, and a
  /// truncated list with no exit is the kind of thing people file bugs about. It
  /// claims nothing about what macOS shows or hides, only what THIS list left
  /// out.
  @ViewBuilder private func overflowCaption(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    if catalog.rows.count > Self.maximumRows {
      PanelCaption("All sizes and refresh rates are in Settings.", style: .tertiary)
    }
  }

  /// The SECOND place a failed `begin()` is reported, not the first.
  ///
  /// Tracking ends on selection, so by the time a failure lands this view is
  /// gone, and a failure nobody is shown on a path where the screen also did not
  /// change is indistinguishable from the feature not working.
  /// `DisplayModeCoordinator.syncConfirmation` is what actually reaches the user.
  /// This row stays because it is correct on reopen and the failure is about a
  /// control that lives here.
  @ViewBuilder private var startFailure: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      PanelReportRow(text: Text(DisplayModeCopy.startFailure(failure.reason))) {
        coordinator.dismissStartFailure()
      }
      // No `.help` here: nothing in the menu bar's panel delivers a tooltip, so
      // one attached here would be a string nobody can read. The same diagnostic
      // reaches the user from the confirmation window and the settings banner,
      // both ordinary windows.
    }
  }

  /// A synthesized size that did not engage, or a teardown that did not finish
  /// (`SynthesisFailure.unwindIncomplete`).
  ///
  /// The panel can pick a synthesized stop: `badgedSize` marks it and the rows
  /// above apply it like any other size. So the refusal has to be answerable
  /// here as well as in the settings window, or a stop refused from the menu
  /// bar would change nothing and say nothing.
  ///
  /// Same dismissal as everywhere else, against the coordinator's one refusal
  /// slot: OK here clears the settings banner too, which is right, because it
  /// is one answer to one request rather than one notice per surface.
  @ViewBuilder private var synthesisRefusal: some View {
    if let refusal, let synthesis = coordinator.synthesis {
      PanelReportRow(text: Text(SynthesisCopy.refusal(refusal.reason))) {
        synthesis.dismissRefusal()
      }
      .padding(.horizontal, 4)
    }
  }

  /// This display's refusal, or nil. One reading for the builder above and for
  /// the branch that renders it with no list.
  private var refusal: SynthesisCoordinator.Refusal? {
    guard let refusal = coordinator.synthesis?.refusal, refusal.displayID == displayID
    else { return nil }
    return refusal
  }

  /// What reapply could not do on this display, at launch or when it
  /// reconnected. Nobody was watching then, so this is the first moment the user
  /// can be told, and it stays until they dismiss it or pick a resolution
  /// themselves. An unplug does not take it away.
  @ViewBuilder private var reapplyReport: some View {
    if let report {
      PanelReportRow(
        text: Text(DisplayModeCopy.reapply(requested: report.requested, notice: report.notice))
      ) {
        // The same call the settings banner's OK makes, against the same key:
        // one dismissal clears the notice on every surface.
        coordinator.dismissReport(forKey: report.key)
      }
      .padding(.horizontal, 4)
    }
  }

  // MARK: - Selection

  private func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // Picking the size already on screen would apply a no-op and then demand
    // "Keep this resolution?" for a change nobody made.
    guard mode.ioModeID != catalog.alreadyOnScreenModeID else { return }
    // No `Task` here: `select` is fire-and-forget into the coordinator's queue,
    // which is what serialises two fast clicks.
    //
    // `.panel`: the answer CANNOT be offered here. This view lives in a menu
    // tracking session that ends on Escape, on a menu-bar click, and possibly
    // on the reconfiguration this very call performs, so the coordinator puts
    // the Keep/Revert surface in a window of its own.
    coordinator.select(mode, on: displayID, from: .panel, surface: .floatingPanel)
    // Ending tracking is the point of this line, not a courtesy.
    //
    // Everything `select` queues (the reconfiguration, the countdown, the
    // confirmation window) is main-actor work, and a tracking session holds the
    // run loop in event-tracking mode and starves exactly that. It is the same
    // fact that moved enumeration out to `StatusItemController`. `isApplying` is
    // raised synchronously, so a starved selection would grey out every display's
    // rows while the screen did not change and nothing said why.
    //
    // Nothing is lost by closing: the confirmation window was built to outlive
    // this menu, so the answer is already somewhere else. Sliders stay put: a
    // drag is an in-place adjustment nothing waits on. The HDR button ends
    // tracking too, for the starvation reason above rather than for this one.
    PanelMenu.endTracking()
  }
}

/// One selectable size. A row-shaped button: the whole row is the hit region (a
/// bare `.plain` button is only as clickable as its text is wide), with hover and
/// pressed states, without which it reads as static text. On a control that
/// reconfigures the screen, a click that feels unregistered invites a second.
private struct PanelModeRow: View {
  let title: String
  /// Same rule as `PanelDisclosureRow`: a bare "2560 × 1440 (Scaled)" told
  /// nobody which display it would change.
  let accessibilityName: String
  let isCurrent: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tint)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(true)
        Text(verbatim: title)
          .font(.system(size: 12))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.leading, 4)
      .padding(.trailing, 6)
      .frame(height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(PanelRowButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    .onDisappear { isHovering = false }
    .accessibilityLabel(Text(verbatim: "\(accessibilityName), \(title)"))
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}
