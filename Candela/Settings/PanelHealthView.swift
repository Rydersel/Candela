import CandelaKit
import CoreGraphics
import SwiftUI

/// One panel's accumulated exposure, a page pushed from the display's OLED
/// Care page rather than embedded in one of its sections (OC19, placement
/// amended by OCR5: a pushed page, no longer a sheet). It owns the map
/// instruments now: the History / Right now lens, the window outlines, and
/// the crosshair readout, all moved here from the old hero so the app has ONE
/// surface for interrogating the map.
///
/// Copy rule, and it is the reason half this file is text (OC11): software has
/// two levers against OLED wear, namely reduce luminance and reduce time at
/// luminance. Nothing here may translate a measurement into a lifespan, a date,
/// a percentage of damage avoided or a score. **Relative exposure is measured
/// and therefore sayable**; everything else on offer is not.
///
/// The three `PanelHealthSummary.Confidence` states are three genuinely
/// different pages, not one page with a badge:
/// - `.insufficient` shows **no figures at all**: under 30 samples there is
///   nothing to be right about, and it is the state a freshly enrolled display
///   sits in for its first half hour (and forever, if the Screen Recording
///   grant never arrives).
/// - `.estimated` means measuring is off, so every figure it can show is
///   labelled an estimate.
/// - `.measured` is the only state that shows a multiple of the panel mean.
///
/// **`confidence` does not answer "is anything being recorded right now."** It
/// is a pure function of the telemetry pref and the stored sample count, so it
/// stays `.measured` forever once 30 samples are on disk: through a revoked
/// Screen Recording grant, and through a Safe Mode session where the driver
/// loop never starts. Both are checked here, ahead of the switch, and both
/// change the page from a present-tense reading to a record of history.
///
/// Deliberately absent: any convergence or trend line. That needs a multi-week
/// soak to read out and belongs to W3b-2; a placeholder for it here would be a
/// claim the data cannot answer.
@MainActor
struct PanelHealthView: View {
  let state: AppModel.DisplayState
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @State private var confirmingDelete = false
  /// Which lens the surface shows. Session state, not a pref.
  @State private var surfaceMode: SurfaceMode = .history
  @State private var showsWindowGhosts = false
  /// Pointer location over the surface, for the crosshair inspection.
  @State private var hoverPoint: CGPoint?

  private enum SurfaceMode { case history, now }

  private var persistenceKey: String { state.display.persistenceKey }
  /// Live handle, used only to ask macOS about the panel's current geometry.
  /// Never persisted and never a key: IDs reassign across a replug. A pushed
  /// page only exists for a connected display, so it is never stale here.
  private var displayID: CGDirectDisplayID? { state.display.id }

  private var displayName: String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  /// The coordinator's single door. Non-mutating by contract: it is called
  /// from a `body`, and it deliberately does not memoize the map it may have to
  /// load, because populating an observation-tracked dictionary during view
  /// update is a mutation SwiftUI would report.
  private var summary: PanelHealthSummary {
    model.oledCare.healthSummary(for: persistenceKey)
  }

  /// Preflight only, never `CGRequestScreenCaptureAccess`: the only prompting
  /// call in the app is the pane's telemetry toggle. Gated on a live display,
  /// because with nothing attached there is no capture to be missing a grant
  /// for and the page is pure history either way.
  ///
  /// Re-read on every render rather than once, because the grant genuinely does
  /// come and go under a running app: each ad-hoc re-sign of a deployed build
  /// can drop it (CLAUDE.md §3), and so can a revocation in System Settings.
  private var screenRecordingMissing: Bool {
    !CGPreflightScreenCaptureAccess()
  }

  var body: some View {
    let summary = self.summary
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SubPageHeader(
          title: "Display Health",
          currentKey: persistenceKey,
          displays: displays,
          onSwitch: onSwitch)
        confidenceNote(summary)
        mapCard(summary)
        findings(summary)
        ownersCard(summary)
        deleteRow
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .confirmationDialog(
      "Delete this display's measurement history?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        // The coordinator's own one-step clear, covering memory, disk and the
        // window attribution derived from it, under its epoch guard so a
        // capture already in flight cannot re-book into what was just deleted.
        // Never re-implemented here.
        model.oledCare.clearExposureHistory(for: persistenceKey)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        verbatim:
          "The accumulated brightness map for \(displayName), and the per-app display time derived from the same observations, are removed from this Mac. This display's total hours of use are a separate count and are not affected."
      )
    }
  }

  // MARK: - Chrome

  private var deleteRow: some View {
    Button("Delete History…", role: .destructive) { confirmingDelete = true }
      .accessibilityLabel("Delete History…")
  }

  // MARK: - Confidence

  /// The one place the states are told apart, so a reader of this file can
  /// check the honesty rule in one screen rather than by tracing `if`s through
  /// the layout.
  ///
  /// Order matters. Safe Mode and a missing grant both stop readings dead while
  /// `confidence` carries on reporting whatever the stored sample count says,
  /// so each is tested BEFORE the switch. Anything else lets the green
  /// "Measured" banner claim a reading a minute in a session that has taken
  /// none.
  @ViewBuilder private func confidenceNote(_ summary: PanelHealthSummary) -> some View {
    if model.isSafeMode {
      // `OledCareCoordinator.start` returns before it builds the driver loop in
      // a safe-mode session, so nothing on this page has a live producer behind
      // it. Same statement as the pane's status row, which is where a reader
      // arrives from.
      PanelHealthBanner(
        symbol: "pause.circle",
        title: Text("Paused for this session (Safe Mode)"),
        message: Text(
          "Shift was held at launch, so no new readings are being taken and no hours are accumulating. Everything shown here was recorded before this session."
        ))
    } else if summary.confidence != .estimated, screenRecordingMissing {
      // Telemetry is switched on and macOS is not letting us capture. Two very
      // different arrivals: a display that has never had the grant, and one
      // measured for weeks whose grant went away under it. The difference is
      // whether the page has history to stand on, so the title is the same and
      // the second half is not.
      PanelHealthBanner(
        symbol: "exclamationmark.triangle",
        title: Text("Waiting on Screen Recording"),
        message: summary.confidence == .measured
          ? Text(
            "Measuring is switched on for this display, but macOS has not granted \(AppInfo.productName) Screen Recording, so no new readings are being taken. What is shown below was recorded while the permission was in place. Grant it again in System Settings > Privacy & Security > Screen Recording."
          )
          : Text(
            "Measuring is switched on for this display, but macOS has not granted \(AppInfo.productName) Screen Recording, so no readings are being taken. Grant it in System Settings > Privacy & Security > Screen Recording."
          ))
    } else {
      switch summary.confidence {
      case .measured:
        PanelHealthBanner(
          symbol: "checkmark.circle",
          title: Text("Measured"),
          message: Text(
            "The figures below are built from the readings recorded so far, one a minute while this display has been awake and in use, and they describe this display against itself. Readings are still being taken."
          ))
      case .estimated:
        PanelHealthBanner(
          symbol: "questionmark.circle",
          title: Text("Estimated: brightness is not being measured"),
          // The second sentence names a producer, so it has to check that the
          // producer is running. Window observation is its own pref and can be
          // off on its own; with both off the page was claiming window geometry
          // while the list below it read "No data yet".
          message: summary.observationEnabled
            ? Text(
              "Measuring is off for this display, so nothing here comes from the screen itself. What is left is window geometry: which app held which part of the display, and for how long. Turn on \"Measure how bright each part of this display is\" in OLED Care to record what the display is actually showing."
            )
            : Text(
              "Measuring is off for this display and so is app attribution, so nothing new is being recorded at all. Anything below was recorded earlier. Turn on \"Measure how bright each part of this display is\" and \"Note which apps are on this display\" in OLED Care to start recording again."
            ))
      case .insufficient:
        PanelHealthBanner(
          symbol: "clock",
          title: Text("Not enough readings yet"),
          message: Text(
            "Readings are taken once a minute while this display is awake and in use, and it takes \(ExposureAccumulator.minimumSamplesForAnalysis) of them before there is anything worth drawing. Nothing is shown until then."
          ))
      }
    }
  }

  // MARK: - Map

  /// The map as an instrument (OCR5): the heat surface drawn the way the
  /// monitor hangs on the desk (`PanelExposureSurface` re-orders a rotated
  /// display's history for presentation; storage stays panel-native), with
  /// the lens picker, the window outlines and the crosshair readout, all
  /// moved here from the old pane hero.
  @ViewBuilder private func mapCard(_ summary: PanelHealthSummary) -> some View {
    let live = model.oledCare.latestSample(for: persistenceKey)
    let historyBlank = summary.confidence != .measured
    let aspect =
      OledPanelGeometry.displayAspect(for: displayID)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    let rotation = OledPanelGeometry.rotation(for: displayID)
    // The displayed cells are the one truth every sub-layer (surface, ghosts,
    // crosshair readout) shares, so the inspection can never describe a frame
    // the surface is not drawing.
    let displayed: [Double]? =
      surfaceMode == .history ? (historyBlank ? nil : summary.cells) : live?.cells

    VStack(alignment: .leading, spacing: 10) {
      Text("Where this display has been lit")
        .font(.subheadline.weight(.semibold))

      HStack(spacing: 10) {
        Picker("Map", selection: $surfaceMode) {
          Text("History").tag(SurfaceMode.history)
          Text("Right now").tag(SurfaceMode.now)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
        .accessibilityLabel("Map shows")
        Toggle("Windows", isOn: $showsWindowGhosts)
          .toggleStyle(.button)
          .controlSize(.small)
          .help("Outline the windows on this display, from the same permission-free snapshot app attribution uses.")
        Spacer(minLength: 0)
      }

      if let displayed {
        PanelExposureSurface(
          cells: displayed,
          highlighted: surfaceMode == .history
            ? OledPanelGeometry.hottestIndex(summary.cells) : nil,
          aspect: aspect,
          rotation: rotation,
          glowStrength: 0.6,
          reticle: true)
        .overlay {
          if showsWindowGhosts {
            ghostCanvas
              .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
          }
        }
        .overlay {
          // The marked cell explains itself on the map (OCR8): here the tag
          // carries the whole finding, because this page IS the reading
          // instrument. History lens only; the live lens marks nothing.
          if surfaceMode == .history, let relative = summary.hottestRelative,
            let multiple = PanelHealthCopy.multiple(relative)
          {
            OledHotspotTag(
              cells: summary.cells,
              rotation: rotation,
              text: "Hottest area · \(multiple) average")
          }
        }
        .overlay {
          GeometryReader { geometry in
            inspection(
              displayed: displayed, summary: summary, size: geometry.size,
              rotation: rotation)
          }
        }
        PanelExposureLegend()
        if surfaceMode == .now, let live {
          Text(verbatim: "Reading from \(live.at.formatted(date: .omitted, time: .standard)); brightness of what the display was showing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(.quaternary)
          .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(.separator, lineWidth: 1)
          }
          .aspectRatio(aspect, contentMode: .fit)
          .accessibilityHidden(true)
        // `summary.cells` is the accumulated history and is populated whatever
        // the confidence, so blanking the drawing must not also claim there is
        // nothing behind it: a display measured for a month and then switched
        // off still has that month, and this caption sits one button away from
        // "Delete History…". Only `.insufficient` may say nothing was measured,
        // because that state IS a map with fewer than
        // `minimumSamplesForAnalysis` samples in it.
        Text(verbatim: mapPlaceholder(summary, mode: surfaceMode))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Caption under a blank surface, per lens.
  private func mapPlaceholder(_ summary: PanelHealthSummary, mode: SurfaceMode) -> String {
    if mode == .now {
      return "No reading this session yet. One lands within a minute while this display is awake, in use, and Screen Recording is granted."
    }
    if model.isSafeMode {
      return "Paused for this session (Safe Mode). History recorded before it is kept."
    }
    if summary.confidence != .estimated, screenRecordingMissing {
      return "Waiting on Screen Recording; no readings are being taken."
    }
    return summary.confidence == .estimated
      ? "Not shown while measuring is off. The history recorded so far is kept."
      : "Nothing measured to draw yet. Readings are taken once a minute while this display is awake and in use."
  }

  /// Current window rectangles over the surface, the geometry model made
  /// visible. Same layer policy as the exposure model, so what is outlined is
  /// what the estimate counts; below-zero backdrop layers stay out.
  private var ghostCanvas: some View {
    let windows = model.oledCare.latestWindowSnapshots(for: persistenceKey)
    let display = OledCareCoordinator.transform(for: state.display.id)?.displaySize
    // Direct display-local mapping: the surface is drawn in display
    // orientation, so a window rect lands exactly where the eye expects,
    // with no panel transform in between.
    return Canvas { context, size in
      guard let display, display.width > 0, display.height > 0 else { return }
      for window in windows where ExposureModel.includedLayers.contains(window.layer) {
        let bounds = window.bounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
          bounds.width.isFinite, bounds.height.isFinite
        else { continue }
        let clamped = bounds.intersection(CGRect(origin: .zero, size: display))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { continue }
        let rect = CGRect(
          x: clamped.minX / display.width * size.width,
          y: clamped.minY / display.height * size.height,
          width: clamped.width / display.width * size.width,
          height: clamped.height / display.height * size.height
        ).insetBy(dx: 0.5, dy: 0.5)
        context.stroke(
          Path(roundedRect: rect, cornerRadius: 2),
          with: .color(.white.opacity(0.55)), lineWidth: 1)
      }
    }
    .allowsHitTesting(false)
  }

  /// Crosshair and readout under the pointer: the map as an instrument you
  /// can interrogate. History mode reads the accumulated cell against the
  /// map's own mean; Right now reads the live luminance. Both say only what
  /// the displayed array holds.
  @ViewBuilder private func inspection(
    displayed: [Double], summary: PanelHealthSummary, size: CGSize,
    rotation: DisplayRotation
  ) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location): hoverPoint = location
        case .ended: hoverPoint = nil
        }
      }
      .overlay {
        if let point = hoverPoint, size.width > 0, size.height > 0 {
          // Pointer to PANEL cell through the shared transform, so a rotated
          // display's readout describes the cell under the pointer, not the
          // cell at those coordinates in the manufactured frame.
          let mapper = PanelSpaceTransform(
            displaySize: CGSize(width: 1, height: 1), rotation: rotation)
          let panelPoint = mapper.panelPointForDisplay(
            u: point.x / size.width, v: point.y / size.height)
          let col = min(PanelGrid.cols - 1, max(0, Int(panelPoint.p * Double(PanelGrid.cols))))
          let row = min(PanelGrid.rows - 1, max(0, Int(panelPoint.q * Double(PanelGrid.rows))))
          let cell = row * PanelGrid.cols + col
          Canvas { context, canvasSize in
            var lines = Path()
            lines.move(to: CGPoint(x: point.x, y: 0))
            lines.addLine(to: CGPoint(x: point.x, y: canvasSize.height))
            lines.move(to: CGPoint(x: 0, y: point.y))
            lines.addLine(to: CGPoint(x: canvasSize.width, y: point.y))
            context.stroke(lines, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
          }
          .allowsHitTesting(false)
          inspectionReadout(cell: cell, displayed: displayed, summary: summary)
            .position(
              x: min(max(point.x + 70, 70), size.width - 70),
              y: max(point.y - 26, 18))
            .allowsHitTesting(false)
        }
      }
  }

  @ViewBuilder private func inspectionReadout(
    cell: Int, displayed: [Double], summary: PanelHealthSummary
  ) -> some View {
    let lines = inspectionLines(cell: cell, displayed: displayed, summary: summary)
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(lines, id: \.self) { line in
          Text(verbatim: line)
        }
      }
      .font(.caption2.monospaced())
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
    }
  }

  private func inspectionLines(
    cell: Int, displayed: [Double], summary: PanelHealthSummary
  ) -> [String] {
    guard displayed.indices.contains(cell) else { return [] }
    var lines: [String] = []
    switch surfaceMode {
    case .history:
      let mean = displayed.reduce(0, +) / Double(displayed.count)
      if mean > 0, let multiple = PanelHealthCopy.multiple(displayed[cell] / mean) {
        lines.append("\(multiple) average")
      }
    case .now:
      lines.append("\(Int((displayed[cell] * 100).rounded()))% luminance")
    }
    if let owner = summary.dominantOwnerByCell?[cell] {
      lines.append(owner)
    }
    return lines
  }

  /// The shared tie-break (`OledPanelGeometry.hottestIndex`), one answer for
  /// this page and the display page's hero.
  private static func hottestIndex(_ cells: [Double]) -> Int? {
    OledPanelGeometry.hottestIndex(cells)
  }

  // MARK: - Findings

  @ViewBuilder private func findings(_ summary: PanelHealthSummary) -> some View {
    if summary.confidence == .measured, let relative = summary.hottestRelative,
      let multiple = Self.multiplePhrase(relative)
    {
      VStack(alignment: .leading, spacing: 10) {
        Text("The hottest area")
          .font(.subheadline.weight(.semibold))

        // The one number this whole feature is allowed to state: a measured
        // ratio of a panel against itself. It is not a lifespan, a date or a
        // score, and it must never grow into one.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: multiple)
            .font(.title2.weight(.semibold))
            .monospacedDigit()
          Text("this display's average")
            .foregroundStyle(.secondary)
        }

        if let region = Self.hottestIndex(summary.cells).map(Self.regionPhrase) {
          SettingsCaption(verbatim: "Marked on the map, \(region).")
        }

        // Past tense, deliberately. The snapshot behind this is up to a minute
        // old, so "right now" is a claim the data cannot support even though
        // the summary withholds the owner entirely once observation is off.
        if let owner = summary.hottestOwner {
          SettingsCaption(
            verbatim: "\(owner) was on that part of the display at the last reading.")
        }
      }
    }
  }

  // MARK: - Attribution

  /// Rendered from whatever the summary carries, with an explicit empty case:
  /// the producer for this series is wired separately from the view, so the
  /// section must assume neither that it is populated nor that it is not.
  ///
  /// **Not labelled by `confidence`.** That describes the luminance telemetry
  /// only; these hours come from window observation, which is a separate pref
  /// and needs no permission, so they are measured whether or not brightness
  /// is. Calling them an estimate here would be as wrong as calling them
  /// measured on the other side.
  @ViewBuilder private func ownersCard(_ summary: PanelHealthSummary) -> some View {
    let owners = summary.topOwnersByHours
    VStack(alignment: .leading, spacing: 10) {
      Text("Display time by app")
        .font(.subheadline.weight(.semibold))

      if owners.isEmpty {
        Text("No data yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        // Index-keyed: the elements are tuples, which cannot be `Identifiable`,
        // and an owner name is not guaranteed unique across the list.
        // The bar is proportional to the LIST's own leader, so the top row is
        // always full and the rest read against it; an absolute scale would
        // need a total this list deliberately truncates.
        let leader = owners.map(\.hours).max() ?? 0
        ForEach(Array(owners.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(verbatim: entry.owner)
              Spacer(minLength: 0)
              Text(verbatim: Self.panelTimePhrase(entry.hours))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            GeometryReader { geometry in
              Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                  if leader > 0 {
                    Capsule()
                      .fill(
                        LinearGradient(
                          colors: [
                            PanelExposureScale.color(0.35), PanelExposureScale.color(0.9),
                          ],
                          startPoint: .leading, endPoint: .trailing))
                      .frame(width: geometry.size.width * entry.hours / leader)
                  }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
          }
        }
      }

      // The figure is display-time, NOT how long the app was open: an app
      // filling the display books an hour per hour, one covering a quarter
      // books fifteen minutes. Saying "Ghostty was open for 3 hours" would be a
      // claim this does not measure, so the caption states the weighting
      // outright.
      SettingsCaption(
        "Weighted by how much of the display each app's windows covered, so this is not how long the app was open. Read from window positions and owner names only (never window titles, and never their contents), and only while the display is awake and undimmed."
      )
    }
  }

  // MARK: - Formatting

  // These three used to live here as private statics, untestable because the
  // app target has no test target, and the pane had independently grown a
  // DIFFERENT formatter for the same quantity. They are `PanelHealthCopy` in
  // CandelaKit now, tested there, and these are the thin adapters that keep
  // each call site's own vocabulary.

  private static func multiplePhrase(_ relative: Double) -> String? {
    PanelHealthCopy.multiple(relative)
  }

  /// "none yet" rather than the shared default "0 hours": a leaderboard row for
  /// an app with no time is a row that should not have appeared, whereas the
  /// pane's lifetime counter is a number that legitimately reads zero.
  private static func panelTimePhrase(_ hours: Double) -> String {
    PanelHealthCopy.hours(hours, zeroPhrase: "none yet")
  }

  private static func regionPhrase(_ index: Int) -> String {
    PanelHealthCopy.region(cell: index) ?? ""
  }
}

// MARK: - Banner

/// Symbol AND text, never state by colour alone: the same rule the OLED Care
/// pane's Safe Mode note follows, and the reason an inactive window (which
/// draws every accent in grey) cannot make this unreadable.
private struct PanelHealthBanner: View {
  let symbol: String
  let title: Text
  let message: Text

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        title.font(.subheadline.weight(.semibold))
        message
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - The map itself

/// The stored grid, drawn at the shape of the display it came from.
///
/// Always `PanelGrid.cols` × `PanelGrid.rows` in PANEL-NATIVE order regardless
/// of how the display is rotated: `PanelSpaceTransform` re-bins every sample
/// into that orientation before it is accumulated, so this view never rotates
/// anything and must not start.
struct PanelExposureMap: View {
  let cells: [Double]
  let highlighted: Int?
  /// Draw the grid empty. A blank grid is the honest picture of "measured
  /// nothing"; drawing near-zero values instead produces a faint pattern that
  /// reads as data.
  let blank: Bool
  /// Panel-native width / height of the display this history belongs to. Nil
  /// falls back to the grid's own 24:10, which is only correct where the
  /// subject IS the grid rather than a display (`PanelGridMark`). The grid is
  /// deliberately one fixed shape for every panel, so its cells are square on
  /// the MAG and 35% taller than wide on the Dell; drawing every display at
  /// 24:10 would show the Dell's history stretched sideways.
  var aspect: CGFloat?

  var body: some View {
    Canvas { context, size in
      let cellWidth = size.width / CGFloat(PanelGrid.cols)
      let cellHeight = size.height / CGFloat(PanelGrid.rows)
      for row in 0..<PanelGrid.rows {
        for col in 0..<PanelGrid.cols {
          let index = row * PanelGrid.cols + col
          let rect = CGRect(
            x: CGFloat(col) * cellWidth, y: CGFloat(row) * cellHeight,
            width: cellWidth, height: cellHeight
          ).insetBy(dx: 0.75, dy: 0.75)
          let path = Path(roundedRect: rect, cornerRadius: 2)
          context.fill(path, with: .color(Color.primary.opacity(0.07)))
          if !blank, cells.indices.contains(index), cells[index] > 0 {
            context.fill(path, with: .color(PanelExposureScale.color(cells[index])))
          }
          if index == highlighted {
            context.stroke(
              Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
              with: .color(.primary), lineWidth: 1.5)
          }
        }
      }
    }
    .aspectRatio(aspect ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows), contentMode: .fit)
    .frame(maxWidth: .infinity)
    .accessibilityElement()
    .accessibilityLabel(
      Text(
        verbatim:
          "Exposure map, \(PanelGrid.cols) by \(PanelGrid.rows) cells, drawn with the display's long edge across"
      ))
  }
}

/// The ramp's key, since a heat map with no key is a picture rather than a
/// reading. Deliberately "less/more" and not a unit: the scale is each cell
/// against this panel's own peak, which has no absolute meaning.
struct PanelExposureLegend: View {
  var body: some View {
    HStack(spacing: 8) {
      Text("Less lit")
      LinearGradient(
        colors: stride(from: 0.0, through: 1.0, by: 0.1).map(PanelExposureScale.color),
        startPoint: .leading, endPoint: .trailing
      )
      .frame(height: 6)
      .clipShape(RoundedRectangle(cornerRadius: 3))
      Text("More lit")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

/// A sequential ramp with fixed sRGB anchors rather than semantic colours.
///
/// Fixed on purpose: this is quantitative encoding, and a ramp that changed
/// between light and dark appearance would make the same panel history look
/// like two different measurements. The anchors keep a monotonic lightness
/// climb so the ordering survives being read in greyscale.
enum PanelExposureScale {
  private static let anchors: [(r: Double, g: Double, b: Double)] = [
    (0.13, 0.15, 0.32),
    (0.47, 0.18, 0.44),
    (0.83, 0.33, 0.27),
    (0.98, 0.75, 0.24),
  ]

  static func color(_ value: Double) -> Color {
    let (red, green, blue) = components(value)
    return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
  }

  /// The raw sRGB triple, for the surface rendering that rasterizes the ramp
  /// itself rather than asking SwiftUI to.
  static func components(_ value: Double) -> (r: Double, g: Double, b: Double) {
    let clamped = min(1, max(0, value.isFinite ? value : 0))
    let scaled = clamped * Double(anchors.count - 1)
    let lower = min(anchors.count - 2, Int(scaled))
    let t = scaled - Double(lower)
    let a = anchors[lower]
    let b = anchors[lower + 1]
    return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
  }
}

/// The grid at glyph size, so the telemetry toggle's "at about the resolution
/// of this grid" has a grid to point at. Same dimensions as the real map: the
/// sentence is a claim about resolution, so a decorative stand-in with a
/// different cell count would make it false.
///
/// Drawn at the grid's own 24:10 and NOT at any display's aspect, because here
/// the subject really is the stored grid.
struct PanelGridMark: View {
  var body: some View {
    PanelExposureMap(cells: [], highlighted: nil, blank: true, aspect: nil)
      .frame(width: 96)
      .accessibilityHidden(true)
  }
}
