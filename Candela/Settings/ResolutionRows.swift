import CandelaKit
import CoreGraphics
import SwiftUI

/// The one apply path every resolution control in the settings window goes
/// through. A value rather than a method on a view, because two panes offer the
/// same choice and a second copy would be a second place to get the preview
/// contract wrong. Nothing is applied outside a countdown.
@MainActor
struct ResolutionSelection {
  let coordinator: DisplayModeCoordinator
  let displayID: CGDirectDisplayID
  /// SO6, sampled at the click and carried in. Re-deriving it here would answer
  /// for whatever was key when the row was drawn.
  let surface: DisplayModeCoordinator.PreviewSurface

  /// Keeps the refresh rate the display is already running, when the chosen
  /// size offers it. The rule lives on `Catalog`, shared with the menu-bar panel.
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
    // No `Task` here. `selectFromList` is fire-and-forget into the
    // coordinator's queue, which is what serialises two fast clicks; one Task
    // per click is how the banner ends up naming a different mode than the one
    // "Keep" would commit.
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

/// The size pop-up, the refresh-rate picker and the two empty states, shared by
/// the external hub and the built-in display's page.
///
/// The density model's recommendation callout and the synthesized-sizes opt-in
/// stay out: they are the hub's alone, and SS14 keeps synthesis away from the
/// built-in. The synthesized-rate row IS here because it belongs to the refresh
/// control it replaces.
///
/// `@MainActor` because a `View`'s properties other than `body` are nonisolated
/// under complete concurrency and these read main-actor types.
@MainActor
struct DisplaySizeRows: View {
  let catalog: DisplayModeCoordinator.Catalog

  @Environment(AppModel.self) private var model
  /// SO6's "key settings window" test, read at the click that starts a preview.
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
      // Every size this panel reports is under the usability floor, so the
      // curated list is empty while the full one is not. Saying "no
      // resolutions" while holding dozens would be false.
      SettingsRowNote("Every size this display reports is too small to use as a desktop. All Sizes & Refresh Rates lists them anyway.")
    } else {
      SettingsRowNote("\(AppInfo.productName) found no resolutions it can switch between on this display.")
    }
  }

  /// **The binding is one-way on purpose.** The getter reads the catalog's
  /// CURRENT mode, never a `@State` mirror, which would drift the moment a
  /// preview reverted or System Settings changed the mode. The setter assigns
  /// nothing; it starts the preview-with-countdown flow. So the pop-up snaps
  /// back to the running mode until the change lands, which is the truth.
  private var sizePicker: some View {
    ThemedChoiceRow(label: "Size", selection: Binding(
      get: { Self.curatedSelection(in: catalog) },
      set: { id in
        guard let id, let row = catalog.rows.first(where: { $0.id == id }) else { return }
        selection.select(size: row, in: catalog)
      }
    )) {
      // The size on screen is not always one we curated: a display left below
      // the usability floor by System Settings is still running something, and
      // a pop-up naming none of it reads as broken. Choosing this item is the
      // same no-op as choosing the current size.
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

  /// Static and internal so the app test bundle can assert on the words
  /// without a window (AT10's row-model rule).
  ///
  /// A mark rides along only when it is a COST of choosing this item: the caps
  /// warning (from the row's OUTCOME, not its catalog entry, SO18), the
  /// recommendation, and "Rendered by Candela" (SS5), which stands a virtual
  /// display up. Notes about where a mode came from belong to the All Sizes
  /// page, where a row has the width; see `AllModesPage.rowBadge`.
  ///
  /// When the display has no current mode the caps warning is SUPPRESSED: a
  /// placeholder 0 would both disable the warning and name the wrong rate.
  static func sizeItemLabel(
    _ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog
  ) -> String {
    var marks: [String] = []
    // Never asked of a synthesized row: the question is what rate this size
    // gets in the display's OWN list, and a stop is not in that list. A stop
    // colliding with a published 1x size would be answered about that other
    // size and print a rate this row never applies.
    if !row.mode.isSynthesized,
       let current = catalog.current,
       let outcome = DisplayModeCatalog.outcome(
         selectingWidth: row.mode.logicalWidth,
         selectingHeight: row.mode.logicalHeight,
         currentHz: current.refreshHz,
         in: catalog.all
       ),
       outcome.lowersCurrentRate {
      // First: what the choice costs outranks a note about the display.
      marks.append("caps at \(DisplayModeCopy.refresh(outcome.appliedHz))")
    }
    // A note about this PANEL rather than a cost. By SIZE, like
    // `curatedSelection` below.
    if catalog.isRecommendedSize(row.mode) {
      marks.append(DisplayModeCopy.recommended)
    }
    // The built-in's counterpart: it can never carry a Recommended, since no
    // physical size is filed for it and the density model abstains. Same word
    // System Settings' Displays pane uses.
    if catalog.isDefaultSize(row.mode) {
      marks.append(DisplayModeCopy.defaultSize)
    }
    // A cost, not a provenance note (SS5): picking this stands a virtual
    // display up, takes seconds, and shows in System Settings.
    if row.mode.isSynthesized {
      marks.append(SynthesisCopy.badge)
    }

    let base = DisplayModeCopy.size(row.mode)
    guard !marks.isEmpty else { return base }
    return "\(base) (\(marks.joined(separator: ", ")))"
  }

  /// The curated row the display is running, matched by SIZE. `ioModeID` would
  /// come up empty at a size's slower refresh rate, since the row's
  /// representative mode is that size's fastest. Nil means the running size is
  /// not one of ours, which is what puts an extra item in the menu.
  static func curatedSelection(in catalog: DisplayModeCoordinator.Catalog) -> DisplayModeRow.ID? {
    catalog.rows.first { catalog.isCurrentSize($0.mode) }?.id
  }

  /// Prospective (SO18): the rates offered are the SELECTED size's. Quantized
  /// before deduplication, because `refreshRates(in:)` dedupes raw doubles and
  /// would list 60 twice the day float noise reached it, while NTSC's genuine
  /// 59.9 survives quantization as its own entry.
  ///
  /// Absent while a synthesized size is engaged, since the rates would belong to
  /// a size that is not on the glass and picking one would apply a published
  /// mode to a display whose picture comes from somewhere else.
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
        // Never this card's first row: the same branch draws the size row.
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

  /// The rate is not a property of the stop: the engage tail re-times the
  /// display onto its own mode, so it keeps its own rate [MEASURED 2026-08-18].
  /// States the rule rather than a figure. A row rather than nothing, because a
  /// refresh control that vanished reads as the feature taking the rate away.
  @ViewBuilder private var synthesizedRateRow: some View {
    if catalog.engagedSyntheticSize != nil {
      // Same as the picker it replaces: the size row is always drawn first.
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

/// "Remember this resolution", the mode it has pinned, and the buttons that
/// re-pin and clear it. Shared by the external hub and the built-in's page: the
/// built-in departs whenever the lid closes, and a reconnect is what the reapply
/// pass restores on.
@MainActor
struct RememberResolutionRow: View {
  let displayID: CGDirectDisplayID
  /// Passed in rather than derived from the display's identity: the pref
  /// announcement has to name the key every other control on the page uses.
  let persistenceKey: String

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var coordinator: DisplayModeCoordinator { model.displayModes }

  /// Nameable rather than inline in `body` so the app test bundle can assert on
  /// it. The empty case is awkward to stage by hand (Forget, and a turn-on whose
  /// seeding pin declined), and rendering nothing there looks like a broken
  /// toggle.
  enum PinnedRow: Equatable {
    /// Remembering is off, so there is no promise to describe.
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

  /// The pin tracks the resolution the user keeps. `Set to Current` is the
  /// explicit re-pin for a mode already on screen and disables itself once pin
  /// and running mode agree. `Forget` is the way out short of wiping every
  /// setting in the app.
  var body: some View {
    SettingRow("Restored when this display reconnects, not while you are using it.") {
      VStack(alignment: .leading, spacing: 6) {
        Toggle("Remember this resolution", isOn: Binding(
          get: { coordinator.isRemembering(displayID) },
          set: { remembering in
            // Only the flag is announced here. Turning it on also pins the
            // current mode, and that write announces itself from inside the
            // coordinator (`didStoreMode`). Naming `.storedDisplayMode` here
            // too would put the rule in two places.
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
          // The normal state after Forget, and where a turn-on lands when its
          // seeding pin declined. Silence here reads as the toggle having done
          // nothing. The pin button comes along, or the only route back to a
          // pin is a toggle off and on.
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
            // Never disabled. This is the way out of a pin that cannot be
            // honoured, and a recovery control unavailable in the state it
            // exists to recover from is the D29 rule 3 shape. Clearing during a
            // countdown is harmless: keeping the preview pins the mode the user
            // just accepted, not the forgotten one.
            Button("Forget") { coordinator.forgetStoredMode(on: displayID) }
              .buttonStyle(SettingsSecondaryButtonStyle())
              .accessibilityLabel("Forget the Pinned Resolution")
              .help("Removes the pinned resolution. This display goes on remembering, so the next resolution you keep is pinned in its place.")
          }
        }
      }
    }
  }

  /// Disabled while a preview is outstanding: pinning a mode still under
  /// countdown would record one the user may yet revert. The coordinator's queue
  /// re-checks, so this disable is courtesy rather than the guard.
  ///
  /// `isRedundant` cannot arise with nothing pinned, so the empty row passes
  /// false rather than computing it.
  private func setToCurrentButton(isRedundant: Bool) -> some View {
    Button("Set to Current") { coordinator.pinCurrentMode(on: displayID) }
      .buttonStyle(SettingsSecondaryButtonStyle())
      .accessibilityLabel("Set to Current")
      .disabled(isRedundant || coordinator.preview?.displayID == displayID)
  }

  /// Reads the SAME source the pin writes: live configurator first, catalog
  /// cache as fallback. For a moment after a countdown expires the cache still
  /// names the reverted-away mode, and comparing against it enables the button
  /// for a pin that would be refused, or disables it against a stale answer.
  private func pinnedMatchesCurrent(_ stored: DisplayModeDescriptor) -> Bool {
    guard let live = coordinator.configurator.currentMode(for: displayID)
      ?? coordinator.catalogs[displayID]?.current
    else { return false }
    return live.descriptor == stored
  }
}
