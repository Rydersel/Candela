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
  let cells: [Double]
  let highlighted: Int?
  let aspect: CGFloat

  var body: some View {
    Group {
      if let image = Self.rasterize(cells) {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .aspectRatio(aspect, contentMode: .fit)
    .overlay {
      if let highlighted, cells.indices.contains(highlighted) {
        Canvas { context, size in
          let width = size.width / CGFloat(PanelGrid.cols)
          let height = size.height / CGFloat(PanelGrid.rows)
          let rect = CGRect(
            x: CGFloat(highlighted % PanelGrid.cols) * width,
            y: CGFloat(highlighted / PanelGrid.cols) * height,
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
    .accessibilityHidden(true)
  }

  /// One pixel per stored cell, colored through the shared ramp. Row 0 of a
  /// `CGImage` is the top row, the same top-left convention the cells are
  /// stored in, so no flip.
  private static func rasterize(_ cells: [Double]) -> CGImage? {
    guard cells.count == PanelGrid.cellCount else { return nil }
    let cols = PanelGrid.cols
    let rows = PanelGrid.rows
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
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: "\(name). \(stateLine(summary: summary))"))
    .accessibilityHint(Text("Shows this display's OLED care settings."))
  }

  private func tile(summary: PanelHealthSummary, showsMap: Bool) -> some View {
    let aspect =
      OledPanelGeometry.panelNativeAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    let width = min(boxWidth, boxHeight * aspect)
    let size = CGSize(width: width, height: width / aspect)
    return Group {
      if showsMap {
        PanelExposureSurface(
          cells: summary.cells,
          highlighted: OledPanelGeometry.hottestIndex(summary.cells),
          aspect: aspect)
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
      return "\(hours) · not enough readings yet"
    case .estimated:
      return "\(hours) · brightness not measured"
    }
  }

}
