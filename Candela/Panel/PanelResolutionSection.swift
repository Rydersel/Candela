import CandelaKit
import CoreGraphics
import SwiftUI

/// Quick resolution switching for one display, inside the menu-bar panel.
///
/// **Not a `Menu`, and it cannot be one.** The panel is a SwiftUI view hosted in
/// a custom-view `NSMenuItem` inside a real `NSMenu` (see `StatusItemController`),
/// and a nested SwiftUI `Menu` never opens there — the enclosing menu owns event
/// tracking, so the inner one is dead on arrival. That was measured once already
/// for the HDR control in `PanelView`, which is a cycling button for exactly this
/// reason. A resolution list cannot be a cycling button — each press would start
/// a fifteen-second countdown on a mode nobody asked for — so it is an inline
/// disclosure instead: one row while collapsed, the top few sizes while open.
///
/// The full list, the refresh-rate picker, the badges and the remember toggle
/// stay in Settings, where there is room.
///
/// This view never enumerates: `StatusItemController.warmModeCatalogs` does it
/// outside the tracking session, because a `.task` here would be starved while
/// the menu is open and the section would be missing on the open that wanted it.
///
/// `@MainActor` for the same reason as `DisplayModeSection`: it stores
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
  /// Keyed by (display, SECTION) rather than by display alone since mirroring
  /// gained a disclosure of its own — see `PanelDisclosureID`. With a bare id,
  /// opening this display's mirroring row would have opened its resolution list
  /// underneath at the same time, because both tests are `== displayID`.
  @Binding var expanded: PanelDisclosureID?

  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }
  private var isExpanded: Bool { expanded == PanelDisclosureID(displayID, .resolution) }

  /// True while this display has a preview waiting to be kept or reverted. The
  /// answer is in the confirmation panel on the display itself, so the rows
  /// here stand down rather than offering a second, competing change.
  private var isAwaitingAnswer: Bool { coordinator.preview?.displayID == displayID }

  private var report: DisplayModeCoordinator.ReapplyReport? {
    coordinator.reapplyReports[displayID]
  }

  var body: some View {
    // One usable size is not a choice, so the control is absent rather than
    // present-and-dead. A nil catalog is "not enumerated yet" (never "no
    // modes"), and renders as nothing for the same reason.
    if let catalog, catalog.rows.count > 1 {
      VStack(alignment: .leading, spacing: 2) {
        disclosureRow(catalog)
        if isExpanded {
          ForEach(catalog.rows.prefix(Self.maximumRows)) { row in
            PanelModeRow(
              title: DisplayModeCopy.size(row.mode),
              accessibilityName: displayName,
              isCurrent: catalog.isCurrentSize(row.mode)
            ) {
              apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
            }
          }
          .disabled(coordinator.isApplying || isAwaitingAnswer)
          overflowCaption(catalog)
        }
        if isAwaitingAnswer {
          caption("Waiting for you to keep or revert the new resolution on \(displayName).")
        }
        startFailure
        reapplyReport
      }
    } else if report != nil {
      // The list is absent — one usable size, or none — and a reapply still had
      // something to say about this display. Saying it anyway is the point:
      // this is the surface most people see, and a report that renders only
      // when a picker happens to be worth drawing is a report that goes missing
      // exactly on the displays with the fewest options.
      VStack(alignment: .leading, spacing: 2) { reapplyReport }
    }
  }

  // MARK: - Rows

  private func disclosureRow(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    PanelDisclosureRow(
      title: "Resolution",
      // The size the display is actually running, not the row that happens to
      // be checked: they differ when the current size fell below the curation
      // floor, and the summary must describe the display, not our list.
      detail: catalog.current.map(DisplayModeCopy.size),
      accessibilityName: displayName,
      accessibilityRole: "resolution",
      isExpanded: isExpanded
    ) {
      expanded = isExpanded ? nil : PanelDisclosureID(displayID, .resolution)
    }
  }

  /// Says where the rest are. The panel shows the top few by design, and a
  /// truncated list with no exit is the kind of thing people file bugs about.
  /// It makes no claim about what macOS shows or hides — only about what THIS
  /// list left out.
  @ViewBuilder private func overflowCaption(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    if catalog.rows.count > Self.maximumRows {
      caption("All sizes and refresh rates are in Settings.")
    }
  }

  /// The SECOND place a failed `begin()` is reported, not the first.
  ///
  /// It used to be the only one, on the reasoning that a failed begin changes
  /// nothing so the menu is still open. Ending tracking on selection made that
  /// false — by the time the failure lands, this view is gone — and a failure
  /// nobody is shown, on a path where the screen also did not change, is
  /// indistinguishable from the feature not working. The confirmation window is
  /// what actually reaches the user now (`DisplayModeCoordinator.syncConfirmation`).
  /// This row stays because it is correct on reopen and the failure is about a
  /// control that lives here.
  @ViewBuilder private var startFailure: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(DisplayModeCopy.startFailure)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("OK") { coordinator.dismissStartFailure() }
          .buttonStyle(.link)
          .font(.system(size: 11))
          .fixedSize()
      }
      .help("CoreGraphics error \(failure.error.cgErrorCode)")
    }
  }

  /// What reapply could not do on this display, at launch or when it
  /// reconnected. Nobody was watching then, so this is the first moment the
  /// user can be told — it stays until they dismiss it, pick a resolution
  /// themselves, or unplug the display.
  @ViewBuilder private var reapplyReport: some View {
    if let report {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(DisplayModeCopy.reapply(requested: report.requested, notice: report.notice))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("OK") { coordinator.dismissReapplyReport(for: displayID) }
          .buttonStyle(.link)
          .font(.system(size: 11))
          .fixedSize()
      }
      .padding(.horizontal, 4)
    }
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
  }

  // MARK: - Selection

  private func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // Picking the size already on screen would apply a no-op and then demand
    // "Keep this resolution?" for a change nobody made.
    guard mode.ioModeID != catalog.current?.ioModeID else { return }
    // No `Task` here — `select` is fire-and-forget into the coordinator's
    // queue, which is what serialises two fast clicks.
    //
    // `.panel`: the answer CANNOT be offered here. This view lives in a menu
    // tracking session that ends on Escape, on a menu-bar click, and possibly
    // on the reconfiguration this very call performs, so the coordinator puts
    // the Keep/Revert surface in a window of its own.
    coordinator.select(mode, on: displayID, from: .panel)
    // Ending tracking is the point of this line, not a courtesy.
    //
    // Everything `select` queues — the reconfiguration, the countdown, the
    // confirmation window — is main-actor work, and a tracking session holds the
    // run loop in event-tracking mode and starves exactly that. It is the same
    // fact that moved enumeration out to `StatusItemController`, and it bites
    // harder here: `isApplying` is raised synchronously, so a starved selection
    // would grey out every display's rows while the screen did not change and
    // nothing said why. Closing the menu makes the queued work runnable at once,
    // whether or not the starvation turns out to be total.
    //
    // Nothing is lost by closing. The confirmation window was built to outlive
    // this menu, so the answer is already somewhere else — and dismissing on a
    // choice is what a menu does. Sliders and the HDR toggle stay put because
    // they are in-place adjustments, not choices.
    PanelMenu.endTracking()
  }
}

/// One selectable size. A row-shaped button: the whole row is the hit region (a
/// bare `.plain` button is only as clickable as its text is wide), with hover
/// and pressed states, without which it reads as static text — and on a control
/// that reconfigures the screen, a click that feels unregistered invites a
/// second one.
private struct PanelModeRow: View {
  let title: String
  /// Same rule as `PanelDisclosureRow`: a bare "Looks like 2560 × 1440" told
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
