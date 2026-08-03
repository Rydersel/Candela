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
  @Binding var expandedDisplayID: CGDirectDisplayID?

  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }
  private var isExpanded: Bool { expandedDisplayID == displayID }

  /// True while this display has a preview waiting to be kept or reverted. The
  /// answer is in the confirmation panel on the display itself, so the rows
  /// here stand down rather than offering a second, competing change.
  private var isAwaitingAnswer: Bool { coordinator.preview?.displayID == displayID }

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
      detail: catalog.current.map(DisplayModeCopy.size),
      isExpanded: isExpanded
    ) {
      expandedDisplayID = isExpanded ? nil : displayID
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

  /// A `begin()` that failed changed nothing on the display, so the menu is
  /// still open and this is the right place to say so — unlike the confirm
  /// panel, which exists for previews that ARE applied.
  @ViewBuilder private var startFailure: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("\(AppInfo.productName) could not switch this display. Nothing changed.")
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
  }
}

/// The collapsed header: a title, the current value, and a chevron — the shape
/// Control Center uses for a module that opens.
private struct PanelDisclosureRow: View {
  let title: LocalizedStringKey
  let detail: String?
  let isExpanded: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.system(size: 12))
        Spacer(minLength: 8)
        if let detail {
          Text(verbatim: detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
      .frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(PanelRowButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    // The menu can close without a mouse-exit event (Escape, or clicking the
    // status item), which would leave a phantom highlight on the next open.
    .onDisappear { isHovering = false }
    .accessibilityLabel(Text(title))
    .accessibilityValue(detail.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
  }
}

/// One selectable size. A row-shaped button: the whole row is the hit region (a
/// bare `.plain` button is only as clickable as its text is wide), with hover
/// and pressed states, without which it reads as static text — and on a control
/// that reconfigures the screen, a click that feels unregistered invites a
/// second one.
private struct PanelModeRow: View {
  let title: String
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
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// Hover plus — required for any custom button (`buttons.md`) — a distinct
/// pressed state, in the same visual language as the panel's footer buttons.
private struct PanelRowButtonStyle: ButtonStyle {
  let isHovering: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let hovering = isHovering && isEnabled
    let background: AnyShapeStyle = if configuration.isPressed, isEnabled {
      AnyShapeStyle(.tertiary)
    } else if hovering {
      AnyShapeStyle(.quaternary)
    } else {
      AnyShapeStyle(.clear)
    }
    return configuration.label
      .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(background))
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}
