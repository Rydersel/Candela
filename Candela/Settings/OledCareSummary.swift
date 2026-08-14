import CandelaKit
import CoreGraphics
import SwiftUI

/// Shared geometry for every surface that draws a display's exposure history.
enum OledPanelGeometry {
  /// The map's drawn aspect, panel-native (the manufactured landscape
  /// rectangle), because that is the geometry the cells were binned in. Not
  /// the grid's own 24:10: that ratio is one panel's, and drawing another
  /// display's history at it stretches the picture. Nil when the geometry
  /// cannot be read or the rotation is not a right angle; callers fall back
  /// to the grid's ratio rather than guessing.
  static func panelNativeAspect(for displayID: CGDirectDisplayID?) -> CGFloat? {
    guard let displayID else { return nil }
    let width = CGFloat(CGDisplayPixelsWide(displayID))
    let height = CGFloat(CGDisplayPixelsHigh(displayID))
    guard width > 0, height > 0,
      let rotation = DisplayRotation(degrees: CGDisplayRotation(displayID))
    else { return nil }
    return rotation.swapsAxes ? height / width : width / height
  }

  /// The peak cell of a normalized map, ties to the first index, the same
  /// answer `ExposureMap.hottestCell` gives.
  static func hottestIndex(_ cells: [Double]) -> Int? {
    guard let peak = cells.max(), peak > 0 else { return nil }
    return cells.firstIndex(of: peak)
  }

  /// The display's CURRENT logical aspect, rotation included, for surfaces
  /// that draw the map the way the glass hangs on the desk. Storage stays
  /// panel-native; this is presentation only.
  static func displayAspect(for displayID: CGDirectDisplayID?) -> CGFloat? {
    guard let displayID else { return nil }
    let width = CGFloat(CGDisplayPixelsWide(displayID))
    let height = CGFloat(CGDisplayPixelsHigh(displayID))
    guard width > 0, height > 0 else { return nil }
    return width / height
  }

  static func rotation(for displayID: CGDirectDisplayID?) -> DisplayRotation {
    guard let displayID else { return .standard }
    return DisplayRotation(degrees: CGDisplayRotation(displayID)) ?? .standard
  }

  /// The stored panel-native grid re-ordered into DISPLAY orientation, with
  /// both index maps, so a rotated monitor's surface shows what the desk
  /// shows while every data lookup stays in the panel-native store. The
  /// mapping goes through `PanelSpaceTransform`'s own point function; a
  /// right-angle rotation maps cell centers to cell centers exactly, so this
  /// is a re-ordering, never a resample.
  static func displayOriented(
    _ cells: [Double], rotation: DisplayRotation
  ) -> (cells: [Double], cols: Int, rows: Int, panelFromDisplay: [Int]) {
    let cols = rotation.swapsAxes ? PanelGrid.rows : PanelGrid.cols
    let rows = rotation.swapsAxes ? PanelGrid.cols : PanelGrid.rows
    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: 1, height: 1), rotation: rotation)
    var oriented = [Double](repeating: 0, count: cells.count)
    var panelFromDisplay = [Int](repeating: 0, count: cells.count)
    for row in 0..<rows {
      for col in 0..<cols {
        let point = transform.panelPointForDisplay(
          u: (Double(col) + 0.5) / Double(cols), v: (Double(row) + 0.5) / Double(rows))
        let panelCol = min(PanelGrid.cols - 1, max(0, Int(point.p * Double(PanelGrid.cols))))
        let panelRow = min(PanelGrid.rows - 1, max(0, Int(point.q * Double(PanelGrid.rows))))
        let panelIndex = panelRow * PanelGrid.cols + panelCol
        let displayIndex = row * cols + col
        panelFromDisplay[displayIndex] = panelIndex
        if cells.indices.contains(panelIndex) { oriented[displayIndex] = cells[panelIndex] }
      }
    }
    return (oriented, cols, rows, panelFromDisplay)
  }
}

/// The glance rendering of an exposure map: the stored 24 by 10 grid as a
/// tiny image, magnified with interpolation so it reads as one continuous
/// heat surface filling the display's shape.
///
/// Deliberately not the health sheet's discrete cell grid. That grid is the
/// reading instrument, honest about the storage resolution; at glance size
/// its inset cells read as floating squares and a non-ultrawide panel's
/// taller cells read as stretched. The hottest cell keeps its outline here so
/// the words beside the hero still point at something.
struct PanelExposureSurface: View {
  /// Panel-native, always; the surface re-orders for presentation itself.
  let cells: [Double]
  /// Panel-native index; remapped internally.
  let highlighted: Int?
  /// The DISPLAY's current aspect, so a portrait-mounted monitor draws tall.
  let aspect: CGFloat
  /// How the glass hangs. Presentation only: storage never rotates.
  var rotation: DisplayRotation = .standard
  /// 0 disables the emission glow; the strip runs it low, the hero higher.
  /// The glow is the same rasterized data blurred, so it can only bloom where
  /// the panel has actually been lit.
  var glowStrength: Double = 0
  /// Draw fine corner ticks, the hero's instrument framing.
  var reticle: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let oriented = OledPanelGeometry.displayOriented(cells, rotation: rotation)
    let image = Self.rasterize(oriented.cells, cols: oriented.cols, rows: oriented.rows)
    let highlightedDisplayIndex = highlighted.flatMap { panelIndex in
      oriented.panelFromDisplay.firstIndex(of: panelIndex)
    }
    ZStack {
      if glowStrength > 0, let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .aspectRatio(aspect, contentMode: .fit)
          .blur(radius: 18)
          .opacity(glowStrength)
          .blendMode(.screen)
      }
      Group {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        if let index = highlightedDisplayIndex {
          Canvas { context, size in
            let width = size.width / CGFloat(oriented.cols)
            let height = size.height / CGFloat(oriented.rows)
            let rect = CGRect(
              x: CGFloat(index % oriented.cols) * width,
              y: CGFloat(index / oriented.cols) * height,
              width: width, height: height
            ).insetBy(dx: 0.75, dy: 0.75)
            context.stroke(
              Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary), lineWidth: 1.5)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(.separator, lineWidth: 1)
      }
      .overlay {
        if reticle { ReticleTicks() }
      }
    }
    // The id swap makes a data change an insertion the transition can
    // crossfade; without it a replaced CGImage snaps. Reduce Motion snaps on
    // purpose.
    .id(reduceMotion ? 0 : cells.hashValue)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: cells.hashValue)
    .accessibilityHidden(true)
  }

  /// One pixel per stored cell, colored through the shared ramp. Row 0 of a
  /// `CGImage` is the top row, the same top-left convention the cells are
  /// stored in, so no flip.
  private static func rasterize(_ cells: [Double], cols: Int, rows: Int) -> CGImage? {
    guard cells.count == cols * rows else { return nil }
    var pixels = [UInt8](repeating: 255, count: cols * rows * 4)
    for index in cells.indices {
      let (r, g, b) = PanelExposureScale.components(cells[index])
      let offset = index * 4
      pixels[offset] = UInt8(max(0, min(255, (r * 255).rounded())))
      pixels[offset + 1] = UInt8(max(0, min(255, (g * 255).rounded())))
      pixels[offset + 2] = UInt8(max(0, min(255, (b * 255).rounded())))
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: cols, height: rows, bitsPerComponent: 8,
          bytesPerRow: cols * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return nil }
      return context.makeImage()
    }
  }
}

/// The pane's opening image: every enrolled display as a tile at its
/// panel-native shape, filled with its measured exposure map where one exists.
///
/// Enrolled only: this pane is about the displays in OLED care, and a strip
/// of "Not enrolled" placeholders would be a list of things the page is not
/// about. The tile earns its place the way the display hero's does: it
/// carries the display's real manufactured shape and its real history, and
/// clicking it jumps to that display's section. Every fact it draws is stated
/// in words directly under it, so the tile itself stays decorative to
/// VoiceOver.
@MainActor
struct OledCareGlanceStrip: View {
  let displays: [AppModel.DisplayState]
  let jump: (String) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      ForEach(displays, id: \.display.persistenceKey) { state in
        OledCareGlanceTile(state: state, jump: jump)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// One display in the strip: shape, map, name, and a one-line state.
///
/// The state line follows the health view's honesty precedence exactly (its
/// `confidenceNote` is the reference): Safe Mode first, then a missing Screen
/// Recording grant, then the confidence states. The map is drawn only when the
/// stored history is `.measured`; every other state gets the blank grid, never
/// a stale or estimated picture presented as one (OC11).
@MainActor
struct OledCareGlanceTile: View {
  let state: AppModel.DisplayState
  let jump: (String) -> Void

  @Environment(AppModel.self) private var model

  /// The display hero's fit rule at strip scale: the box the tile fits
  /// inside, preserving aspect, so an ultrawide and a portrait-mounted panel
  /// take the same vertical room.
  @ScaledMetric(relativeTo: .subheadline) private var boxWidth: CGFloat = 190
  @ScaledMetric(relativeTo: .subheadline) private var boxHeight: CGFloat = 84

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  private var name: String {
    DisplayOrdering.title(friendlyName: prefs.friendlyName, hardwareName: state.display.name)
  }

  var body: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let showsMap = summary.confidence == .measured
    Button {
      jump(persistenceKey)
    } label: {
      VStack(spacing: 6) {
        tile(summary: summary, showsMap: showsMap)
        Text(verbatim: name)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: stateLine(summary: summary))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: boxWidth * 1.25)
      .contentShape(Rectangle())
    }
    .buttonStyle(OledTileButtonStyle())
    // Lift, not tint: an inactive window draws every accent grey, so a hover
    // treatment that only recolored would vanish exactly when screenshots are
    // taken. Scale and shadow survive focus.
    .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
    .shadow(
      color: .black.opacity(hovering ? 0.35 : 0),
      radius: hovering ? 10 : 0, y: 3)
    .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
    .onHover { hovering = $0 }
    .accessibilityLabel(Text(verbatim: "\(name). \(stateLine(summary: summary))"))
    .accessibilityHint(Text("Shows this display's OLED care settings."))
  }

  private func tile(summary: PanelHealthSummary, showsMap: Bool) -> some View {
    // Display aspect, not panel-native: the tile stands for the monitor on
    // the desk, so a portrait mount draws tall. Storage stays panel-native;
    // the surface re-orders for presentation.
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    let width = min(boxWidth, boxHeight * aspect)
    let size = CGSize(width: width, height: width / aspect)
    return Group {
      if showsMap {
        PanelExposureSurface(
          cells: summary.cells,
          highlighted: OledPanelGeometry.hottestIndex(summary.cells),
          aspect: aspect,
          rotation: OledPanelGeometry.rotation(for: state.display.id),
          glowStrength: 0.35)
      } else {
        // No dotted placeholder: a blank surface with the state line under it
        // is quieter and does not read as faint data.
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(.quaternary)
          .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .strokeBorder(.separator, lineWidth: 1)
          }
      }
    }
    .frame(width: size.width, height: size.height)
    .frame(height: boxHeight)
    .accessibilityHidden(true)
  }

  /// One line under the name. Everything the tile draws, in words (the hero's
  /// A4 rule), and nothing the data cannot support.
  private func stateLine(summary: PanelHealthSummary) -> String {
    if model.isSafeMode { return "Paused (Safe Mode)" }
    let hours = PanelHealthCopy.hours(
      model.oledCare.hoursTracker(for: persistenceKey).totalHours)
    if summary.confidence != .estimated, !CGPreflightScreenCaptureAccess() {
      return "\(hours) · waiting on Screen Recording"
    }
    switch summary.confidence {
    case .measured:
      if let relative = summary.hottestRelative,
        let multiple = PanelHealthCopy.multiple(relative)
      {
        return "\(hours) · hottest area \(multiple) average"
      }
      return hours
    case .insufficient:
      return "\(hours) · \(summary.sampleCount) of \(ExposureAccumulator.minimumSamplesForAnalysis) readings"
    case .estimated:
      return "\(hours) · brightness not measured"
    }
  }

}

/// Pressed-state scale for the strip tiles; hover lift lives on the tile so
/// both read from one animation.
struct OledTileButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isPressed)
  }
}

/// Fine corner ticks over the hero surface: instrument framing, drawn, never
/// data. Decorative to VoiceOver by way of the surface's own hidden marker.
struct ReticleTicks: View {
  var body: some View {
    Canvas { context, size in
      let length: CGFloat = 9
      let inset: CGFloat = 3.5
      var path = Path()
      for (x, xDirection): (CGFloat, CGFloat) in [(inset, 1), (size.width - inset, -1)] {
        for (y, yDirection): (CGFloat, CGFloat) in [(inset, 1), (size.height - inset, -1)] {
          path.move(to: CGPoint(x: x + xDirection * length, y: y))
          path.addLine(to: CGPoint(x: x, y: y))
          path.addLine(to: CGPoint(x: x, y: y + yDirection * length))
        }
      }
      context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
    }
    .allowsHitTesting(false)
  }
}

/// The mission-control strip under the hero map. Every field is a real
/// reading: the count and timestamp come off the map itself and the grant is
/// the live preflight, so this line cannot describe a pipeline that is not
/// running.
struct OledTelemetryTicker: View {
  let sampleCount: Int
  let lastSample: Date?
  let grantPresent: Bool

  var body: some View {
    Text(verbatim: line)
      .font(.caption2.monospaced())
      .foregroundStyle(.tertiary)
      .contentTransition(.numericText())
      .animation(.default, value: sampleCount)
  }

  private var line: String {
    var fields = [String(format: "R#%04d", sampleCount)]
    if let lastSample {
      fields.append(lastSample.formatted(date: .omitted, time: .standard))
    }
    fields.append("\(PanelGrid.cellCount) cells")
    fields.append(grantPresent ? "grant OK" : "no grant")
    return fields.joined(separator: " · ")
  }
}

/// The breathing measurement indicator. It may only breathe while readings
/// genuinely land (`lastSample` within two sampling intervals), so the motion
/// IS the telemetry: a dead grant stills it within two minutes, which is the
/// honesty tie the stalled 2026-08-11 soak earned.
struct OledMeasuringDot: View {
  let live: Bool

  @State private var breathing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle()
      .fill(live ? Color.green : Color.secondary.opacity(0.5))
      .frame(width: 7, height: 7)
      .opacity(breathing ? 1 : 0.35)
      .animation(
        live && !reduceMotion
          ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil,
        value: breathing)
      .onAppear { breathing = live }
      .onChange(of: live) { _, isLive in breathing = isLive }
      .accessibilityHidden(true)
  }
}

/// Time at brightness, from the wear signal histogram nothing displayed
/// before. Ten bars, one per stored level bucket, each scaled to the busiest
/// bucket and colored through the shared ramp so dark-to-bright reads
/// left-to-right. Seconds are real accumulated counts (OC20); the dim share
/// is `wearWeightableFraction`, a count of seconds with no model in it.
struct OledBrightnessHistogram: View {
  let secondsByBucket: [Double]

  private var peak: Double { secondsByBucket.max() ?? 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .bottom, spacing: 5) {
        ForEach(secondsByBucket.indices, id: \.self) { bucket in
          let fraction = peak > 0 ? secondsByBucket[bucket] / peak : 0
          UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
            .fill(PanelExposureScale.color(Double(bucket) / 9))
            .opacity(secondsByBucket[bucket] > 0 ? 1 : 0.18)
            .frame(height: max(2, 44 * fraction))
            .frame(maxWidth: .infinity, alignment: .bottom)
        }
      }
      .frame(height: 44, alignment: .bottom)
      HStack {
        Text("Dimmest")
        Spacer(minLength: 0)
        Text("Brightest")
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: spoken))
  }

  private var spoken: String {
    guard peak > 0, let busiest = secondsByBucket.firstIndex(of: peak) else {
      return "Time at brightness, nothing recorded yet"
    }
    let low = busiest * 10
    let high = low + 10
    return "Time at brightness. Most time was spent between \(low) and \(high) percent."
  }
}
