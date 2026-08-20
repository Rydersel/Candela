import CandelaKit
import CoreGraphics
import SwiftUI

/// The one apply path every resolution control in the settings window goes
/// through.
///
/// A value rather than a method on a view, because two panes now offer the same
/// choice (the external hub and the built-in display's page) and a second copy
/// of this would be a second place to get the preview contract wrong. Nothing is
/// applied outside a countdown, and the surface that answers is decided once, at
/// the click.
@MainActor
struct ResolutionSelection {
  let coordinator: DisplayModeCoordinator
  let displayID: CGDirectDisplayID
  /// SO6, sampled from the calling window's key state at the click and carried
  /// in rather than re-derived here: a value built during a body evaluation
  /// would answer for whatever was key when the row was drawn.
  let surface: DisplayModeCoordinator.PreviewSurface

  /// Applies the chosen SIZE while keeping the refresh rate the display is
  /// already running, when that size offers it. The rule itself lives on
  /// `Catalog` (the menu-bar panel applies the same one).
  func select(size row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog) {
    apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
  }

  func select(refreshHz: Double, in catalog: DisplayModeCoordinator.Catalog) {
    guard let current = catalog.current else { return }
    let wanted = DisplayModeDescriptor(
      logicalWidth: current.logicalWidth,
      logicalHeight: current.logicalHeight,
      pixelWidth: current.pixelWidth,
      pixelHeight: current.pixelHeight,
      refreshHz: refreshHz
    )
    guard let mode = catalog.mode(matching: wanted, atSizeOf: current) else { return }
    apply(mode, in: catalog)
  }

  func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // Never speculative: this runs only from an explicit click naming this
    // display's mode. No `Task` here: `selectFromList` is fire-and-forget into
    // the coordinator's queue, which is what serialises two fast clicks;
    // spawning one per click is precisely how the banner ends up naming a
    // different mode than the one "Keep" would commit. It also carries the
    // already-on-screen guard, shared with the full mode list.
    //
    // `.settings` routes a failed `begin()` to the banner region, which the
    // menu-bar surface cannot show.
    coordinator.selectFromList(
      mode, on: displayID, from: .settings,
      surface: surface,
      currentModeID: catalog.alreadyOnScreenModeID
    )
  }
}

/// The size pop-up, the refresh-rate picker and the two empty states, as rows
/// for a display page's Display section.
///
/// Shared by the external hub and the built-in display's page: the built-in is
/// an ordinary target for every one of these controls (its identity has a
/// first-class persistence key and the reapply pass already walks it), and it
/// went without them only because the pane that renders it never had them.
///
/// Deliberately NOT in here, because they are the hub's alone: the density
/// model's recommendation callout, and the synthesized-sizes opt-in (SS14 keeps
/// synthesis away from the built-in outright). The synthesized-rate row IS here
/// because it belongs to the refresh control it replaces; on the built-in it is
/// structurally unreachable, since no stop is ever engaged there.
///
/// `@MainActor` for the reason every settings view records: a `View`'s stored
/// and computed properties other than `body` are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct DisplaySizeRows: View {
  let catalog: DisplayModeCoordinator.Catalog

  @Environment(AppModel.self) private var model
  /// SO6's "key settings window" test, read at the click that starts a
  /// preview: `.key` exactly when this view's window is the key window.
  @Environment(\.controlActiveState) private var controlActiveState

  private var displayID: CGDirectDisplayID { catalog.display.id }
  private var selection: ResolutionSelection {
    ResolutionSelection(
      coordinator: model.displayModes,
      displayID: displayID,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel
    )
  }

  var body: some View {
    if !catalog.rows.isEmpty {
      SettingRow("Changes how big text and windows look.") {
        sizePicker
      }
      refreshPicker
      synthesizedRateRow
    } else if !catalog.all.isEmpty {
      // Every size this panel reports is under the usability floor. The curated
      // list is empty, the full one is not, so the sub-page is the whole feature
      // here, and saying "no resolutions" while holding dozens would be false.
      SettingsCaption("Every size this display reports is too small to use as a desktop. All Sizes & Refresh Rates lists them anyway.")
    } else {
      SettingsCaption("\(AppInfo.productName) found no resolutions it can switch between on this display.")
    }
  }

  /// The curated sizes as a dropdown.
  ///
  /// **The binding is one-way in practice, and deliberately so.** The getter
  /// reads the catalog's CURRENT mode, never a `@State` mirror, which would
  /// drift the moment a preview reverted, System Settings changed the mode, or
  /// the display was replugged. The setter is the only writer, and it does not
  /// assign anything: it calls `select(size:in:)`, so a choice still enters the
  /// preview-with-countdown-revert flow instead of stranding someone on a mode
  /// they cannot see. The popup therefore snaps back to the running mode until
  /// the change lands, which is the truth: nothing is applied until the preview
  /// is kept.
  private var sizePicker: some View {
    ThemedChoiceRow(label: "Size", selection: Binding(
      get: { Self.curatedSelection(in: catalog) },
      set: { id in
        guard let id, let row = catalog.rows.first(where: { $0.id == id }) else { return }
        selection.select(size: row, in: catalog)
      }
    )) {
      // The size on screen is not always one we curated: a display left below
      // the usability floor by System Settings is still running something, and a
      // popup that named none of it would read as broken. Offered as an item so
      // the closed control tells the truth; choosing it is the no-op that
      // choosing the current size has always been.
      if Self.curatedSelection(in: catalog) == nil {
        Text(verbatim: catalog.current.map(DisplayModeCopy.size) ?? "Unknown")
          .tag(DisplayModeRow.ID?.none)
      }
      ForEach(catalog.rows) { row in
        Text(verbatim: Self.sizeItemLabel(row, in: catalog))
          .tag(DisplayModeRow.ID?.some(row.id))
      }
    }
  }

  /// Static and internal rather than an instance method, so the app test
  /// bundle can assert on the words without a window: the marks are derivation,
  /// and the caps warning in particular is a claim about the display that only
  /// the catalog can settle (AT10's row-model rule).
  ///
  /// The row's OUTCOME, not its catalog entry (SO18): a size whose applied mode
  /// cannot hold the rate now in use says so on the item.
  ///
  /// The Native/Scaled tags deliberately do NOT ride along: this picker is
  /// deduplicated by logical size, so the distinction words belong to the
  /// surfaces that show the duplicates (SO14/SO18).
  ///
  /// **The revealed-source mark does not ride along.** Marks on one dropdown
  /// item read as a badge queue, so this pop-up states the cost of the choice
  /// (the caps warning) and the recommendation. "Added by Candela" belongs to
  /// the All Sizes page, where a row has the width for it and where a mode we
  /// found sits beside its published neighbour at the same size; see
  /// `AllModesPage.rowBadge`.
  ///
  /// **"Rendered by Candela" does ride along** (SS5), because it is not the
  /// same kind of statement: a synthesized size is one the display does not
  /// have, and choosing it stands a virtual display up. That is a cost, like
  /// the caps warning, and a cost belongs where the choice is made. The
  /// built-in is never offered one (SS14), so this branch is dead there rather
  /// than suppressed there.
  ///
  /// **The density model's mark rides along too**, for the same reason: this
  /// pop-up is where a size is chosen, and a suggestion nobody sees while
  /// choosing is a suggestion the app did not make. One word is all of it: a
  /// mark states the suggestion, and anything that has to be argued (the panel
  /// measurement behind it, an apply button) belongs to a dismissible row.
  ///
  /// `currentHz` is `outcome`'s contract, not a hint: when the display has no
  /// current mode the caps warning is SUPPRESSED entirely, since a placeholder
  /// 0 would both disable the warning and name the wrong rate.
  static func sizeItemLabel(
    _ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog
  ) -> String {
    var marks: [String] = []
    // Never asked of a synthesized row, which `AllModesPage.recommendedRowModel`
    // skips for the same reason: the question is "what rate does this size get
    // in the display's own list", and a stop is not in that list. A stop whose
    // logical size collided with a published 1x size would otherwise be
    // answered about the OTHER size and print a rate this row never applies.
    if !row.mode.isSynthesized,
       let current = catalog.current,
       let outcome = DisplayModeCatalog.outcome(
         selectingWidth: row.mode.logicalWidth,
         selectingHeight: row.mode.logicalHeight,
         currentHz: current.refreshHz,
         in: catalog.all
       ),
       outcome.lowersCurrentRate {
      // First: what this choice costs outranks a note about the display.
      marks.append("caps at \(DisplayModeCopy.refresh(outcome.appliedHz))")
    }
    // Second: a note about this PANEL rather than a cost of the choice. By
    // SIZE, like `curatedSelection` below.
    if catalog.isRecommendedSize(row.mode) {
      marks.append(DisplayModeCopy.recommended)
    }
    // The built-in's counterpart to the mark above (it can never carry a
    // Recommended: no physical size is ever filed for it, so the density
    // model abstains). Same word as System Settings' own Displays pane.
    if catalog.isDefaultSize(row.mode) {
      marks.append(DisplayModeCopy.defaultSize)
    }
    // Third, and the exception to the paragraph above: a synthesized row IS
    // marked here (SS5). "Added by Candela" is a note about where a mode came
    // from, which is why it stays on the All Sizes page; this one is a cost of
    // the choice, in the same family as the caps warning. Picking it stands a
    // virtual display up, takes seconds, and shows in System Settings, so the
    // pop-up where the choice is made is exactly where it has to be legible.
    if row.mode.isSynthesized {
      marks.append(SynthesisCopy.badge)
    }

    let base = DisplayModeCopy.size(row.mode)
    guard !marks.isEmpty else { return base }
    return "\(base) (\(marks.joined(separator: ", ")))"
  }

  /// Nameable for `sizeItemLabel`'s reason: "which row is the display on" is
  /// the pop-up's whole selection, and its nil answer (a running size nobody
  /// curated) is the case that puts an extra item in the menu.
  ///
  /// The curated row the display is running, by SIZE: `ioModeID` would come up
  /// empty whenever the user is at a size's slower refresh rate, since the row's
  /// representative mode is that size's fastest. nil means the running size is
  /// not one of ours.
  static func curatedSelection(in catalog: DisplayModeCoordinator.Catalog) -> DisplayModeRow.ID? {
    catalog.rows.first { catalog.isCurrentSize($0.mode) }?.id
  }

  /// Prospective (SO18): the rates offered are the SELECTED size's, read from
  /// the size picker's own selection, which, because that binding snaps to the
  /// running mode, is the current size until a choice lands. Quantized before
  /// deduplication: `refreshRates(in:)` dedupes raw doubles and would list 60
  /// twice the day float noise reached it, while NTSC's genuine 59.9 survives
  /// quantization as its own entry (the built-in offers both, so the two must
  /// stay apart).
  ///
  /// Absent entirely while a synthesized size is engaged, and `synthesizedRateRow`
  /// takes its place. Two reasons, either of which is enough: the rates it would
  /// list belong to a size that is not on the glass, and picking one would apply
  /// a published mode to a display whose picture comes from somewhere else.
  @ViewBuilder private var refreshPicker: some View {
    if let current = catalog.current, catalog.engagedSyntheticSize == nil {
      let selected = catalog.rows
        .first { $0.id == Self.curatedSelection(in: catalog) }?.mode ?? current
      let raw = DisplayModeCatalog.refreshRates(
        in: catalog.all,
        logicalWidth: selected.logicalWidth,
        logicalHeight: selected.logicalHeight
      )
      let rates = dedupedQuantized(raw)
      if rates.count > 1 {
        // Never this card's first row: the size row above is drawn by the same
        // branch that reaches here.
        SettingsCardDivider()
        ThemedChoiceRow(label: "Refresh rate", selection: Binding(
          get: { DisplayMode.quantizedRefresh(current.refreshHz) },
          set: { hz in selection.select(refreshHz: hz, in: catalog) }
        )) {
          ForEach(rates, id: \.self) { hz in
            Text(verbatim: DisplayModeCopy.refresh(hz)).tag(hz)
          }
        }
      }
    }
  }

  /// What the refresh picker's slot says while a synthesized size is engaged.
  ///
  /// The rate is not a property of the stop: the engage tail re-times the
  /// display onto its own mode, so it keeps its own rate [MEASURED 2026-08-18],
  /// and this states the rule rather than a figure. A row rather than nothing,
  /// because a refresh control that simply vanished would read as the feature
  /// having taken the rate away.
  @ViewBuilder private var synthesizedRateRow: some View {
    if catalog.engagedSyntheticSize != nil {
      // Same reasoning as the picker it replaces: the size row is always drawn
      // before it.
      SettingsCardDivider()
      LabeledContent("Refresh rate") {
        Text(verbatim: SynthesisCopy.keepsPanelRefresh)
          .foregroundStyle(SettingsTheme.bodyColor)
      }
    }
  }

  private func dedupedQuantized(_ rates: [Double]) -> [Double] {
    var seen = Set<Double>()
    return rates.map(DisplayMode.quantizedRefresh).filter { seen.insert($0).inserted }
  }
}

/// "Remember this resolution", the mode it has pinned, and the two buttons that
/// re-pin and clear it.
///
/// Shared by the external hub and the built-in display's page. The built-in is
/// the display this promise is least obvious about and most useful on: it
/// departs whenever the lid closes, and a reconnect is exactly what the reapply
/// pass restores on.
@MainActor
struct RememberResolutionRow: View {
  let displayID: CGDirectDisplayID
  /// The pane's key, passed in rather than derived from the display's identity:
  /// the pref announcement has to name the same key every other control on that
  /// page writes under.
  let persistenceKey: String

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var coordinator: DisplayModeCoordinator { model.displayModes }

  /// What the second line under the Remember toggle is showing.
  ///
  /// Nameable rather than inline in `body` so the app test bundle can assert
  /// on it: the empty case is reachable by two routes that are awkward to
  /// stage by hand (Forget, and a turn-on whose seeding pin declined), and a
  /// row that silently rendered nothing in either would look exactly like the
  /// toggle being broken.
  enum PinnedRow: Equatable {
    /// Remembering is off, so there is no promise on screen to describe.
    case hidden
    /// Remembering is on and nothing is pinned.
    case empty
    case pinned(DisplayModeDescriptor)
  }

  static func pinnedRow(isRemembering: Bool, stored: DisplayModeDescriptor?) -> PinnedRow {
    guard isRemembering else { return .hidden }
    guard let stored else { return .empty }
    return .pinned(stored)
  }

  /// The stored mode is visible while the toggle is on, and it tracks the
  /// resolution the user keeps. `Set to Current` stays as the explicit re-pin
  /// for a mode already on screen; it disables itself once the pin and the
  /// running mode agree, which auto-tracking now makes the usual state.
  /// `Forget` is the way back out, and the only one that does not go through
  /// wiping every setting in the app.
  var body: some View {
    SettingRow("Restored when this display reconnects, not while you are using it.") {
      VStack(alignment: .leading, spacing: 6) {
        Toggle("Remember this resolution", isOn: Binding(
          get: { coordinator.isRemembering(displayID) },
          set: { remembering in
            // Only the flag is announced here. Turning it on ALSO pins the
            // current mode (the seeding inside `setRemembering`), and that
            // write announces itself from inside the coordinator
            // (`didStoreMode`): naming `.storedDisplayMode` here as well would
            // put the rule in two places, which is how it was lost the first
            // time.
            coordinator.setRemembering(remembering, for: displayID)
            actions.prefDidChange(.rememberDisplayMode, persistenceKey: persistenceKey)
          }
        ))
        .themedSwitch()
        .prefIdentifier(.rememberDisplayMode, persistenceKey: persistenceKey)
        switch Self.pinnedRow(
          isRemembering: coordinator.isRemembering(displayID),
          stored: coordinator.storedDescriptor(for: displayID)
        ) {
        case .hidden:
          EmptyView()
        case .empty:
          // States the fact rather than apologising: this is the normal state
          // straight after Forget, and it is also where a turn-on lands when
          // its seeding pin declined (a preview outstanding, a synthesized size
          // engaged). Silence there reads as the toggle having done nothing.
          // The pin button comes along, because otherwise the only route back
          // to a pin is a toggle off and on.
          HStack {
            Text("Nothing pinned.").foregroundStyle(SettingsTheme.bodyColor)
            Spacer()
            setToCurrentButton(isRedundant: false)
          }
        case .pinned(let stored):
          HStack {
            Text(verbatim: "\(DisplayModeCopy.size(stored)) · \(DisplayModeCopy.refresh(stored.refreshHz))")
              .foregroundStyle(SettingsTheme.bodyColor)
            Spacer()
            setToCurrentButton(isRedundant: pinnedMatchesCurrent(stored))
            // Never disabled, deliberately, and not for symmetry with the
            // button beside it: this is the way out of a pin that cannot be
            // honoured, and the reapply banner apologising for that pin is
            // what sends people here. A recovery control that is unavailable
            // in the state it exists to recover from is the D29 rule 3 shape.
            // Clearing while a countdown stands is harmless: keeping the
            // preview afterwards pins the mode the user just accepted, which
            // is a fresh answer rather than the forgotten one coming back.
            Button("Forget") { coordinator.forgetStoredMode(on: displayID) }
              .buttonStyle(SettingsSecondaryButtonStyle())
              .accessibilityLabel("Forget the Pinned Resolution")
              .help("Removes the pinned resolution. This display goes on remembering, so the next resolution you keep is pinned in its place.")
          }
        }
      }
    }
  }

  /// Disabled while a preview is outstanding: pinning a mode that is still
  /// under countdown would record one the user may yet revert. The
  /// coordinator's own queue re-checks (session-authoritative), so this
  /// disable is courtesy, not the guard.
  ///
  /// `isRedundant` is the pin-already-matches-current case, which is the usual
  /// one once auto-tracking has run. There is no such thing with nothing
  /// pinned, so the empty row passes false rather than computing it.
  private func setToCurrentButton(isRedundant: Bool) -> some View {
    Button("Set to Current") { coordinator.pinCurrentMode(on: displayID) }
      .buttonStyle(SettingsSecondaryButtonStyle())
      .accessibilityLabel("Set to Current")
      .disabled(isRedundant || coordinator.preview?.displayID == displayID)
  }

  /// Reads the SAME source the pin writes: live configurator first, catalog
  /// cache as fallback. After a countdown expiry the cache still names the
  /// reverted-away mode for a moment, and a comparison against it would enable
  /// the button for a pin that would be refused, or worse, disable it against a
  /// stale answer.
  private func pinnedMatchesCurrent(_ stored: DisplayModeDescriptor) -> Bool {
    guard let live = coordinator.configurator.currentMode(for: displayID)
      ?? coordinator.catalogs[displayID]?.current
    else { return false }
    return live.descriptor == stored
  }
}
