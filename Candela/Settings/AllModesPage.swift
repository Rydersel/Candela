import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI

/// Every mode one display reports (spec §5).
///
/// The page exists solely to enumerate: the hub's Size pop-up is the
/// curated answer and this is the escape hatch behind it, so nothing here is a
/// preference. Choosing a row goes through the hub's preview-with-countdown.
///
/// Not a `DisclosureGroup`: one toggles from its chevron glyph and never from
/// its label text (measured on this window), and its nested scroller meant
/// scrolling one view to get at another.
///
/// `@MainActor` for the reason every settings view records: a `View`'s
/// properties other than `body` are nonisolated under complete concurrency.
@MainActor
struct AllModesPage: View {
  let state: AppModel.DisplayState
  /// The header's display switcher. The root view owns switching: carry
  /// the path, move the sidebar selection.
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  /// `Recommended` is the list the hub's Size pop-up offers, so arriving here
  /// shows what the user just left. The control sits at the TOP (§5): an
  /// expansion control never sits below what it expands.
  enum ListMode: String, CaseIterable, Hashable {
    case recommended = "Recommended"
    case all = "All"
  }

  /// nil until `seedListMode` decides, once, which list this display opens on;
  /// the user's own choice overwrites it and it is never re-decided.
  ///
  /// Not a stored initial value: the answer needs a catalog that does not exist
  /// yet, and a display whose every size is under the usability floor has an
  /// EMPTY curated list, which is exactly the display the hub sends here.
  ///
  /// Not recomputed per body either. [MEASURED 2026-08-06] repeated launches of
  /// one build opened alternately on Recommended and All: a body-time read
  /// samples a catalog not yet settled at first layout, and the segmented picker
  /// writes back whatever it sampled.
  @State private var chosenListMode: ListMode?
  /// nil is "Any". Quantized rates only: `distinctRates`, never
  /// `refreshRates(in:)`, which dedupes raw doubles and would offer 60 twice
  /// the day float noise reached it.
  @State private var rateFilter: Double?
  /// Which sizes are open, by `SizeGroup.header`. Keyed by the size and not by
  /// `ioModeID`, so an expansion survives the re-enumeration that reassigns
  /// mode ids.
  @State private var expandedSizes: Set<String> = []
  /// Arrow-key movement within the list (accessibility contract 6), and
  /// `scrollTo`'s target. One id space for both kinds of row, because
  /// `ioModeID` alone cannot name a size row and a mode row apart.
  @FocusState private var focusedRow: String?

  @Environment(AppModel.self) private var model
  /// The "key settings window" test, read at the click that starts a
  /// preview: `.key` exactly when this view's window is the key window.
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }

  /// What the list is showing. `.recommended` only stands in for the moment
  /// before the seed lands, during which the page has no catalog and renders no
  /// list at all.
  private var listMode: ListMode { chosenListMode ?? .recommended }

  var body: some View {
    // The scaffold's reading variant: it owns the scroller, and the two hooks
    // that land the page on the mode in use need that scroller's proxy.
    SettingsPageScaffold(reading: { proxy in
      SubPageHeader(
        title: DisplaySubPage.allModes.title,
        currentKey: state.display.persistenceKey,
        displays: displays,
        onSwitch: onSwitch
      )
      // The scroll hooks hang on the header, the one view of this page that is
      // always present: on the list they would stop existing whenever the
      // catalog does.
      .onAppear { scrollToCurrent(proxy) }
      // The row worth landing on is the one the display is running. Focus stays
      // on the list-mode control; scrolling does not move it. Keyed on the
      // RESOLVED mode, so a catalog arriving and flipping the default scrolls.
      .onChange(of: listMode) { _, _ in scrollToCurrent(proxy) }

      // A nil catalog is "not enumerated yet", NOT "no modes". It renders as
      // nothing, so no empty state flashes on every push.
      if let catalog {
        if catalog.all.isEmpty {
          // An enumerated display with nothing in it. Without this the page
          // draws a Show control over a titled, empty card, which reads as a
          // list that failed to load.
          SettingsRowNote(verbatim: Self.noModesNote)
        } else {
          listControls(catalog)
          modeList(catalog)
        }
      }
    })
    // Enumeration is several CoreGraphics round-trips, so it runs once per
    // display, not per body evaluation. It runs here as well as on the hub
    // because the debug screenshot hook can open this page without the hub's
    // own `.task` ever appearing.
    .task(id: state.id) {
      coordinator.refreshCatalog(for: state.id)
      seedListMode()
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

  // MARK: - Controls

  /// Word for word what `DisplaySizeRows` says on the hub for the same display,
  /// so the two surfaces do not describe one silent panel two ways.
  static let noModesNote =
    "\(AppInfo.productName) found no resolutions it can switch between on this display."

  @ViewBuilder private func listControls(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    SettingsCardSection {
      SettingRow {
        HStack(spacing: 12) {
          // Hidden from VoiceOver, which reads it off the segments' own
          // container instead, so the group is named once.
          Text("Show").accessibilityHidden(true)
          Spacer(minLength: 16)
          ThemedSegments(options: Self.listModeNames, selection: listModeSelection(catalog))
            // A container element: the segments are the buttons, so this names
            // the group and each segment keeps its own name and selected trait.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Only the full list is long enough to want filtering, and a filter with
      // one rate in it is a control that cannot do anything.
      if listMode == .all, rateChoices.count > 1 {
        // A `Group`'s modifier reaches each child, so the divider and the row
        // arrive and leave together under the switch to All, as one movement.
        Group {
          SettingsCardDivider()
          SettingRow {
            ThemedChoiceRow(label: "Refresh rate", selection: Binding<Double?>(
              get: { rateFilter },
              set: { rate in
                // A rate bulk-expands every size that offers it (see
                // `isExpanded`), so this unfurls as one movement. Animating the
                // SETTER leaves the `onChange(of: rateChoices)` correction
                // instant, which nobody asked for.
                withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) { rateFilter = rate }
              }
            )) {
              Text("Any").tag(Double?.none)
              ForEach(rateChoices, id: \.self) { hz in
                Text(verbatim: DisplayModeCopy.refresh(hz)).tag(Double?.some(hz))
              }
            }
          }
        }
        .transition(.opacity)
      }
    }
  }

  /// The segment names in `ListMode`'s own order, so the control and the
  /// binding below cannot come to disagree about which one index 0 is.
  private static let listModeNames = ListMode.allCases.map(\.rawValue)

  /// `ThemedSegments` chooses by index; this page reasons in list modes. An
  /// out-of-range write lands on the curated list rather than on nothing.
  ///
  /// The announcement rides on the SETTER, not on a change of `listMode`: the
  /// resolved value also changes when the catalog arrives, and announcing the
  /// opening default would talk over the title `SubPageHeader` just took the
  /// cursor to (a11y contract 1).
  private func listModeSelection(_ catalog: DisplayModeCoordinator.Catalog) -> Binding<Int> {
    Binding(
      get: { Self.listModeNames.firstIndex(of: listMode.rawValue) ?? 0 },
      set: { index in
        let mode = ListMode.allCases.indices.contains(index)
          ? ListMode.allCases[index] : .recommended
        // A write-back equal to what `get` returned is not a choice, and a real
        // click cannot send one. Ignoring it keeps an initial-selection write
        // from counting as the user having answered.
        guard mode != listMode else { return }
        // Animated at the SETTER, not by an `.animation` on the list: only a
        // real choice should move. The seed and a catalog arriving mid-page both
        // land instantly.
        withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
          chosenListMode = mode
        }
        announce(mode, in: catalog)
      }
    )
  }

  private var rateChoices: [Double] {
    catalog.map { DisplayModeCatalog.distinctRates($0.all) } ?? []
  }

  /// Decides the opening list once, from the catalog `refreshCatalog` just
  /// wrote, never from a body-time read (see `chosenListMode`).
  ///
  /// Silent on a missing or empty catalog: that is a display mid-reconfiguration
  /// and a default taken from it is a guess. `.task(id:)` runs again on the next
  /// identity with the seed still unmade.
  private func seedListMode() {
    guard chosenListMode == nil,
          let catalog = coordinator.catalogs[displayID],
          !catalog.all.isEmpty
    else { return }
    chosenListMode = catalog.rows.isEmpty ? .all : .recommended
    // The size in use opens with the page, or the checkmark's own row sits
    // behind a click. `onScreen`, so while a size this app renders is engaged
    // this opens nothing rather than the native group.
    if let onScreen = catalog.onScreen {
      expandedSizes.insert(
        RowID.size(width: onScreen.logicalWidth, height: onScreen.logicalHeight))
    }
  }

  /// A size is open when the user opened it, or when the rate filter is on.
  ///
  /// Filtered means expanded: a filter answers "which sizes give me 120 Hz", and
  /// leaving the matches shut answers it with closed doors and a click each.
  private func isExpanded(_ group: DisplayModeCatalog.SizeGroup) -> Bool {
    Self.isExpanded(group, rateFilter: rateFilter, expandedSizes: expandedSizes)
  }

  /// The same rule over plain values, so the row derivation below can answer it
  /// without a live view's state.
  static func isExpanded(
    _ group: DisplayModeCatalog.SizeGroup, rateFilter: Double?, expandedSizes: Set<String>
  ) -> Bool {
    rateFilter != nil || expandedSizes.contains(group.header)
  }

  // MARK: - List

  /// One flat section in `Recommended`; in `All`, one row per SIZE that opens
  /// to its rates. Sizes are collapsed by default (§5): grouping hundreds of
  /// rows under headers still leaves hundreds to scroll, and the rates are the
  /// second question, asked one size at a time.
  ///
  /// The size row is a BUTTON, not a `DisclosureGroup`: a disclosure toggles
  /// only from its chevron glyph, never from its label (measured on this
  /// window). Here the chevron is decoration on a fully clickable row.
  ///
  /// No hairline between mode rows, unlike every other card in this window: a
  /// divider separates unrelated settings, and a rule between every pair of one
  /// long list is a grid. Hover and the accent ring tell the rows apart.
  @ViewBuilder private func modeList(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    // A11y 6 asks for the rows to read as one radio group. `.contain` names it
    // without collapsing its children; never `.combine`, which would announce
    // the whole list as one element.
    Group {
      switch listMode {
      case .recommended:
        SettingsCardSection(title: "Recommended Sizes") {
          ForEach(catalog.rows) { row in
            choice(Self.recommendedRowModel(row, in: catalog), in: catalog)
          }
        }
      case .all:
        // Computed here, not per row: the answer depends on a mode's siblings
        // at the same logical size, and an expanded group renders every one.
        let lowResolution = DisplayModeCatalog.lowResolutionDuplicates(catalog.all)
        // ONE card, not one per size: the size rows are content, not headers,
        // and a header repeating the row under it says the same words twice.
        SettingsCardSection(title: "Sizes") {
          // The All clause. This list enumerates what the DISPLAY reports, so
          // an engaged synthesized stop has no row and the checkmark is on
          // nothing. Saying so beats looking like the list lost track.
          //
          // The raw readback cannot stand in: the engage tail re-times the slave
          // onto its own mode, so the readback names the display's NATIVE
          // geometry [MEASURED 2026-08-18], a real row in this list and not what
          // is on the glass. Readers go through `Catalog.onScreen` instead.
          if Self.showsEngagedSizeNotice(in: catalog) {
            SettingsCaption(verbatim: SynthesisCopy.engagedSizeNotListed)
              .padding(.bottom, 6)
            // The one hairline on this card: it separates a sentence about the
            // list from the list, which is the divider's ordinary job.
            SettingsCardDivider()
              .padding(.bottom, 6)
          }
          ForEach(filteredGroups(catalog), id: \.header) { group in
            choice(
              Self.sizeRowModel(group, in: catalog, expanded: isExpanded(group)), in: catalog
            )
            if isExpanded(group) {
              // A `Group`, not a real container: its modifier reaches each
              // child, so every rate stays its OWN row. A `VStack` would fade as
              // one block and collapse the size into a single row, insets and
              // all.
              Group {
                ForEach(group.modes) { mode in
                  choice(
                    Self.fullRowModel(mode, in: catalog, lowResolution: lowResolution),
                    in: catalog
                  )
                  .padding(.leading, 18)
                }
              }
              .transition(.opacity)
            }
          }
        }
      }
    }
    // `.focusSection()` is a11y 6's "arrows within" primitive and is still
    // ABSENT: nothing here can verify the affordance. See `move(_:)` for what is
    // implemented and why synthetic keystrokes cannot reach this app.
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sizes")
  }

  /// The row states what pressing it DOES, not what its catalog entry
  /// says. A curated row applies its size at the rate the display is already
  /// running when that size offers it, so a row that cannot hold the current
  /// rate says so instead of naming its representative's rate.
  ///
  /// `currentHz` is `outcome`'s contract, not a hint: with no current mode the
  /// caps warning is suppressed rather than judged against a placeholder.
  ///
  /// No "low resolution" tag here (that tag applies only to the full list). The
  /// representative for a size can be its 1x half with the sharp twin
  /// deduplicated away, so the tag would name a choice this list cannot offer.
  static func recommendedRowModel(
    _ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog
  ) -> AllModesRow {
    // A synthesized stop is not in `catalog.all` and has no rate of its own:
    // what scans out is the display's own timing, which the engage tail re-times
    // it back onto [MEASURED 2026-08-18]. Asking anyway answers nil for every
    // field.
    let synthesized = row.mode.isSynthesized
    let outcome = synthesized ? nil : DisplayModeCatalog.outcome(
      selectingWidth: row.mode.logicalWidth,
      selectingHeight: row.mode.logicalHeight,
      currentHz: catalog.current?.refreshHz ?? row.mode.refreshHz,
      in: catalog.all
    )
    let caps = catalog.current != nil && outcome?.lowersCurrentRate == true
    let hz = outcome?.appliedHz ?? DisplayMode.quantizedRefresh(row.mode.refreshHz)
    let tags = catalog.tags(for: row.mode, isLowResolutionDuplicate: false)
    // A mode with no rate reports nil, never 0: "at 0 hertz" is a claim nobody
    // can act on, so the row names the size alone.
    //
    // A synthesized row's `refreshHz` is the 0 sentinel, so the branch above
    // would blank the column on the rows most in need of explaining. It names
    // the rule instead of a figure, since the rule holds for every panel.
    let rate = synthesized
      ? SynthesisCopy.keepsPanelRefresh
      : (hz > 0
        ? (caps ? "caps at \(DisplayModeCopy.refresh(hz))" : DisplayModeCopy.refresh(hz))
        : nil)
    let spokenRate = synthesized
      ? SynthesisCopy.keepsPanelRefresh
      : (hz > 0
        ? (caps ? "caps at \(ModeSpeech.spokenRate(hz))" : ModeSpeech.spokenRate(hz))
        : nil)
    // The mode this row would APPLY, not its representative. The two
    // carry different provenance when a size holds both kinds: measured on the
    // MAG, CoreGraphics began publishing one engaged rate while the other rates
    // at that framebuffer stayed ours.
    let applied = catalog.modeKeepingCurrentRefreshRate(for: row)
    let badge = rowBadge(
      // By SIZE, like the checkmark below and like the hub's pop-up.
      isRecommendedSize: catalog.isRecommendedSize(row.mode),
      isDefaultSize: catalog.isDefaultSize(row.mode),
      isRevealed: applied.isRevealed,
      isSynthesized: applied.isSynthesized
    )

    return AllModesRow(
      id: RowID.mode(row.id),
      // The mode a press APPLIES, the same answer the source mark above is
      // taken from, so a row cannot wear one mode's mark and apply another's.
      kind: .mode(applied),
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
    )
  }

  static func fullRowModel(
    _ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog,
    lowResolution: Set<Int32>
  ) -> AllModesRow {
    let tags = catalog.tags(
      for: mode, isLowResolutionDuplicate: lowResolution.contains(mode.ioModeID)
    )
    // nil, never 0; see `recommendedRow`.
    let hz: Double? = DisplayMode.quantizedRefresh(mode.refreshHz) > 0
      ? DisplayMode.quantizedRefresh(mode.refreshHz)
      : nil
    // Every rate of the recommended size wears the mark: the suggestion is a
    // size, so marking one rate would invent a recommendation the model never
    // made.
    //
    // The low-resolution twins are the exception. The model ranked the sharp
    // mode at that size, so a row reading "low resolution" while wearing
    // "Recommended" is a quality claim that is forbidden here. Measured on the Dell, one
    // logical size held one HiDPI rung and ten 1x modes, so this is ten wrong
    // marks rather than an edge case.
    let badge = rowBadge(
      isRecommendedSize: catalog.isRecommendedSize(mode)
        && !lowResolution.contains(mode.ioModeID),
      // The twin exclusion applies to Default for Recommended's reason: "low
      // resolution" beside the size macOS calls Default is the same forbidden
      // quality claim.
      isDefaultSize: catalog.isDefaultSize(mode)
        && !lowResolution.contains(mode.ioModeID),
      isRevealed: mode.isRevealed,
      // `catalog.all` is the display's own enumeration and holds no synthesized
      // stop, so this arm is false by construction rather than by policy.
      isSynthesized: mode.isSynthesized
    )

    return AllModesRow(
      id: RowID.mode(mode.ioModeID),
      kind: .mode(mode),
      title: DisplayModeCopy.size(mode),
      detail: ([hz.map(DisplayModeCopy.refresh)].compactMap { $0 } + tags)
        .joined(separator: " · "),
      badge: badge,
      spoken: ([
        ModeSpeech.spoken(
          logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight, refreshHz: hz
        ),
      ] + tags + [badge].compactMap { $0 }).joined(separator: ", "),
      // Exact here, unlike the curated rows: this list holds every rate of
      // every size, so the row in use is one specific mode. Against `onScreen`,
      // whose sentinel mode id for an engaged stop belongs to no published row,
      // so nothing is ticked, which the caption above the list already says.
      isCurrent: mode.ioModeID == catalog.onScreen?.ioModeID
    )
  }

  /// One size, closed. Says how fast the size goes rather than how many entries
  /// it holds: the rate is what the next click is about, and a mode count counts
  /// duplicates the platform publishes.
  static func sizeRowModel(
    _ group: DisplayModeCatalog.SizeGroup, in catalog: DisplayModeCoordinator.Catalog,
    expanded: Bool
  ) -> AllModesRow {
    let holdsCurrent = catalog.onScreen.map {
      $0.logicalWidth == group.logicalWidth && $0.logicalHeight == group.logicalHeight
    } ?? false
    let top = group.modes.map(\.refreshHz).max().map(DisplayMode.quantizedRefresh)

    return AllModesRow(
      id: RowID.size(width: group.logicalWidth, height: group.logicalHeight),
      kind: .size(header: group.header),
      title: group.header,
      detail: top.map { $0 > 0 ? "up to \(DisplayModeCopy.refresh($0))" : "" } ?? "",
      // Size and state, both spoken: a closed row that does not say it is
      // closed is a row VoiceOver describes as a dead end.
      spoken: ModeSpeech.spoken(
        logicalWidth: group.logicalWidth, logicalHeight: group.logicalHeight, refreshHz: nil
      ),
      spokenValue: expanded ? "Expanded" : "Collapsed",
      isCurrent: holdsCurrent,
      chevronExpanded: expanded
    )
  }

  /// Draws one derived row. The two lists differ in what they derive, never in
  /// how a row is drawn, so a row model is all this needs.
  private func choice(_ row: AllModesRow, in catalog: DisplayModeCoordinator.Catalog) -> some View {
    ModeChoice(
      title: row.title, detail: row.detail, badge: row.badge, spoken: row.spoken,
      spokenValue: row.spokenValue, isCurrent: row.isCurrent,
      chevronExpanded: row.chevronExpanded
    ) {
      switch row.kind {
      case let .mode(mode):
        apply(mode, in: catalog)
      case let .size(header):
        // Animated HERE, not by an `.animation` on the list: only the click
        // should move, and a re-enumeration must not replay the seed.
        //
        // Keyed on the row's own chevron, not on set membership: a rate filter
        // shows matching sizes open while their headers are absent from the set,
        // and pressing there stays a no-op.
        withAnimation(Motion.disclosure(reduceMotion: reduceMotion)) {
          if row.chevronExpanded == true {
            expandedSizes.remove(header)
          } else {
            expandedSizes.insert(header)
          }
        }
      }
    }
    .id(row.id)
    .focused($focusedRow, equals: row.id)
  }

  /// A row's marks as the ONE string `ModeChoice` draws. Joined rather than
  /// given a pill each: a second pill on a row that already carries a size, a
  /// rate and its tags reads as a table. Recommended leads, because a note about
  /// the DISPLAY outranks a note about the list.
  ///
  /// A low-resolution twin never counts as recommended, which is why the caller
  /// decides rather than passing a bare size match: the model ranked the sharp
  /// mode at that logical size, not its blurry twin.
  ///
  /// A size row carries neither mark. A size can hold published and added modes
  /// at once, so a source mark there would claim something about a set rather
  /// than about a mode.
  ///
  /// TWO source marks, saying different things: "Added by Candela" is a
  /// mode our enumeration found on the display, "Rendered by Candela" is a size
  /// the display does not have, which this app mirrors onto a virtual display.
  /// Mutually exclusive by construction, kept as separate parameters so a row
  /// claiming both renders both instead of silently choosing one.
  static func rowBadge(
    isRecommendedSize: Bool, isDefaultSize: Bool, isRevealed: Bool, isSynthesized: Bool
  ) -> String? {
    let marks = [
      isRecommendedSize ? DisplayModeCopy.recommended : nil,
      isDefaultSize ? DisplayModeCopy.defaultSize : nil,
      isRevealed ? DisplayModeCopy.addedByApp : nil,
      isSynthesized ? SynthesisCopy.badge : nil,
    ].compactMap { $0 }
    return marks.isEmpty ? nil : marks.joined(separator: ", ")
  }

  /// Everything either list puts on screen, in render order, from the catalog
  /// and the list state alone. `modeList` walks the same groups and hands each
  /// one straight to `choice`, so a row missing here is a row nobody can see,
  /// and a test can check that without a window.
  static func rows(
    in catalog: DisplayModeCoordinator.Catalog, listMode: ListMode,
    rateFilter: Double?, expandedSizes: Set<String>
  ) -> [AllModesRow] {
    switch listMode {
    case .recommended:
      return catalog.rows.map { recommendedRowModel($0, in: catalog) }
    case .all:
      // Computed once per list, not per row: the answer depends on a mode's
      // siblings at the same logical size.
      let lowResolution = DisplayModeCatalog.lowResolutionDuplicates(catalog.all)
      return filteredGroups(catalog.all, rateFilter: rateFilter).flatMap { group in
        let expanded = isExpanded(group, rateFilter: rateFilter, expandedSizes: expandedSizes)
        let size = sizeRowModel(group, in: catalog, expanded: expanded)
        guard expanded else { return [size] }
        return [size] + group.modes.map {
          fullRowModel($0, in: catalog, lowResolution: lowResolution)
        }
      }
    }
  }

  /// Whether the All list says the size in use is one this app renders (the
  /// All clause).
  ///
  /// BOTH clauses are load-bearing. An engaged stop has no row here, so the
  /// checkmark sits on nothing. The caption points at the Recommended segment,
  /// which holds the stop only while the opt-in does, and a size can be engaged
  /// with the opt-in off (reset residue, a teardown that cleared the pref and
  /// failed): the caption would then send someone to a list without it.
  static func showsEngagedSizeNotice(in catalog: DisplayModeCoordinator.Catalog) -> Bool {
    catalog.engagedSyntheticSize != nil && catalog.rows.contains { $0.mode.isSynthesized }
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
    Self.filteredGroups(catalog.all, rateFilter: rateFilter)
  }

  static func filteredGroups(
    _ modes: [DisplayMode], rateFilter: Double?
  ) -> [DisplayModeCatalog.SizeGroup] {
    let groups = DisplayModeCatalog.groupedBySize(modes)
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
    // THE apply path, shared with the hub's Size pop-up, including the
    // already-on-screen guard, which lives on the coordinator so the two cannot
    // drift. `.settings` routes a failed `begin()` to the banner region; the
    // SURFACE is the key-window decision, sampled from this window's key state
    // synchronously at the click (see `DisplayHubView`).
    coordinator.selectFromList(
      mode, on: displayID, from: .settings,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel,
      currentModeID: catalog.alreadyOnScreenModeID
    )
  }

  // MARK: - Focus, scrolling and announcements

  /// The page opens on the mode the display is running, not at the top of a
  /// list hundreds of rows long, and ONLY when that row would be off screen:
  /// scrolling takes the title and the list controls out of view.
  ///
  /// The eight-row threshold was measured at a smaller window (header and
  /// controls ~100 pt, a row ~43 pt). It is a floor now rather than a count;
  /// both ways of being wrong here cost nothing.
  ///
  /// One main-actor hop, deliberately: the rows are not laid out when `onAppear`
  /// fires, and scrolling in the same turn lands on nothing at all.
  private func scrollToCurrent(_ proxy: ScrollViewProxy) {
    guard let id = currentRowID,
          let index = visibleRowIDs.firstIndex(of: id),
          index >= Self.rowsVisibleFromTheTop
    else { return }
    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
  }

  private static let rowsVisibleFromTheTop = 8

  /// The row the checkmark is on. `Recommended` holds one row per SIZE; `All`
  /// holds the exact mode, behind a size row that may be shut, in which case the
  /// size row is what to land on.
  private var currentRowID: String? {
    guard let catalog, let onScreen = catalog.onScreen else { return nil }
    switch listMode {
    case .recommended:
      return catalog.rows.first { catalog.isCurrentSize($0.mode) }.map { RowID.mode($0.id) }
    case .all:
      // Answers nil while a size this app renders is engaged: the All list does
      // not hold that size, so there is nothing to scroll to.
      return rowID(forModeAt: onScreen, in: catalog)
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

  /// A11y 6's rotor: the two rows anyone navigates to directly. Both are
  /// omitted when absent, since a display can report no native flag and the rate
  /// pop-up can filter the current mode out.
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

  /// Every row on screen, in render order: size rows included, the modes of a
  /// shut size excluded. Arrow keys, the rotor and `scrollToCurrent` all read
  /// it, so all three follow the collapse for free.
  private var visibleRowIDs: [String] {
    Self.rowIDs(
      for: listMode, in: catalog, rateFilter: rateFilter, expandedSizes: expandedSizes
    )
  }

  /// Ids only, and deliberately not `rows(...).map(\.id)`: this runs on every
  /// body evaluation, and building the words for hundreds of rows just to keep
  /// the ids is work the arrow keys do not need. A test pins that the two orders
  /// agree.
  static func rowIDs(
    for mode: ListMode, in catalog: DisplayModeCoordinator.Catalog?,
    rateFilter: Double?, expandedSizes: Set<String>
  ) -> [String] {
    guard let catalog else { return [] }
    switch mode {
    case .recommended:
      return catalog.rows.map { RowID.mode($0.id) }
    case .all:
      return filteredGroups(catalog.all, rateFilter: rateFilter).flatMap { group in
        [group.header]
          + (isExpanded(group, rateFilter: rateFilter, expandedSizes: expandedSizes)
            ? group.modes.map { RowID.mode($0.ioModeID) } : [])
      }
    }
  }

  /// Maps arrow keys onto row focus. HALF of accessibility contract 6, which
  /// asks for one Tab stop with arrows within: every row is its own focusable
  /// button, so Tab still visits each one, and SwiftUI offers no supported way
  /// to keep a control focusable while taking it out of the Tab loop.
  ///
  /// Unverified: synthetic keystrokes cannot be delivered to an `LSUIElement`
  /// app from the shell (they go to the terminal), so whether anything consumes
  /// the arrows before `onMoveCommand` sees them is unknown. Hardware-checklist
  /// item, not measured behaviour.
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

  /// Takes the mode it announces rather than reading `listMode` back: the
  /// caller is the picker's setter, and reading the state there lands one toggle
  /// behind.
  private func announce(_ mode: ListMode, in catalog: DisplayModeCoordinator.Catalog?) {
    // Counted from the CONTENT, not from `rowIDs`: with sizes collapsed a row
    // count is neither the number of modes nor the number of sizes.
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

/// One row of either list: the words it shows, the marks it wears, and what
/// pressing it does. A value, so the whole list is derivable and assertable
/// without laying out a view.
struct AllModesRow: Identifiable, Equatable {
  /// What a press does, which is also what kind of row this is.
  enum Kind: Equatable {
    /// Applies this mode. On a curated row it is the mode the press would
    /// APPLY, not the row's representative, so the two lists can carry
    /// different provenance for the same size.
    case mode(DisplayMode)
    /// Opens or shuts the size group filed under this header.
    case size(header: String)
  }

  let id: String
  let kind: Kind
  let title: String
  let detail: String
  var badge: String?
  let spoken: String
  var spokenValue: String?
  let isCurrent: Bool
  var chevronExpanded: Bool?
}

private extension DisplayModeCatalog.SizeGroup {
  /// `ForEach` needs an identity for the section, and the size is it: two
  /// groups cannot share one.
  var header: String { AllModesPage.RowID.size(width: logicalWidth, height: logicalHeight) }
}

/// One row in either list: a selectable mode, or a size that opens to its
/// rates. The whole row is the hit region, since a bare `.plain` button is only
/// as clickable as its text is wide.
///
/// Size rows use the SAME component on purpose. A `DisclosureGroup` toggles only
/// from its chevron glyph (measured on this window); here the chevron is drawn
/// by a row that is entirely clickable.
private struct ModeChoice: View {
  let title: String
  let detail: String
  /// A short mark at the trailing edge, or nothing. Kept out of `detail` so it
  /// reads as a note about the row and lines up down the list.
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
  /// Whether the trailing chevron points at an open size, or nil on a row that
  /// discloses nothing. Hidden from accessibility: `spokenValue` already says
  /// what it means.
  var chevronExpanded: Bool?
  let action: () -> Void

  @State private var isHovering = false
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .foregroundStyle(lighting.accent)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(true)
        Text(verbatim: title)
          .foregroundStyle(SettingsTheme.titleColor)
        Text(verbatim: detail)
          .foregroundStyle(SettingsTheme.bodyColor)
        Spacer(minLength: 8)
        if let badge {
          // NOT `SettingsBadge`, the window's accent capsule: the accent
          // already carries the ring and the checkmark on the row in use, and a
          // badge in that hue would read as a second "you are here".
          Text(verbatim: badge)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsTheme.faintColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.08))
            )
            .accessibilityHidden(true)
        }
        if let chevronExpanded {
          // One glyph rotated, not an up/down symbol swap: the rotation rides
          // the expansion's animation and a swap cannot. Same as the menu bar's
          // `PanelDisclosureRow`, so the two resolution surfaces move alike.
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(SettingsTheme.faintColor)
            .rotationEffect(.degrees(chevronExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      ModeChoiceButtonStyle(
        isHovering: isHovering, isCurrent: isCurrent, accent: lighting.accent))
    .onHover { isHovering = $0 }
    .animation(SettingsTheme.hoverMotion, value: isHovering)
    .accessibilityLabel(Text(verbatim: spoken))
    .accessibilityValue(Text(verbatim: spokenValue ?? ""))
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}

/// Hover, the selection ring, and a pressed state (`buttons.md`). Without a
/// pressed state a control that reconfigures the screen invites a second click.
///
/// The checkmark stays beside the ring, so the state is never carried by colour
/// alone.
private struct ModeChoiceButtonStyle: ButtonStyle {
  let isHovering: Bool
  let isCurrent: Bool
  let accent: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(shape.fill(fill(pressed: configuration.isPressed)))
      .overlay(ring)
      .opacity(configuration.isPressed ? 0.85 : 1)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
  }

  @ViewBuilder private var ring: some View {
    if isCurrent {
      shape.stroke(accent.opacity(0.5), lineWidth: 1)
    }
  }

  private func fill(pressed: Bool) -> Color {
    if pressed { return .white.opacity(0.13) }
    if isCurrent { return accent.opacity(0.12) }
    return .white.opacity(isHovering ? 0.06 : 0)
  }
}
