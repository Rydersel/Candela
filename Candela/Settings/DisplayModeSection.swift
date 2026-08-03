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
      if let catalog, !catalog.rows.isEmpty {
        ForEach(catalog.rows) { row in
          ModeChoice(
            title: sizeLabel(row.mode),
            detail: nil,
            badges: badges(for: row, in: catalog),
            isCurrent: isCurrentSize(row.mode, in: catalog)
          ) {
            select(size: row, in: catalog)
          }
        }
        curationCaption(catalog)
        refreshPicker(catalog)
        rememberToggle
        allModes(catalog)
      } else {
        SettingsCaption("\(AppInfo.productName) found no resolutions it can switch between on this display.")
      }
    }
  }

  /// States what OUR curation did, and why. It deliberately makes no claim
  /// about what macOS shows or hides: no CoreGraphics enumeration reports what
  /// Displays settings chooses to present, which is the same reason the
  /// per-mode "hidden" flag was cut from the mode model. Both numbers count
  /// distinct sizes, and the only sizes dropped are the ones below the
  /// usability floor — so this sentence is exactly true, not approximately.
  @ViewBuilder private func curationCaption(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    if catalog.rows.count < catalog.distinctLogicalSizes {
      SettingsCaption("Showing \(catalog.rows.count) of the \(catalog.distinctLogicalSizes) sizes this display reports — the rest are too small to use as a desktop. All modes lists every one.")
    }
  }

  // MARK: - Preview

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
          SettingsCaption("\(AppInfo.productName) could not complete that change (CoreGraphics error \(failure.cgErrorCode)). The display is still showing the preview — try again.")
        }
        if preview.isCountingDown {
          Text(verbatim: countdownText(preview.secondsRemaining))
            .foregroundStyle(.secondary)
        } else if preview.failure != nil {
          SettingsCaption("The automatic revert has already run, so it will not try again on its own.")
        }

        HStack(spacing: 8) {
          Button("Keep") { Task { await keep() } }
            .buttonStyle(.borderedProminent)
          Button("Revert Now") { Task { await coordinator.revert() } }
        }
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder private var startFailureBanner: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      VStack(alignment: .leading, spacing: 6) {
        SettingsCaption("\(AppInfo.productName) could not switch this display (CoreGraphics error \(failure.error.cgErrorCode)). Nothing changed.")
        Button("OK") { coordinator.dismissStartFailure() }
      }
    }
  }

  private func countdownText(_ seconds: Int) -> String {
    seconds == 1
      ? "Reverting to the previous resolution in 1 second."
      : "Reverting to the previous resolution in \(seconds) seconds."
  }

  private func keep() async {
    let outcome = await coordinator.confirm()
    guard case .committed = outcome else { return }
    // The commit writes `storedDisplayMode` only while this display is being
    // remembered; the seam is told only when a pref actually changed (D27).
    if coordinator.isRemembering(displayID) {
      actions.prefDidChange(.storedDisplayMode, persistenceKey: persistenceKey)
    }
  }

  // MARK: - Rows

  private func sizeLabel(_ mode: DisplayMode) -> String {
    // RM11: "looks like", never "true native HiDPI". On a fixed panel only one
    // logical size is a true 2× of the native framebuffer; everything else
    // renders oversized and downsamples.
    "Looks like \(mode.logicalWidth) × \(mode.logicalHeight)"
  }

  private func refreshLabel(_ hz: Double) -> String {
    // Rates are quantized to one decimal at the CoreGraphics boundary, so 59.9
    // is a real value and truncating it to "59 Hz" would both misreport it and
    // collide with a genuine 59 Hz row.
    hz == hz.rounded() ? "\(Int(hz)) Hz" : String(format: "%.1f Hz", hz)
  }

  /// True for the row whose LOGICAL SIZE the display is running. Comparing
  /// `ioModeID` instead would leave the checkmark off whenever the user is at a
  /// size's slower refresh rate: the curated row's representative mode is that
  /// size's FASTEST rate, so the IDs differ while the size is plainly selected.
  private func isCurrentSize(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) -> Bool {
    guard let current = catalog.current else { return false }
    return current.logicalWidth == mode.logicalWidth && current.logicalHeight == mode.logicalHeight
  }

  private func badges(
    for row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog
  ) -> [String] {
    var badges: [String] = []
    if row.mode.isNative { badges.append("Native") }
    if row.mode.isHiDPI { badges.append("HiDPI") }
    if catalog.nativeKnown, row.isScaled, !row.mode.isNative { badges.append("Scaled") }
    return badges
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
          coordinator.setRemembering(remembering, for: displayID)
          // Turning it on writes the flag AND stores the current mode, so the
          // fan-out is the union of both rows, never one representative name.
          if remembering {
            actions.prefsDidChange([.rememberDisplayMode, .storedDisplayMode],
                                   persistenceKey: persistenceKey)
          } else {
            actions.prefDidChange(.rememberDisplayMode, persistenceKey: persistenceKey)
          }
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
              title: "\(mode.logicalWidth) × \(mode.logicalHeight)",
              detail: "\(refreshLabel(mode.refreshHz))\(mode.isHiDPI ? " · HiDPI" : "")",
              badges: [],
              isCurrent: mode.ioModeID == catalog.current?.ioModeID
            ) {
              apply(mode)
            }
          }
        }
      }
      .frame(maxHeight: 240)
    } label: {
      Text("All modes (\(catalog.all.count))")
    }
  }

  // MARK: - Selection

  /// Applies the chosen SIZE while keeping the refresh rate the display is
  /// already running, when that size offers it — a size change should not
  /// silently move someone from 60 Hz to 175 Hz, and the curated row carries
  /// the size's fastest rate as its representative.
  ///
  /// `ModePersistence.resolve` is the tested answer to exactly this question
  /// (geometry + desired refresh → best live mode, deterministic down to
  /// `ioModeID`), so the rule is not re-invented in the view layer. Its
  /// cross-size fallbacks cannot help here — the row came from the live list —
  /// so a resolved mode at a different size is rejected in favour of the row's
  /// own representative.
  private func select(size row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog) {
    let wanted = DisplayModeDescriptor(
      logicalWidth: row.mode.logicalWidth,
      logicalHeight: row.mode.logicalHeight,
      pixelWidth: row.mode.pixelWidth,
      pixelHeight: row.mode.pixelHeight,
      refreshHz: catalog.current?.refreshHz ?? row.mode.refreshHz
    )
    apply(resolved(wanted, in: catalog, matching: row.mode) ?? row.mode)
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
    guard let mode = resolved(wanted, in: catalog, matching: current) else { return }
    apply(mode)
  }

  private func resolved(
    _ descriptor: DisplayModeDescriptor,
    in catalog: DisplayModeCoordinator.Catalog,
    matching size: DisplayMode
  ) -> DisplayMode? {
    let match: DisplayMode? = switch ModePersistence.resolve(descriptor, in: catalog.all) {
    case let .exact(mode): mode
    case let .refreshRateDiffers(mode): mode
    case let .scaleDiffers(mode): mode
    case let .sizeDiffers(mode): mode
    case .none: nil
    }
    guard let match,
          match.logicalWidth == size.logicalWidth,
          match.logicalHeight == size.logicalHeight
    else { return nil }
    return match
  }

  private func apply(_ mode: DisplayMode) {
    // Never speculative: this runs only from an explicit click naming this
    // display's mode.
    Task { await coordinator.select(mode, on: displayID) }
  }
}

/// One selectable mode. A row-shaped button: the whole row is the hit region
/// (a bare `.plain` button is only as clickable as its text is wide), and it
/// carries hover and pressed states, without which it reads as static text.
private struct ModeChoice: View {
  let title: String
  let detail: String?
  let badges: [String]
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
        ForEach(badges, id: \.self) { badge in
          Text(verbatim: badge)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isHovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
  }
}
