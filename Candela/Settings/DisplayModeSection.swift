import CandelaKit
import CoreGraphics
import SwiftUI

/// Resolution and refresh rate for one display.
///
/// Curation and resolution policy live in `CandelaKit`; this file renders what
/// `DisplayModeCatalog` returns and routes the user's choice through
/// `DisplayModeCoordinator`, which owns the preview session.
///
/// `@MainActor` for the same reason as `CommandTuningGrid`: it stores
/// main-actor types and reads them from computed properties, which are
/// nonisolated on a plain `View` under complete concurrency checking.
@MainActor
struct DisplayModeSection: View {
  let state: AppModel.DisplayState
  let coordinator: DisplayModeCoordinator
  let actions: SettingsActions

  @State private var showingAllModes = false

  private var displayID: CGDirectDisplayID { state.display.id }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }
  private var persistenceKey: String { state.display.persistenceKey }

  var body: some View {
    Section("Resolution") {
      previewBanner
      startFailureBanner
      reapplyBanner
      // A nil catalog is "not enumerated yet", NOT "no modes" — rendering the
      // empty state for it flashes false copy on every pane switch.
      if let catalog {
        if !catalog.rows.isEmpty {
          // The caption rides with the control it explains rather than as a row
          // of its own — same reason `SettingRow` exists at all.
          SettingRow(caption: curationCaption(catalog)) {
            sizePicker(catalog)
          }
          refreshPicker(catalog)
        } else if !catalog.all.isEmpty {
          // Every size this panel reports is under the usability floor. The
          // curated list is empty, the full one is not — so the escape hatch
          // below is the whole feature here, and saying "no resolutions" while
          // holding dozens would be false.
          SettingsCaption("Every size this display reports is too small to use as a desktop. All sizes and refresh rates lists them anyway.")
        } else {
          SettingsCaption("\(AppInfo.productName) found no resolutions it can switch between on this display.")
        }

        if !catalog.all.isEmpty {
          rememberToggle
          // Outside the curated branch on purpose: the escape hatch has to
          // survive the case it exists for.
          allModes(catalog)
        }
      }
    }
  }

  /// States what OUR curation did, and why. It deliberately makes no claim
  /// about what macOS shows or hides: no CoreGraphics enumeration reports what
  /// Displays settings chooses to present, which is the same reason the
  /// per-mode "hidden" flag was cut from the mode model. Both numbers count
  /// distinct sizes, and the only sizes dropped are the ones below the
  /// usability floor — so this sentence is exactly true, not approximately.
  ///
  /// Returns the caption rather than rendering it so `SettingRow` can bind it to
  /// the dropdown; nil when nothing was curated out, because a menu that holds
  /// everything has nothing to explain.
  private func curationCaption(_ catalog: DisplayModeCoordinator.Catalog) -> SettingsCaption? {
    guard catalog.rows.count < catalog.distinctLogicalSizes else { return nil }
    return SettingsCaption(verbatim: "Showing \(catalog.rows.count) of the \(catalog.distinctLogicalSizes) sizes this display reports — the rest are too small to use as a desktop. All sizes and refresh rates, below, holds every one of them.")
  }

  // MARK: - Preview

  /// The SECOND surface, kept deliberately.
  ///
  /// `ModeConfirmationWindow` is the primary one now — it takes every preview
  /// whatever started it, and it goes on the display that changed, which is what
  /// the owner asked for and what macOS itself does. This banner is no longer
  /// where a settings-started change is normally answered.
  ///
  /// It stays because the window is a *floating panel on one specific display*
  /// and the answers it offers are safety answers. It is the recovery path for
  /// every case where that window is on screen but not usable: a failed revert
  /// on a mode that left the display barely readable, a window that landed on a
  /// display the user cannot see (a mirror sample lagging a break puts it on the
  /// ex-master), a preview whose display departed. Gated on the DISPLAY and
  /// never on origin, and answering with the same intent-carrying values, so
  /// whichever surface is reachable can end the same session. Two live surfaces
  /// for one preview is the point.
  ///
  /// (A first click that does not take is NOT one of those cases: measured
  /// 2026-08-04 on real hardware, Keep and Revert both fire on the first click
  /// of a genuine mouse-down in the never-activated panel.)
  @ViewBuilder private var previewBanner: some View {
    if let preview = coordinator.preview, preview.displayID == displayID {
      VStack(alignment: .leading, spacing: 6) {
        Text("Keep this resolution?")
          .font(.callout.weight(.semibold))
        Text(verbatim: "\(sizeLabel(preview.mode)), \(refreshLabel(preview.mode.refreshHz))")
          .foregroundStyle(.secondary)

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent here would
          // leave the display on a mode the user never approved, held only
          // until the app exits.
          SettingsCaption(DisplayModeCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          Text(verbatim: countdownText(preview.secondsRemaining))
            .foregroundStyle(.secondary)
        } else if preview.failure != nil {
          SettingsCaption(DisplayModeCopy.expiryAlreadyRan)
        }

        HStack(spacing: 8) {
          // Both answers carry the preview THIS banner is rendering, so a
          // selection landing between the click and the queued operation is
          // refused as stale rather than resolved by an answer given about
          // something else.
          Button("Keep") { Task { await keep(preview) } }
            .buttonStyle(.borderedProminent)
          Button("Revert Now") { Task { await coordinator.revert(preview) } }
        }
        // Belt to the intent check's braces: while a selection is still landing
        // the banner is about to change, so offering an answer to the old one
        // is pointless even though it is now harmless.
        .disabled(coordinator.isApplying)
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder private var startFailureBanner: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      VStack(alignment: .leading, spacing: 6) {
        SettingsCaption(DisplayModeCopy.startFailure)
          .help("CoreGraphics error \(failure.error.cgErrorCode)")
        Button("OK") { coordinator.dismissStartFailure() }
      }
    }
  }

  /// What reapply could not do, said where the stored-mode toggle that asked
  /// for it lives.
  ///
  /// Reapply runs at launch and on reconnect with nobody in front of the
  /// screen, so this is not a notification the user missed — it is the whole
  /// report, and it waits here until they dismiss it, choose a mode themselves,
  /// or unplug the display. Rendering it in the section that owns "Remember
  /// this resolution" is deliberate: the control that made the promise is the
  /// one that has to admit it could not keep it.
  @ViewBuilder private var reapplyBanner: some View {
    if let report = coordinator.reapplyReports[displayID] {
      VStack(alignment: .leading, spacing: 6) {
        SettingsCaption(DisplayModeCopy.reapply(
          requested: report.requested, notice: report.notice
        ))
        .modifier(ReapplyDiagnostic(notice: report.notice))
        Button("OK") { coordinator.dismissReapplyReport(for: displayID) }
      }
      .padding(.vertical, 2)
    }
  }

  private func countdownText(_ seconds: Int) -> String {
    DisplayModeCopy.countdown(seconds)
  }

  /// The stored-mode fan-out is NOT done here: `DisplayModeCoordinator` owns it
  /// (`didStoreMode`), so the panel's confirmation surface cannot forget it.
  private func keep(_ answered: DisplayModeCoordinator.Preview) async {
    await coordinator.confirm(answered)
  }

  // MARK: - Rows

  private func sizeLabel(_ mode: DisplayMode) -> String {
    DisplayModeCopy.size(mode)
  }

  private func refreshLabel(_ hz: Double) -> String {
    DisplayModeCopy.refresh(hz)
  }

  /// Refresh rate, then the Native / HiDPI / Scaled words, for the full list's
  /// second column.
  ///
  /// Same words as the popup's `badgedSize`, different punctuation: a popup item
  /// is one label and parenthesises them, a two-column row already has a
  /// separator. The words are what RM11 rests on now that the size label is a
  /// bare "2560 × 1440", and this list is the surface where dropping them would
  /// leave hundreds of unexplained sizes.
  private func detailLabel(
    for mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog
  ) -> String {
    ([refreshLabel(mode.refreshHz)] + catalog.badges(for: mode)).joined(separator: " · ")
  }

  // MARK: - Size

  /// The curated sizes as a dropdown.
  ///
  /// **The binding is one-way in practice, and deliberately so.** The getter
  /// reads the catalog's CURRENT mode — never a `@State` mirror, which would
  /// drift the moment a preview reverted, System Settings changed the mode, or
  /// the display was replugged. The setter is the only writer, and it does not
  /// assign anything: it calls `select(size:in:)`, the same entry the rows used,
  /// so a choice still enters the preview-with-countdown-revert flow instead of
  /// stranding someone on a mode they cannot see. A plain `@State` selection
  /// would have bypassed that flow — and would have fired it again on the way
  /// back when the countdown reverted.
  ///
  /// The popup therefore snaps back to the running mode until the change lands,
  /// which is the truth: nothing is applied until the preview is kept.
  @ViewBuilder private func sizePicker(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    // "Size:", not "Resolution:" — the section is already called Resolution, and
    // this row now pairs with "Refresh rate:" directly below it. The two
    // together are what "resolution" means.
    Picker("Size:", selection: Binding(
      get: { curatedSelection(in: catalog) },
      set: { id in
        guard let id, let row = catalog.rows.first(where: { $0.id == id }) else { return }
        select(size: row, in: catalog)
      }
    )) {
      // The size on screen is not always one we curated — a display left below
      // the usability floor by System Settings is still running something, and a
      // popup that named none of it would read as broken. Offered as an item so
      // the closed control tells the truth; choosing it is the no-op that
      // choosing the current size has always been.
      if curatedSelection(in: catalog) == nil {
        Text(verbatim: catalog.current.map(catalog.badgedSize) ?? "Unknown")
          .tag(DisplayModeRow.ID?.none)
      }
      ForEach(catalog.rows) { row in
        Text(verbatim: catalog.badgedSize(row.mode))
          .tag(DisplayModeRow.ID?.some(row.id))
      }
    }
  }

  /// The curated row the display is running, by SIZE — `ioModeID` would come up
  /// empty whenever the user is at a size's slower refresh rate, since the row's
  /// representative mode is that size's fastest. nil means the running size is
  /// not one of ours.
  private func curatedSelection(in catalog: DisplayModeCoordinator.Catalog) -> DisplayModeRow.ID? {
    catalog.rows.first { catalog.isCurrentSize($0.mode) }?.id
  }

  // MARK: - Refresh rate

  @ViewBuilder private func refreshPicker(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    if let current = catalog.current {
      let rates = DisplayModeCatalog.refreshRates(
        in: catalog.all,
        logicalWidth: current.logicalWidth,
        logicalHeight: current.logicalHeight
      )
      if rates.count > 1 {
        Picker("Refresh rate:", selection: Binding(
          get: { current.refreshHz },
          set: { hz in select(refreshHz: hz, in: catalog) }
        )) {
          ForEach(rates, id: \.self) { hz in
            Text(verbatim: refreshLabel(hz)).tag(hz)
          }
        }
      }
    }
  }

  // MARK: - Remember

  private var rememberToggle: some View {
    SettingRow("Reapplies your choice when this display reconnects or \(AppInfo.productName) launches. Changes you make in System Settings are left alone until then.") {
      Toggle("Remember this resolution for this display", isOn: Binding(
        get: { coordinator.isRemembering(displayID) },
        set: { remembering in
          // Only the flag is announced here. Turning it on ALSO stores the
          // current mode, and that write announces itself from inside the
          // coordinator (`didStoreMode`) — naming `.storedDisplayMode` here as
          // well would put the rule in two places, which is how it was lost the
          // first time.
          coordinator.setRemembering(remembering, for: displayID)
          actions.prefDidChange(.rememberDisplayMode, persistenceKey: persistenceKey)
        }
      ))
    }
  }

  // MARK: - Full list

  @ViewBuilder private func allModes(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    DisclosureGroup(isExpanded: $showingAllModes) {
      // A real panel reports 120–332 modes. Scrolling them inside their own
      // container keeps the rest of the pane reachable instead of pushing the
      // reset button hundreds of rows down.
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(catalog.all) { mode in
            ModeChoice(
              // The same label as the curated rows a few pixels above, and — the
              // part that matters — wearing the same badges. This list is where
              // RM11 is easiest to lose: hundreds of sizes, most of them scaled,
              // and the size alone says nothing about which.
              title: sizeLabel(mode),
              detail: detailLabel(for: mode, in: catalog),
              isCurrent: mode.ioModeID == catalog.current?.ioModeID
            ) {
              apply(mode, in: catalog)
            }
          }
        }
      }
      .frame(maxHeight: 240)
    } label: {
      // Not "All sizes": it holds every size at EVERY refresh rate, which on the
      // development Dell is 41 sizes and 332 modes. "Modes" was jargon, and it
      // clashed with the Size and Refresh rate rows above.
      Text("All sizes and refresh rates (\(catalog.all.count))")
    }
  }

  // MARK: - Selection

  /// Applies the chosen SIZE while keeping the refresh rate the display is
  /// already running, when that size offers it. The rule itself lives on
  /// `Catalog` — the panel applies the same one.
  private func select(size row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog) {
    apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
  }

  private func select(refreshHz: Double, in catalog: DisplayModeCoordinator.Catalog) {
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

  private func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // Clicking the mode already on screen used to apply a no-op and then demand
    // "Keep this resolution?" with a full countdown for a change nobody made.
    guard mode.ioModeID != catalog.current?.ioModeID else { return }
    // Never speculative: this runs only from an explicit click naming this
    // display's mode. No `Task` here — `select` is fire-and-forget into the
    // coordinator's queue, which is what serialises two fast clicks; spawning
    // one per click is precisely how the banner ends up naming a different mode
    // than the one "Keep" would commit.
    //
    // `.settings` no longer picks the answering surface — the confirmation
    // window takes every preview now — but it still routes a failed `begin()`,
    // which this pane reports in `startFailureBanner` and the panel cannot.
    coordinator.select(mode, on: displayID, from: .settings)
  }
}

/// The CoreGraphics code stays out of the sentence and goes in a tooltip — it
/// is diagnostic, and belongs nowhere near text someone reads while working out
/// what happened to their screen. Only a `.failed` notice has one: for a
/// substitution or an unavailable mode there is no error, and an empty tooltip
/// would suggest there was.
private struct ReapplyDiagnostic: ViewModifier {
  let notice: ModeReapplyNotice

  @ViewBuilder func body(content: Content) -> some View {
    if case let .failed(error) = notice {
      content.help("CoreGraphics error \(error.cgErrorCode)")
    } else {
      content
    }
  }
}

/// One selectable mode in the full list. A row-shaped button: the whole row is
/// the hit region (a bare `.plain` button is only as clickable as its text is
/// wide), and it carries hover and pressed states, without which it reads as
/// static text.
///
/// It no longer carries badge capsules: the curated sizes — the only rows that
/// ever had them — are a dropdown now, and their badges are folded into the menu
/// labels. A capsule nobody can pass a badge to is a style rule waiting to drift.
private struct ModeChoice: View {
  let title: String
  let detail: String?
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
        if let detail {
          Text(verbatim: detail)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(ModeChoiceButtonStyle(isHovering: isHovering))
    .onHover { isHovering = $0 }
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
