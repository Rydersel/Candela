import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// Every mode one display reports (spec §5).
///
/// The page exists solely to enumerate (SO2): the hub's Size pop-up is the
/// curated answer, and this is the escape hatch behind it — so nothing here is
/// a preference and nothing writes one. Choosing a row goes through the same
/// preview-with-countdown flow the hub's pop-up uses.
///
/// It replaces a `DisclosureGroup` wrapping a 240 pt nested scroller, which had
/// two defects a page does not. A `DisclosureGroup` toggles only from its
/// chevron glyph and never from its label text (measured on this window), so
/// the sole route to a display's 120–332 modes was a glyph-sized target; and
/// the list scrolled inside the pane's own scroller, so reaching a mode meant
/// scrolling one view to get at another.
///
/// `@MainActor` for the reason every settings view records: a `View`'s stored
/// and computed properties other than `body` are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct AllModesPage: View {
  let state: AppModel.DisplayState
  /// The header's display switcher (SO23) — owned by the root view, which is
  /// what "switching" means here (carry the path, move the sidebar selection).
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  /// `Recommended` is the same list the hub's Size pop-up offers, so arriving
  /// here shows what the user just left, and `All` is a deliberate step. The
  /// control sits at the TOP (§5): an expansion control never sits below what
  /// it expands.
  enum ListMode: String, CaseIterable, Hashable {
    case recommended = "Recommended"
    case all = "All"
  }

  @State private var listMode: ListMode = .recommended
  /// nil is "Any". Quantized rates only — `distinctRates` is the source, never
  /// `refreshRates(in:)`, which dedupes raw doubles and would offer 60 twice
  /// the day float noise reached it.
  @State private var rateFilter: Double?
  /// Arrow-key movement within the list (accessibility contract 6). Keyed by
  /// `ioModeID`, which is also the row `.id`, so focus and `scrollTo` speak the
  /// same language.
  @FocusState private var focusedRow: Int32?

  @Environment(AppModel.self) private var model

  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        SubPageHeader(
          title: DisplaySubPage.allModes.title,
          currentKey: state.display.persistenceKey,
          displays: displays,
          onSwitch: onSwitch
        )
        // A nil catalog is "not enumerated yet", NOT "no modes" — the same
        // distinction the hub draws. It renders as nothing rather than as an
        // empty state that would flash on every push.
        if let catalog {
          listControls(catalog)
          modeList(catalog)
        }
      }
      .formStyle(.grouped)
      // Enumeration is several CoreGraphics round-trips, so it runs once per
      // display rather than per body evaluation — and it runs HERE as well as
      // on the hub because a push is exactly when the modes are worth
      // re-reading, and because the debug screenshot hook can open this page
      // with the hub's own `.task` never having appeared.
      .task(id: state.id) { coordinator.refreshCatalog(for: state.id) }
      .onAppear { scrollToCurrent(proxy) }
      // Switching to All lands on 332 rows, and the row worth landing on is the
      // one the display is running. Focus stays on the segmented control (Ana
      // #5) — scrolling does not move it, and the announcement is what tells a
      // VoiceOver user the list underneath changed size.
      .onChange(of: listMode) { _, _ in
        scrollToCurrent(proxy)
        announceListMode()
      }
      // A filter naming a rate the display no longer offers would render an
      // empty list under a pop-up showing a blank value. Re-enumeration is the
      // one thing that can take a rate away.
      .onChange(of: rateChoices) { _, choices in
        if let rate = rateFilter, !choices.contains(rate) { rateFilter = nil }
      }
      .onMoveCommand { move($0) }
      .accessibilityRotor("Resolutions") {
        ForEach(rotorEntries) { entry in
          AccessibilityRotorEntry(entry.label, id: entry.id)
        }
      }
    }
  }

  // MARK: - Controls

  @ViewBuilder private func listControls(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    Section {
      Picker("Show", selection: $listMode) {
        ForEach(ListMode.allCases, id: \.self) { mode in
          Text(verbatim: mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      // Only the full list is long enough to want filtering, and a filter with
      // one rate in it is a control that cannot do anything.
      if listMode == .all, rateChoices.count > 1 {
        Picker("Refresh rate", selection: $rateFilter) {
          Text("Any").tag(Double?.none)
          ForEach(rateChoices, id: \.self) { hz in
            Text(verbatim: DisplayModeCopy.refresh(hz)).tag(Double?.some(hz))
          }
        }
      }
    }
  }

  private var rateChoices: [Double] {
    catalog.map { DisplayModeCatalog.distinctRates($0.all) } ?? []
  }

  // MARK: - List

  /// One `Section` per logical size in `All`, one flat section in
  /// `Recommended`. The sections sit directly in the `Form`'s builder — a
  /// grouped `Form` only reliably handles structure declared there (measured;
  /// see `DisplayHubView.body`).
  @ViewBuilder private func modeList(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    let lowResolution = DisplayModeCatalog.lowResolutionDuplicates(catalog.all)
    // A11y 6 asks for the rows to read as one radio group. `.contain` names the
    // group without collapsing its children, which is the whole point — it must
    // never become `.combine`, or 332 rows would announce as one element.
    Group {
      switch listMode {
      case .recommended:
        Section {
          ForEach(catalog.rows) { row in
            recommendedRow(row, in: catalog, lowResolution: lowResolution)
          }
        } header: {
          Text("Recommended Sizes").settingsHeading()
        }
      case .all:
        // The size headers feed the heading rotor, which is the only way to
        // cross 300 rows without arrowing through every one of them.
        ForEach(filteredGroups(catalog), id: \.header) { group in
          Section {
            ForEach(group.modes) { mode in
              fullRow(mode, in: catalog, lowResolution: lowResolution)
            }
          } header: {
            Text(verbatim: group.header).settingsHeading()
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sizes")
  }

  /// SO18: the row states what pressing it DOES, not what its catalog entry
  /// says. A curated row applies its size at the rate the display is already
  /// running when that size offers it, so a row that cannot hold the current
  /// rate says so instead of naming its representative's rate.
  ///
  /// `currentHz` is `outcome`'s contract, not a hint — and with no current mode
  /// the caps warning is suppressed entirely rather than judged against a
  /// placeholder.
  private func recommendedRow(
    _ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog,
    lowResolution: Set<Int32>
  ) -> some View {
    let outcome = DisplayModeCatalog.outcome(
      selectingWidth: row.mode.logicalWidth,
      selectingHeight: row.mode.logicalHeight,
      currentHz: catalog.current?.refreshHz ?? row.mode.refreshHz,
      in: catalog.all
    )
    let caps = catalog.current != nil && outcome?.lowersCurrentRate == true
    let hz = outcome?.appliedHz ?? DisplayMode.quantizedRefresh(row.mode.refreshHz)
    let tags = catalog.fullListTags(
      for: row.mode, isLowResolutionDuplicate: lowResolution.contains(row.id)
    )
    let rate = caps ? "caps at \(DisplayModeCopy.refresh(hz))" : DisplayModeCopy.refresh(hz)
    let spokenRate = caps
      ? "caps at \(ModeSpeech.spokenRate(hz))"
      : ModeSpeech.spokenRate(hz)

    return modeRow(
      id: row.id,
      title: DisplayModeCopy.size(row.mode),
      detail: ([rate] + tags).joined(separator: " · "),
      spoken: ([
        ModeSpeech.spoken(
          logicalWidth: row.mode.logicalWidth, logicalHeight: row.mode.logicalHeight,
          refreshHz: nil
        ),
        spokenRate,
      ] + tags).joined(separator: ", "),
      // By SIZE, like the hub's pop-up: a curated row's representative mode is
      // its size's fastest, so an ID comparison would drop the checkmark
      // whenever the user is at that size's slower rate.
      isCurrent: catalog.isCurrentSize(row.mode)
    ) {
      apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
    }
  }

  private func fullRow(
    _ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog,
    lowResolution: Set<Int32>
  ) -> some View {
    let tags = catalog.fullListTags(
      for: mode, isLowResolutionDuplicate: lowResolution.contains(mode.ioModeID)
    )
    let hz = DisplayMode.quantizedRefresh(mode.refreshHz)

    return modeRow(
      id: mode.ioModeID,
      title: DisplayModeCopy.size(mode),
      detail: ([DisplayModeCopy.refresh(hz)] + tags).joined(separator: " · "),
      spoken: ([
        ModeSpeech.spoken(
          logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight, refreshHz: hz
        ),
      ] + tags).joined(separator: ", "),
      // Exact here, unlike the curated rows: this list holds every rate of
      // every size, so the row the display is running is one specific mode.
      isCurrent: mode.ioModeID == catalog.current?.ioModeID
    ) {
      apply(mode, in: catalog)
    }
  }

  private func modeRow(
    id: Int32, title: String, detail: String, spoken: String, isCurrent: Bool,
    action: @escaping () -> Void
  ) -> some View {
    ModeChoice(
      title: title, detail: detail, spoken: spoken, isCurrent: isCurrent, action: action
    )
    .id(id)
    .focused($focusedRow, equals: id)
  }

  /// The full list, grouped, with the rate filter applied. Groups that the
  /// filter empties are dropped rather than left as bare headers.
  private func filteredGroups(
    _ catalog: DisplayModeCoordinator.Catalog
  ) -> [DisplayModeCatalog.SizeGroup] {
    let groups = DisplayModeCatalog.groupedBySize(catalog.all)
    guard let rateFilter else { return groups }
    return groups.compactMap { group in
      let modes = group.modes.filter { DisplayMode.quantizedRefresh($0.refreshHz) == rateFilter }
      guard !modes.isEmpty else { return nil }
      return DisplayModeCatalog.SizeGroup(
        logicalWidth: group.logicalWidth, logicalHeight: group.logicalHeight, modes: modes
      )
    }
  }

  // MARK: - Selection

  private func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // THE apply path, shared with the hub's Size pop-up — including the
    // already-on-screen guard, which lives on the coordinator so the two
    // surfaces cannot drift. `.settings` still routes a failed `begin()` to the
    // hub's start-failure banner.
    coordinator.selectFromList(
      mode, on: displayID, from: .settings, currentModeID: catalog.current?.ioModeID
    )
  }

  // MARK: - Focus, scrolling and announcements

  /// Leo #10: the page opens on the mode the display is running, not at the top
  /// of a list that can be 332 rows long.
  ///
  /// **Only when that row would be off screen.** Scrolling is not free — it
  /// takes the page's own title and its list controls out of view, and a push
  /// that lands on a clipped control row reads as a rendering fault.
  ///
  /// The threshold is a measurement, not a guess: at the window's default
  /// 900×568 the header and controls cost ~100 pt and a row is ~43 pt, so the
  /// first EIGHT rows are on screen from the top (counted in a capture, with
  /// the ninth clipped). It is still a heuristic — the window resizes and this
  /// number does not — but its two failure modes are a scroll that centres a
  /// row already visible and a row left one line below the fold, neither of
  /// which loses anything.
  ///
  /// One main-actor hop, deliberately: a grouped `Form`'s rows are not laid out
  /// when the page's `onAppear` fires, and scrolling in the same turn lands on
  /// nothing at all.
  private func scrollToCurrent(_ proxy: ScrollViewProxy) {
    guard let id = currentRowID,
          let index = visibleRowIDs.firstIndex(of: id),
          index >= Self.rowsVisibleFromTheTop
    else { return }
    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
  }

  private static let rowsVisibleFromTheTop = 8

  /// The row the checkmark is on, which differs by list mode: `All` holds the
  /// exact current mode, while `Recommended` holds one row for its SIZE.
  private var currentRowID: Int32? {
    guard let catalog else { return nil }
    switch listMode {
    case .recommended: return catalog.rows.first { catalog.isCurrentSize($0.mode) }?.id
    case .all: return catalog.current?.ioModeID
    }
  }

  private var nativeRowID: Int32? {
    guard let catalog else { return nil }
    switch listMode {
    case .recommended: return catalog.rows.first { $0.mode.isNative }?.id
    case .all: return catalog.all.first { $0.isNative }?.ioModeID
    }
  }

  /// A11y 6's rotor: the two rows anyone actually navigates to directly. Both
  /// are omitted when absent — a display can report no native flag, and the
  /// current mode can be filtered out of the list by the rate pop-up.
  private var rotorEntries: [RotorEntry] {
    let visible = Set(visibleRowIDs)
    var entries: [RotorEntry] = []
    if let id = currentRowID, visible.contains(id) {
      entries.append(RotorEntry(id: id, label: "Current resolution"))
    }
    if let id = nativeRowID, visible.contains(id), id != currentRowID {
      entries.append(RotorEntry(id: id, label: "Native resolution"))
    }
    return entries
  }

  private struct RotorEntry: Identifiable {
    let id: Int32
    let label: String
  }

  /// Every row on screen, in render order. The arrow keys walk this, and the
  /// rotor checks membership against it.
  private var visibleRowIDs: [Int32] {
    guard let catalog else { return [] }
    switch listMode {
    case .recommended: return catalog.rows.map(\.id)
    case .all: return filteredGroups(catalog).flatMap { $0.modes.map(\.ioModeID) }
    }
  }

  /// A11y 6: arrows move within the list, so Tab does not have to walk 332
  /// rows to leave it. Whether the enclosing `List` swallows the arrow keys
  /// before this sees them is UNVERIFIED — synthetic keystrokes cannot be
  /// delivered to an `LSUIElement` app from the shell, so this is a hardware
  /// checklist item, not a measured behaviour.
  private func move(_ direction: MoveCommandDirection) {
    let ids = visibleRowIDs
    guard !ids.isEmpty else { return }
    guard let focusedRow, let index = ids.firstIndex(of: focusedRow) else {
      self.focusedRow = ids.first
      return
    }
    switch direction {
    case .up: self.focusedRow = ids[max(index - 1, 0)]
    case .down: self.focusedRow = ids[min(index + 1, ids.count - 1)]
    default: break
    }
  }

  private func announceListMode() {
    let count = visibleRowIDs.count
    let message = switch listMode {
    case .all: "Showing all \(count) modes"
    case .recommended: "Showing \(count) recommended sizes"
    }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }
}

private extension DisplayModeCatalog.SizeGroup {
  /// Title Case is not a question for a pair of numbers, but `ForEach` needs an
  /// identity for the section and the size is it — two groups cannot share one.
  var header: String { "\(logicalWidth) × \(logicalHeight)" }
}

/// One selectable mode. A row-shaped button: the whole row is the hit region (a
/// bare `.plain` button is only as clickable as its text is wide), and it
/// carries hover and pressed states, without which it reads as static text.
///
/// Moved here from the resolution section it used to serve, which is gone —
/// this page is now the only surface in the settings window that lists modes
/// one per row.
private struct ModeChoice: View {
  let title: String
  let detail: String
  /// The spoken form (`2,560 by 1,440 at 60 hertz`), which is not the visible
  /// one: "×" is read inconsistently at most verbosities and digit groups are
  /// read digit by digit without it.
  let spoken: String
  let isCurrent: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .foregroundStyle(.tint)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(true)
        Text(verbatim: title)
        Text(verbatim: detail)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(ModeChoiceButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    .accessibilityLabel(Text(verbatim: spoken))
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// Hover and — required for any custom button (`buttons.md`) — a pressed state.
/// Without one the row feels unresponsive and people wonder whether the click
/// registered, which on a control that reconfigures the screen invites a second
/// click.
private struct ModeChoiceButtonStyle: ButtonStyle {
  let isHovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(fill(pressed: configuration.isPressed))
      )
      .opacity(configuration.isPressed ? 0.85 : 1)
  }

  private func fill(pressed: Bool) -> AnyShapeStyle {
    if pressed { return AnyShapeStyle(.quaternary) }
    return isHovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)
  }
}
