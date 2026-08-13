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

  /// nil until `seedListMode` decides, once, which list this display should
  /// open on; the user's own choice overwrites it and is never re-decided.
  ///
  /// The default cannot be a stored initial value, because it depends on a
  /// catalog that does not exist when this state is created: a display whose
  /// every size is under the usability floor has an EMPTY curated list and a
  /// full one with hundreds of entries, and it is exactly the display the hub
  /// sends here ("All Sizes & Refresh Rates lists them anyway"). `.recommended`
  /// would open this page blank on the one display it exists for.
  ///
  /// It cannot be recomputed per body either. **Measured 2026-08-06:** with 22
  /// curated rows present, repeated launches of the same build opened
  /// alternately on Recommended and All — a body-time read of
  /// `catalog.rows.isEmpty` samples a catalog that is not yet settled at first
  /// layout, and the segmented picker can write whatever it sampled back.
  /// Seeding once, from the catalog this page's own `.task` has just
  /// enumerated, is what makes the answer the same every time.
  @State private var chosenListMode: ListMode?
  /// nil is "Any". Quantized rates only — `distinctRates` is the source, never
  /// `refreshRates(in:)`, which dedupes raw doubles and would offer 60 twice
  /// the day float noise reached it.
  @State private var rateFilter: Double?
  /// Which sizes are open, by `SizeGroup.header`. Seeded once with the current
  /// mode's size (`seedListMode`) and owned by the user after that. Keyed by
  /// the size and not by `ioModeID`, so an expansion survives the
  /// re-enumeration that reassigns mode ids.
  @State private var expandedSizes: Set<String> = []
  /// Arrow-key movement within the list (accessibility contract 6), and
  /// `scrollTo`'s target. One id space for both kinds of row — a size row and a
  /// mode row can share a display, so `ioModeID` alone could not name them
  /// both.
  @FocusState private var focusedRow: String?

  @Environment(AppModel.self) private var model
  /// SO6's "key settings window" test, read at the click that starts a
  /// preview: `.key` exactly when this view's window is the key window.
  @Environment(\.controlActiveState) private var controlActiveState

  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }

  /// What the list is showing. `.recommended` only stands in for the moment
  /// before the seed lands, during which the page has no catalog and renders no
  /// list at all.
  private var listMode: ListMode { chosenListMode ?? .recommended }

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
      .task(id: state.id) {
        coordinator.refreshCatalog(for: state.id)
        seedListMode()
      }
      .onAppear { scrollToCurrent(proxy) }
      // Switching to All lands on 332 rows, and the row worth landing on is the
      // one the display is running. Focus stays on the segmented control (Ana
      // #5) — scrolling does not move it. Keyed on the RESOLVED mode, so the
      // catalog arriving and flipping the default scrolls too.
      .onChange(of: listMode) { _, _ in scrollToCurrent(proxy) }
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
      // The announcement rides on the SETTER, not on a change of `listMode`:
      // the resolved value can also change when the catalog arrives, and a page
      // that announced its own opening default would talk over the title
      // `SubPageHeader` just took the cursor to (a11y contract 1).
      Picker("Show", selection: Binding(
        get: { listMode },
        set: { mode in
          // A write-back equal to what `get` just returned is not a choice, and
          // a segmented control cannot send one from a real click. Ignoring it
          // keeps a picker's own initial-selection write from being recorded as
          // the user having answered.
          guard mode != listMode else { return }
          chosenListMode = mode
          announce(mode, in: catalog)
        }
      )) {
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

  /// Decides the opening list once, from the catalog `refreshCatalog` has just
  /// written — never from a body-time read (see `chosenListMode`).
  ///
  /// Silent when the catalog is missing or holds no modes at all: that is a
  /// display mid-reconfiguration, and a default taken from it would be a guess
  /// this page then has to live with. `.task(id:)` runs again on the next
  /// identity, and the seed is still unmade.
  private func seedListMode() {
    guard chosenListMode == nil,
          let catalog = coordinator.catalogs[displayID],
          !catalog.all.isEmpty
    else { return }
    chosenListMode = catalog.rows.isEmpty ? .all : .recommended
    // The size in use opens with the page — it is the one group somebody
    // arriving here is looking for, and leaving it shut would put the
    // checkmark's own row behind a click.
    if let current = catalog.current {
      expandedSizes.insert(RowID.size(width: current.logicalWidth, height: current.logicalHeight))
    }
  }

  /// A size is open when the user opened it — or when the rate filter is on.
  ///
  /// **Filtered means expanded, and that is a choice.** A filter answers "which
  /// sizes give me 120 Hz", and leaving the matches shut answers it with thirty
  /// closed doors and a click each to confirm what the filter already
  /// established. Filtering also cuts most groups to one or two rows, so the
  /// expanded list stays about as long as the collapsed one.
  private func isExpanded(_ group: DisplayModeCatalog.SizeGroup) -> Bool {
    rateFilter != nil || expandedSizes.contains(group.header)
  }

  // MARK: - List

  /// One flat section in `Recommended`; in `All`, one row per SIZE that opens
  /// to its rates.
  ///
  /// **Sizes are collapsed by default (§5, amended 2026-08-06).** Grouping 332
  /// rows under headers still leaves 332 rows to scroll; a display offers about
  /// thirty sizes, and that is the list a person is actually reading. The rates
  /// are the second question, asked one size at a time.
  ///
  /// The size row is a BUTTON, not a `DisclosureGroup`: a disclosure toggles
  /// only from its chevron glyph and never from its label (measured on this
  /// window), and that trap is exactly what the old full-list disclosure died
  /// of. The chevron here is decoration on a row that is entirely hit-target.
  ///
  /// The sections sit directly in the `Form`'s builder — a grouped `Form` only
  /// reliably handles structure declared there (measured; see
  /// `DisplayHubView.body`).
  @ViewBuilder private func modeList(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    // A11y 6 asks for the rows to read as one radio group. `.contain` names the
    // group without collapsing its children, which is the whole point — it must
    // never become `.combine`, or 332 rows would announce as one element.
    Group {
      switch listMode {
      case .recommended:
        Section {
          ForEach(catalog.rows) { row in
            recommendedRow(row, in: catalog)
          }
        } header: {
          Text("Recommended Sizes").settingsHeading()
        }
      case .all:
        // Computed here, not per row: the answer depends on a mode's siblings
        // at the same logical size, and an expanded group renders every one.
        let lowResolution = DisplayModeCatalog.lowResolutionDuplicates(catalog.all)
        // ONE section, not one per size: the size rows are now content rather
        // than headers, and a header repeating the row directly under it is the
        // same words twice.
        Section {
          ForEach(filteredGroups(catalog), id: \.header) { group in
            sizeRow(group, in: catalog)
            if isExpanded(group) {
              ForEach(group.modes) { mode in
                fullRow(mode, in: catalog, lowResolution: lowResolution)
                  .padding(.leading, 18)
              }
            }
          }
        } header: {
          Text("Sizes").settingsHeading()
        }
      }
    }
    // `.focusSection()` belongs here on paper — it is the primitive for a11y
    // 6's "arrows within" — and it is deliberately ABSENT. Applied to this
    // Group inside the grouped `Form` it took the form styling with it
    // (measured 2026-08-06: the size header centred and the rows lost their
    // card and separators). A focus affordance that cannot be verified is not
    // worth a visibly broken list; see `move(_:)` for what is implemented.
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
  ///
  /// **No "low resolution" tag here, and that is not an oversight.** SO14
  /// scopes the tag to the full mode list, and the curated list is where it
  /// would lie: `representativeRanking` ranks native first, so on a panel that
  /// offers its native framebuffer at both 1x and 2x the representative for
  /// that size IS the 1x half — and its sharp twin has been deduplicated away.
  /// The row would then read "Native · low resolution" with no better option in
  /// sight, which is a complaint about a choice the user cannot act on from
  /// this list. In All, where the twin is one row away, the tag is a
  /// distinction; here it would only be an insult.
  private func recommendedRow(
    _ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    let outcome = DisplayModeCatalog.outcome(
      selectingWidth: row.mode.logicalWidth,
      selectingHeight: row.mode.logicalHeight,
      currentHz: catalog.current?.refreshHz ?? row.mode.refreshHz,
      in: catalog.all
    )
    let caps = catalog.current != nil && outcome?.lowersCurrentRate == true
    let hz = outcome?.appliedHz ?? DisplayMode.quantizedRefresh(row.mode.refreshHz)
    let tags = catalog.tags(for: row.mode, isLowResolutionDuplicate: false)
    // A mode with no rate has no rate: nil, never 0, because "at 0 hertz" is a
    // claim and "0 Hz" is a value nobody can act on. The row then names the
    // size alone, which is all it knows.
    let rate = hz > 0 ? (caps ? "caps at \(DisplayModeCopy.refresh(hz))" : DisplayModeCopy.refresh(hz)) : nil
    let spokenRate = hz > 0
      ? (caps ? "caps at \(ModeSpeech.spokenRate(hz))" : ModeSpeech.spokenRate(hz))
      : nil
    // The mode this row would APPLY, not its representative, for the same
    // reason the rate above is the applied one (SO18). The two carry different
    // provenance whenever a size holds both kinds: measured on the MAG after
    // 1920×804 was engaged, CoreGraphics began publishing that rate while the
    // other rates at the same framebuffer stayed ours, which is a published
    // representative in front of an applied mode we added.
    let badge = sourceBadge(catalog.modeKeepingCurrentRefreshRate(for: row).isRevealed)

    return modeRow(
      id: RowID.mode(row.id),
      title: DisplayModeCopy.size(row.mode),
      detail: ([rate].compactMap { $0 } + tags).joined(separator: " · "),
      badge: badge,
      spoken: ([
        ModeSpeech.spoken(
          logicalWidth: row.mode.logicalWidth, logicalHeight: row.mode.logicalHeight,
          refreshHz: nil
        ),
        spokenRate,
      ].compactMap { $0 } + tags + [badge].compactMap { $0 })
        .joined(separator: ", "),
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
    let tags = catalog.tags(
      for: mode, isLowResolutionDuplicate: lowResolution.contains(mode.ioModeID)
    )
    // nil, never 0 — see `recommendedRow`.
    let hz: Double? = DisplayMode.quantizedRefresh(mode.refreshHz) > 0
      ? DisplayMode.quantizedRefresh(mode.refreshHz)
      : nil

    return modeRow(
      id: RowID.mode(mode.ioModeID),
      title: DisplayModeCopy.size(mode),
      detail: ([hz.map(DisplayModeCopy.refresh)].compactMap { $0 } + tags)
        .joined(separator: " · "),
      badge: sourceBadge(mode.isRevealed),
      spoken: ([
        ModeSpeech.spoken(
          logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight, refreshHz: hz
        ),
      ] + tags + [sourceBadge(mode.isRevealed)].compactMap { $0 }).joined(separator: ", "),
      // Exact here, unlike the curated rows: this list holds every rate of
      // every size, so the row the display is running is one specific mode.
      isCurrent: mode.ioModeID == catalog.current?.ioModeID
    ) {
      apply(mode, in: catalog)
    }
  }

  /// One size, closed. Says how fast the size goes rather than how many entries
  /// it holds: the rate is what the next click is about, and a count of modes
  /// counts duplicates the platform publishes.
  private func sizeRow(
    _ group: DisplayModeCatalog.SizeGroup, in catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    let expanded = isExpanded(group)
    let holdsCurrent = catalog.current.map {
      $0.logicalWidth == group.logicalWidth && $0.logicalHeight == group.logicalHeight
    } ?? false
    let top = group.modes.map(\.refreshHz).max().map(DisplayMode.quantizedRefresh)
    let id = RowID.size(width: group.logicalWidth, height: group.logicalHeight)

    return ModeChoice(
      title: group.header,
      detail: top.map { $0 > 0 ? "up to \(DisplayModeCopy.refresh($0))" : "" } ?? "",
      // Size and state, both spoken: a closed row that does not say it is
      // closed is a row VoiceOver describes as a dead end.
      spoken: ModeSpeech.spoken(
        logicalWidth: group.logicalWidth, logicalHeight: group.logicalHeight, refreshHz: nil
      ),
      spokenValue: expanded ? "Expanded" : "Collapsed",
      isCurrent: holdsCurrent,
      chevron: expanded ? "chevron.up" : "chevron.down"
    ) {
      if expanded {
        expandedSizes.remove(group.header)
      } else {
        expandedSizes.insert(group.header)
      }
    }
    .id(id)
    .focused($focusedRow, equals: id)
  }

  private func modeRow(
    id: String, title: String, detail: String, badge: String? = nil, spoken: String,
    isCurrent: Bool, action: @escaping () -> Void
  ) -> some View {
    ModeChoice(
      title: title, detail: detail, badge: badge, spoken: spoken, isCurrent: isCurrent,
      action: action
    )
    .id(id)
    .focused($focusedRow, equals: id)
  }

  /// The mark on an option our own enumeration added, on both lists: the
  /// curated one, where it is why the row exists, and the full one, where it
  /// separates a mode we found from its published neighbour at the same size.
  ///
  /// Takes the answer rather than a mode, because the two lists ask about
  /// different modes: a full row IS one mode, and a curated row is a size whose
  /// applied mode depends on the rate the display is running.
  ///
  /// A size row never carries it. A size can hold published and added modes at
  /// once, so a mark on the closed row would be a claim about a set rather than
  /// about a mode; open the size and each row answers for itself.
  private func sourceBadge(_ isRevealed: Bool) -> String? {
    isRevealed ? DisplayModeCopy.addedByApp : nil
  }

  /// The one id space the list, its focus and `scrollTo` all speak.
  enum RowID {
    static func size(width: Int, height: Int) -> String { "\(width) × \(height)" }
    static func mode(_ id: Int32) -> String { "mode-\(id)" }
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
    // surfaces cannot drift. `.settings` routes a failed `begin()` to the
    // banner region; the SURFACE is the SO6 decision, sampled from this
    // window's key state synchronously at the click (see `DisplayHubView`).
    coordinator.selectFromList(
      mode, on: displayID, from: .settings,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel,
      currentModeID: catalog.current?.ioModeID
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

  /// The row the checkmark is on, which differs by list mode: `Recommended`
  /// holds one row per SIZE, and `All` holds the exact mode — behind a size row
  /// that may be shut, in which case the size row is the thing to land on.
  private var currentRowID: String? {
    guard let catalog, let current = catalog.current else { return nil }
    switch listMode {
    case .recommended:
      return catalog.rows.first { catalog.isCurrentSize($0.mode) }.map { RowID.mode($0.id) }
    case .all:
      return rowID(forModeAt: current, in: catalog)
    }
  }

  private var nativeRowID: String? {
    guard let catalog else { return nil }
    switch listMode {
    case .recommended:
      return catalog.rows.first { $0.mode.isNative }.map { RowID.mode($0.id) }
    case .all:
      return catalog.all.first { $0.isNative }.flatMap { rowID(forModeAt: $0, in: catalog) }
    }
  }

  /// A mode's row in the collapsible list — itself when its size is open, its
  /// size row when it is not. nil when the rate filter has removed it entirely.
  private func rowID(
    forModeAt mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog
  ) -> String? {
    let sizeID = RowID.size(width: mode.logicalWidth, height: mode.logicalHeight)
    guard let group = filteredGroups(catalog).first(where: { $0.header == sizeID })
    else { return nil }
    guard isExpanded(group), group.modes.contains(where: { $0.ioModeID == mode.ioModeID })
    else { return sizeID }
    return RowID.mode(mode.ioModeID)
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
    let id: String
    let label: String
  }

  /// Every row on screen, in render order — size rows included, and the modes
  /// of a shut size excluded. The arrow keys walk this, the rotor checks
  /// membership against it, and `scrollToCurrent` measures the fold against it,
  /// so all three follow the collapse for free.
  private var visibleRowIDs: [String] { rowIDs(for: listMode, in: catalog) }

  private func rowIDs(
    for mode: ListMode, in catalog: DisplayModeCoordinator.Catalog?
  ) -> [String] {
    guard let catalog else { return [] }
    switch mode {
    case .recommended:
      return catalog.rows.map { RowID.mode($0.id) }
    case .all:
      return filteredGroups(catalog).flatMap { group in
        [group.header] + (isExpanded(group) ? group.modes.map { RowID.mode($0.ioModeID) } : [])
      }
    }
  }

  /// Maps arrow keys onto row focus.
  ///
  /// **This is HALF of accessibility contract 6, and the comment says so
  /// because the code cannot.** The contract is "one Tab stop, arrows within".
  /// What is implemented is the arrows: every row is its own focusable button,
  /// so Tab still visits each one. SwiftUI offers no supported way to keep a
  /// control focusable while taking it out of the Tab loop, and the one
  /// primitive that would have helped with directional movement,
  /// `.focusSection()`, breaks the grouped form's styling here (see
  /// `modeList`).
  ///
  /// Neither half is verified either: synthetic keystrokes cannot be delivered
  /// to an `LSUIElement` app from the shell (they go to the terminal), so
  /// whether the enclosing `List` consumes the arrows before `onMoveCommand`
  /// sees them is unknown. Both are hardware-checklist items, filed with the
  /// task report — not measured behaviour.
  ///
  /// Collapsing the sizes is what makes the shortfall survivable rather than
  /// disqualifying: Tab now walks about thirty size rows instead of 332 mode
  /// rows, and only an opened size adds to that.
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

  /// Takes the mode it is announcing rather than reading `listMode` back: the
  /// caller is the picker's setter, and an announcement about "whatever the
  /// state says now" is exactly the kind of thing that ends up one toggle
  /// behind.
  private func announce(_ mode: ListMode, in catalog: DisplayModeCoordinator.Catalog?) {
    // Counted from the CONTENT, not from `rowIDs` — with sizes collapsed a row
    // count is neither the number of modes nor the number of sizes, and saying
    // "32 modes" about 32 shut size rows would be a plain lie.
    let groups = catalog.map { filteredGroups($0) } ?? []
    let message = switch mode {
    case .all:
      "Showing all \(groups.reduce(0) { $0 + $1.modes.count }) modes in \(groups.count) sizes"
    case .recommended:
      "Showing \(catalog?.rows.count ?? 0) recommended sizes"
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
  var header: String { AllModesPage.RowID.size(width: logicalWidth, height: logicalHeight) }
}

/// One row in either list — a selectable mode, or a size that opens to its
/// rates. A row-shaped button: the whole row is the hit region (a bare `.plain`
/// button is only as clickable as its text is wide), and it carries hover and
/// pressed states, without which it reads as static text.
///
/// The size rows use the SAME component deliberately. They are a
/// `DisclosureGroup`'s job on paper, and a disclosure toggles only from its
/// chevron glyph (measured on this window) — the trap the old full-list
/// disclosure died of. Here the chevron is drawn by a row that is entirely
/// clickable.
private struct ModeChoice: View {
  let title: String
  let detail: String
  /// A short mark at the trailing edge, or nothing. Drawn rather than folded
  /// into `detail` so it reads as a note about the row instead of as one more
  /// property of the mode, and so it lines up down the list: a run of marked
  /// rows is the shape of what the app adds to this display.
  ///
  /// Hidden from accessibility here; the callers put the same words into
  /// `spoken`, which is what VoiceOver reads.
  var badge: String?
  /// The spoken form (`2,560 by 1,440 at 60 hertz`), which is not the visible
  /// one: "×" is read inconsistently at most verbosities and digit groups are
  /// read digit by digit without it.
  let spoken: String
  /// Announced after the label — "Expanded" / "Collapsed" on a size row. A
  /// closed row that does not say it is closed is one VoiceOver describes as a
  /// dead end.
  var spokenValue: String?
  let isCurrent: Bool
  /// An SF Symbol drawn at the trailing edge, or nothing. Hidden from
  /// accessibility: `spokenValue` already says what it means, and a glyph name
  /// read aloud says nothing.
  var chevron: String?
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
        if let badge {
          // The app's own badge shape, to the point: same font, padding, radius
          // and fill as the menu bar's HDR marker (`PanelView`). Two badges
          // differing by a point of radius is how one shape becomes two. A tint
          // would compete with the checkmark, which is the only thing in this
          // list that says "you are here".
          Text(verbatim: badge)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.quaternary))
            .accessibilityHidden(true)
        }
        if let chevron {
          Image(systemName: chevron)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(ModeChoiceButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
    .accessibilityLabel(Text(verbatim: spoken))
    .accessibilityValue(Text(verbatim: spokenValue ?? ""))
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
