import CandelaKit
import CoreGraphics
import SwiftUI

/// One panel's accumulated exposure, in its own content-sized window: a pushed
/// page cannot resize the settings window to a portrait display's map, and a
/// content-sized window can. It owns the map
/// instruments, the History / Right now lens, the window outlines and the
/// crosshair readout, so the app has ONE surface for interrogating the map.
///
/// Instruments only. The cards that state findings in words live on the
/// display's OLED Care page; do not draw a finding here again without moving its
/// card back, because two surfaces stating one measurement is how they come to
/// disagree.
///
/// Copy rule: software has two levers against OLED wear, reduce luminance
/// and reduce time at luminance. Nothing here may translate a measurement into a
/// lifespan, a date, a percentage of damage avoided or a score. Relative
/// exposure is measured and therefore sayable; nothing else is.
///
/// The three `PanelHealthSummary.Confidence` states are three genuinely
/// different pages, not one page with a badge:
/// - `.insufficient` shows NO figures at all: under
///   `minimumSamplesForAnalysis` readings there is nothing to be right about.
/// - `.estimated` means measuring is off, so every figure is labelled an
///   estimate.
/// - `.measured` is the only state that shows a multiple of the panel mean.
///
/// `confidence` does not answer "is anything being recorded right now." It is a
/// pure function of the telemetry pref and the stored sample count, so it stays
/// `.measured` through a revoked Screen Recording grant and through a Safe Mode
/// session where the driver loop never starts. Both are checked here ahead of
/// the switch, and both turn the page from a reading into a record.
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

  /// In `SurfaceMode`'s own order, so the segments and the binding below cannot
  /// disagree about which lens index 0 is.
  private static let lensNames = ["History", "Right now"]

  /// `ThemedSegments` chooses by index; the surface reasons in lenses. An
  /// out-of-range write lands on the history lens rather than on nothing.
  private var lensSelection: Binding<Int> {
    Binding(
      get: { surfaceMode == .now ? 1 : 0 },
      set: { surfaceMode = $0 == 1 ? .now : .history })
  }

  private var persistenceKey: String { state.display.persistenceKey }
  /// Used only to ask macOS about the panel's current geometry. Never persisted
  /// and never a key: IDs reassign across a replug. `DisplayHealthWindowRoot`
  /// resolves the key against the connected set each render, so this view only
  /// ever renders for a connected display.
  private var displayID: CGDirectDisplayID? { state.display.id }

  private var displayName: String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  /// The coordinator's single door. Non-mutating by contract: it is called from
  /// a `body`, and it deliberately does not memoize the map it may load, because
  /// populating an observation-tracked dictionary during view update is a
  /// mutation SwiftUI would report.
  private var summary: PanelHealthSummary {
    model.oledCare.healthSummary(for: persistenceKey)
  }

  /// Preflight only, never `CGRequestScreenCaptureAccess`: the prompting calls
  /// are the telemetry toggle and the guided setup flow.
  ///
  /// Re-read on every render, because the grant does come and go under a running
  /// app: an ad-hoc re-sign of a deployed build can drop it, and so can a
  /// revocation in System Settings.
  private var screenRecordingMissing: Bool {
    !CGPreflightScreenCaptureAccess()
  }

  /// This display's lighting, by its position among the connected externals: the
  /// sidebar's own rule, so this window and the page it was opened from are lit
  /// alike.
  private var accent: SettingsAccent {
    guard
      let index = model.displays.firstIndex(where: {
        $0.display.persistenceKey == persistenceKey
      })
    else { return .neutral }
    return .display(isBuiltIn: false, ordinal: index)
  }

  var body: some View {
    let summary = self.summary
    VStack(alignment: .leading, spacing: 20) {
      switcherRow
      confidenceNote(summary)
      mapSection(summary)
      deleteRow
    }
    .padding(20)
    // Content-sized window: this column's width and the sections'
    // heights decide the window's size, with the map capped below so a portrait
    // display cannot run it off the screen. Deliberately NO ScrollView: a
    // flexible scroll container reports no ideal height and collapses a
    // `.contentSize` window. The title bar is the page title, so the switcher
    // stands alone rather than under a second one.
    .frame(width: 560, alignment: .leading)
    // A BACKGROUND and never a container: a background is laid out against the
    // content it sits behind, so the canvas cannot reach the fitting size the
    // window is built from. A `ZStack` would, collapsing the window to the
    // canvas's own ideal size.
    .background { SettingsCanvas(accent: accent.accent, secondary: accent.secondary) }
    // Published for the whole page, so every card, kicker and button reads this
    // display's lighting.
    .environment(\.settingsAccent, accent)
    .confirmationDialog(
      "Delete this display's measurement history?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        // The coordinator's one-step clear: memory, disk and the window
        // attribution derived from it, under its epoch guard so a capture in
        // flight cannot re-book into what was just deleted. Never re-implement.
        model.oledCare.clearExposureHistory(for: persistenceKey)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        verbatim:
          "The accumulated brightness map for \(displayName), and the per-app display time derived from the same observations, are removed from this Mac. Two other counts are kept and are not affected: this display's total hours of use, and its record of time spent at each brightness."
      )
    }
  }

  // MARK: - Chrome

  /// `SubPageHeader`'s switcher half without its title half: the window's title
  /// bar already says Heat Map. Same callback contract: a persistence key
  /// out, navigation meaning owned by the caller.
  @ViewBuilder private var switcherRow: some View {
    if displays.count > 1 {
      HStack {
        Spacer()
        Picker("Display", selection: Binding(get: { persistenceKey }, set: { onSwitch($0) })) {
          ForEach(displays, id: \.key) { display in
            // A display's name, never a lookup key.
            Text(verbatim: display.name).tag(display.key)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Display")
      }
    }
  }

  private var deleteRow: some View {
    Button("Delete History…", role: .destructive) { confirmingDelete = true }
      // Warning red, never the display's accent, which everywhere else in this
      // window means "this is on".
      .buttonStyle(SettingsDangerButtonStyle())
      .accessibilityLabel("Delete History…")
  }

  // MARK: - Confidence

  /// The one place the states are told apart, so the honesty rule is checkable
  /// in one screen rather than by tracing `if`s through the layout.
  ///
  /// Order matters. Safe Mode and a missing grant both stop readings dead while
  /// `confidence` carries on reporting the stored sample count, so each is tested
  /// BEFORE the switch. Otherwise the "Measured" banner claims a reading a minute
  /// in a session that has taken none.
  @ViewBuilder private func confidenceNote(_ summary: PanelHealthSummary) -> some View {
    if model.isSafeMode {
      // `OledCareCoordinator.start` returns before it builds the driver loop in
      // a safe-mode session, so nothing here has a live producer behind it.
      PanelHealthBanner(
        symbol: "pause.circle",
        title: Text("Paused for this session (Safe Mode)"),
        message: Text(
          "Shift was held at launch, so no new readings are being taken and no hours are accumulating. Everything shown here was recorded before this session."
        ))
    } else if summary.confidence != .estimated, screenRecordingMissing {
      // Telemetry on, macOS not letting us capture. Two arrivals: a display
      // that never had the grant, and one measured for weeks whose grant went
      // away. The difference is whether the page has history to stand on.
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
          // The second sentence names a producer, so it checks the producer is
          // running: window observation is its own pref, and with both off the
          // page claimed window geometry over a list reading "No data yet".
          message: summary.observationEnabled
            ? Text(
              "Measuring is off for this display, so nothing here comes from the screen itself. What is left is window geometry: which app held which part of the display, and for how long. Turn on \"Measure how bright each part of this display is\" on the Health pane to record what the display is actually showing."
            )
            : Text(
              "Measuring is off for this display and so is app attribution, so nothing new is being recorded at all. Anything below was recorded earlier. Turn on \"Measure how bright each part of this display is\" and \"Note which apps are on this display\" on the Health pane to start recording again."
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

  /// The map as an instrument, drawn the way the monitor hangs on the
  /// desk (`PanelExposureSurface` re-orders a rotated display's history for
  /// presentation; storage stays panel-native).
  ///
  /// The one section with no card under it: a card would frame the instrument as
  /// one fact among several and squeeze its measured width by the card's
  /// padding.
  @ViewBuilder private func mapSection(_ summary: PanelHealthSummary) -> some View {
    let live = model.oledCare.latestSample(for: persistenceKey)
    let historyBlank = summary.confidence != .measured
    let aspect =
      OledPanelGeometry.displayAspect(for: displayID)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    let mapSize = Self.mapSize(aspect: aspect)
    let rotation = OledPanelGeometry.rotation(for: displayID)
    // One truth shared by every sub-layer (surface, ghosts, crosshair readout),
    // so the inspection can never describe a frame the surface is not drawing.
    let displayed: [Double]? =
      surfaceMode == .history ? (historyBlank ? nil : summary.cells) : live?.cells

    VStack(alignment: .leading, spacing: 10) {
      // A hero heading, not a card kicker: it titles the picture rather than a
      // group of rows.
      Text("Where this display has been lit")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(SettingsTheme.titleColor)
        // The kicker's own inset, so this heading and the card kickers below
        // share a left edge.
        .padding(.leading, 4)
        .settingsHeading()

      HStack(spacing: 12) {
        // The window's segments rather than the native control, whose selected
        // segment fills with the SYSTEM accent.
        ThemedSegments(options: Self.lensNames, selection: lensSelection)
          // A container element, because the segments themselves are the
          // buttons: each keeps its own name and its selected trait.
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Map shows")
        // The window's switch rather than a bordered toggle button, which fills
        // with the SYSTEM accent when on.
        Toggle("Windows", isOn: $showsWindowGhosts)
          .themedSwitch(spreads: false)
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
          // The tag carries the whole finding here, because this page IS
          // the reading instrument. History lens only; the live lens marks
          // nothing.
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
        // An EXPLICIT frame, not an aspect box: under this window's
        // `preferredContentSize` hosting, a flexible frame plus `aspectRatio`
        // reports no ideal height and collapses to nothing [MEASURED 2026-08-17:
        // the window rendered every section except the map]. It sits OUTSIDE the
        // overlays so the crosshair's GeometryReader and the hotspot tag keep
        // describing exactly the drawn map.
        .frame(width: mapSize.width, height: mapSize.height)
        .frame(maxWidth: .infinity)
        // Per lens, because the scales are different: history is normalized to
        // this panel's own peak, the live lens is absolute luminance.
        if surfaceMode == .now {
          PanelExposureLegend(low: "Darker", high: "Brighter")
        } else {
          PanelExposureLegend()
        }
        if surfaceMode == .now, let live {
          Text(verbatim: "Reading from \(live.at.formatted(date: .omitted, time: .standard)); brightness of what the display was showing.")
            .font(.caption)
            .foregroundStyle(SettingsTheme.faintColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        // A recessed well, the OLED Care hero's: on this canvas a filled tile
        // reads as a broken picture rather than as a pending one.
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.black.opacity(0.22))
          .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(SettingsTheme.cardStroke, lineWidth: 1)
          }
          // Same explicit frame as the drawn map: the blank state collapses
          // under `preferredContentSize` hosting exactly the same way.
          .frame(width: mapSize.width, height: mapSize.height)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)
        // `summary.cells` is populated whatever the confidence, so blanking the
        // drawing must not also claim there is nothing behind it: a display
        // measured for a month and then switched off still has that month. Only
        // `.insufficient` may say nothing was measured, because that state IS a
        // map under `minimumSamplesForAnalysis` samples.
        SettingsCaption(verbatim: mapPlaceholder(summary, mode: surfaceMode))
      }
    }
  }

  /// The map's concrete size: one formula for both orientations, the
  /// height cap winning wherever it produces the narrower map. Explicit on
  /// purpose, because `preferredContentSize` hosting collapses flexible frames.
  private static func mapSize(aspect: CGFloat) -> CGSize {
    let width = min(520, 470 * max(aspect, 0.01))
    return CGSize(width: width, height: width / max(aspect, 0.01))
  }

  /// Caption under a blank surface, per lens.
  ///
  /// Same order as `confidenceNote`, and for the same reason: Safe Mode, a
  /// missing grant and measuring-off each stop readings dead, so the live
  /// lens's "one lands within a minute" is only true below all three. Above
  /// them it promised a reading that could never arrive while the banner over
  /// the map said the opposite.
  private func mapPlaceholder(_ summary: PanelHealthSummary, mode: SurfaceMode) -> String {
    if model.isSafeMode {
      return "Paused for this session (Safe Mode). History recorded before it is kept."
    }
    if summary.confidence != .estimated, screenRecordingMissing {
      return "Waiting on Screen Recording; no readings are being taken."
    }
    if summary.confidence == .estimated {
      // The kept-history half belongs to the lenses that draw history. The live
      // lens draws the last minute, and a reassurance about a record it does not
      // show reads as an answer to a question nobody asked.
      return mode == .now
        ? "Not shown while measuring is off."
        : "Not shown while measuring is off. The history recorded so far is kept."
    }
    if mode == .now {
      return "No reading this session yet. One lands within a minute while this display is awake and in use."
    }
    return "Nothing measured to draw yet. Readings are taken once a minute while this display is awake and in use."
  }

  /// Current window rectangles over the surface. Same layer policy as the
  /// exposure model, so what is outlined is what the estimate counts.
  private var ghostCanvas: some View {
    let windows = model.oledCare.latestWindowSnapshots(for: persistenceKey)
    let display = OledCareCoordinator.transform(for: state.display.id)?.displaySize
    // Direct display-local mapping: the surface is drawn in display
    // orientation, so a window rect needs no panel transform in between.
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

  /// Crosshair and readout under the pointer. History reads the accumulated cell
  /// against the map's own mean, Right now reads the live luminance, and both
  /// say only what the displayed array holds.
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
          // display's readout describes the cell under the pointer, not the one
          // at those coordinates in the manufactured frame.
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

}

// MARK: - Window root

/// The Heat Map window's root: resolves its persistence key against
/// the connected externals, keeps the switcher's list fresh, and closes the
/// window when its display departs. Hosted by `DisplayHealthWindowPresenter` (an
/// AppKit island; a `WindowGroup` measurably changed plain-launch behavior),
/// which supplies both closures: `close` closes THIS window, and `rekey` tells
/// the presenter the switcher repointed it, so the comparison workflow
/// stays one window deep.
@MainActor
struct DisplayHealthWindowRoot: View {
  let initialKey: String
  let close: () -> Void
  let rekey: (_ from: String, _ to: String) -> Void

  /// The display THIS window shows; the switcher moves it (through `rekey`,
  /// so the presenter's bookkeeping follows).
  @State private var currentKey: String?

  @Environment(AppModel.self) private var model

  var body: some View {
    // Rename dependency: names come from `friendlyName`, and `DisplayPrefs` has
    // no observation of its own.
    let _ = model.prefsRevision
    let key = currentKey ?? initialKey
    Group {
      if let state = model.displays.first(where: { $0.display.persistenceKey == key }) {
        PanelHealthView(
          state: state,
          displays: switcherDisplays,
          onSwitch: { newKey in
            rekey(key, newKey)
            currentKey = newKey
          }
        )
        // A display switch resets page state: the lens and ghost toggles
        // describe one display's map, not a session.
        .id(key)
      } else {
        // One frame of a departed display's window before `close` lands, never
        // a blank white sheet. Neutral lighting: the display whose hue this
        // window carried is the one that just left.
        Text("This display is not connected.")
          .foregroundStyle(SettingsTheme.bodyColor)
          .padding(40)
          .background {
            SettingsCanvas(
              accent: SettingsAccent.neutral.accent,
              secondary: SettingsAccent.neutral.secondary)
          }
      }
    }
    // Dark-only, belt to the window's own `darkAqua`: every colour here
    // comes from the theme layer and none has a light answer.
    .preferredColorScheme(.dark)
    .onChange(of: model.displays.map(\.display.persistenceKey), initial: true) { _, connected in
      if !connected.contains(key) {
        close()
      }
    }
  }

  /// Externals only, like the pane's own switcher: OLED care never covers the
  /// built-in display.
  private var switcherDisplays: [(key: String, name: String)] {
    model.displays.map { state in
      (key: state.display.persistenceKey,
       name: DisplayOrdering.title(
         friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
         hardwareName: state.display.name))
    }
  }
}

// MARK: - Banner

/// Symbol AND text, never state by colour alone, which is also why an inactive
/// window (drawing every accent grey) cannot make this unreadable.
private struct PanelHealthBanner: View {
  let symbol: String
  let title: Text
  let message: Text

  var body: some View {
    SettingsCard {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(SettingsTheme.bodyColor)
        VStack(alignment: .leading, spacing: 4) {
          title
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SettingsTheme.titleColor)
          message
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - The map itself

/// The stored grid, drawn at the shape of the display it came from.
///
/// Always `PanelGrid.cols` by `PanelGrid.rows` in PANEL-NATIVE order whatever
/// the rotation: `PanelSpaceTransform` re-bins every sample into that
/// orientation before it is accumulated, so this view never rotates anything and
/// must not start.
struct PanelExposureMap: View {
  let cells: [Double]
  let highlighted: Int?
  /// Draw the grid empty. A blank grid is the honest picture of "measured
  /// nothing"; near-zero values draw a faint pattern that reads as data.
  let blank: Bool
  /// Panel-native width / height of the display this history belongs to. Nil
  /// falls back to the grid's own ratio, which is only correct where the subject
  /// IS the grid rather than a display (`PanelGridMark`). The grid is one fixed
  /// shape for every panel, so drawing every display at it stretches any history
  /// from a panel of another shape.
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
          // Fixed white rather than `Color.primary`, the ramp's own reason:
          // every surface that draws this grid is dark by construction, and a
          // cell answering the system appearance would make one panel's history
          // two different pictures.
          context.fill(path, with: .color(Color.white.opacity(0.07)))
          if !blank, cells.indices.contains(index), cells[index] > 0 {
            context.fill(path, with: .color(PanelExposureScale.color(cells[index])))
          }
          if index == highlighted {
            context.stroke(
              Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
              with: .color(.white), lineWidth: 1.5)
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
/// reading. Never a unit: neither scale has an absolute meaning to put on it.
///
/// The ends are callers' words because the two lenses do not share a scale.
/// History is each cell against the panel's own peak, accumulated; the live
/// lens is the raw linear luminance of one frame. One legend speaking for both
/// described whichever it was not drawn under.
struct PanelExposureLegend: View {
  var low: String = "Less lit"
  var high: String = "More lit"

  var body: some View {
    HStack(spacing: 8) {
      Text(verbatim: low)
      LinearGradient(
        colors: stride(from: 0.0, through: 1.0, by: 0.1).map(PanelExposureScale.color),
        startPoint: .leading, endPoint: .trailing
      )
      .frame(height: 6)
      .clipShape(RoundedRectangle(cornerRadius: 3))
      Text(verbatim: high)
    }
    .font(.caption)
    .foregroundStyle(SettingsTheme.faintColor)
  }
}

/// A sequential ramp with fixed sRGB anchors rather than semantic colours: this
/// is quantitative encoding, and a ramp that changed between light and dark
/// appearance would make one panel's history look like two measurements. The
/// anchors climb monotonically in lightness, so the ordering survives greyscale.
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

/// The grid at glyph size, so the telemetry toggle's "at about the resolution of
/// this grid" has a grid to point at. Same dimensions as the real map, because
/// the sentence is a claim about resolution and a stand-in with a different cell
/// count would make it false. Drawn at the grid's own ratio, not any display's:
/// here the subject really is the stored grid.
struct PanelGridMark: View {
  var body: some View {
    PanelExposureMap(cells: [], highlighted: nil, blank: true, aspect: nil)
      .frame(width: 96)
      .accessibilityHidden(true)
  }
}
