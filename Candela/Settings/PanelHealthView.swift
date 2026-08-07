import CandelaKit
import CoreGraphics
import SwiftUI

/// One panel's accumulated exposure, opened FROM the OLED Care pane rather than
/// embedded in one of its sections (OC19).
///
/// Copy rule, and it is the reason half this file is text (OC11): software has
/// two levers against OLED wear — reduce luminance, and reduce time at
/// luminance. Nothing here may translate a measurement into a lifespan, a date,
/// a percentage of damage avoided or a score. **Relative exposure is measured
/// and therefore sayable**; everything else on offer is not.
///
/// The three `PanelHealthSummary.Confidence` states are three genuinely
/// different pages, not one page with a badge:
/// - `.insufficient` shows **no figures at all** — under 30 samples there is
///   nothing to be right about, and it is the state a freshly enrolled display
///   sits in for its first half hour (and forever, if the Screen Recording
///   grant never arrives).
/// - `.estimated` means measuring is off, so every figure it can show is
///   labelled an estimate.
/// - `.measured` is the only state that shows a multiple of the panel mean.
///
/// Deliberately absent: any convergence or trend line. That needs a multi-week
/// soak to read out and belongs to W3b-2; a placeholder for it here would be a
/// claim the data cannot answer.
@MainActor
struct PanelHealthView: View {
  let displayName: String
  let persistenceKey: String
  /// Live handle, used only to ask macOS how the panel is turned right now — so
  /// the map can say when what it draws is not what is on the glass. Never
  /// persisted and never a key: IDs reassign across a replug.
  let displayID: CGDirectDisplayID?

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var confirmingDelete = false

  /// The coordinator's single door. Non-mutating by contract — it is called
  /// from a `body`, and it deliberately does not memoize the map it may have to
  /// load, because populating an observation-tracked dictionary during view
  /// update is a mutation SwiftUI would report.
  private var summary: PanelHealthSummary {
    model.oledCare.healthSummary(for: persistenceKey)
  }

  var body: some View {
    let summary = self.summary
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          confidenceNote(summary)
          mapCard(summary)
          findings(summary)
          ownersCard(summary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 560, height: 620)
    .confirmationDialog(
      "Delete this display's measurement history?",
      isPresented: $confirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        // The coordinator's own one-step clear — in memory, on disk, and the
        // window attribution derived from it, under its epoch guard so a
        // capture already in flight cannot re-book into what was just deleted.
        // Never re-implemented here.
        model.oledCare.clearExposureHistory(for: persistenceKey)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        verbatim:
          "The accumulated brightness map for \(displayName), and the per-app panel time derived from the same observations, are removed from this Mac. The panel's total on-hours are a separate count and are not affected."
      )
    }
  }

  // MARK: - Chrome

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Panel health")
        .font(.headline)
      Text(verbatim: displayName)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  private var footer: some View {
    HStack {
      Button("Delete History…", role: .destructive) { confirmingDelete = true }
      Spacer(minLength: 12)
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  // MARK: - Confidence

  /// The one place the three states are told apart, so a reader of this file
  /// can check the honesty rule in one screen rather than by tracing four
  /// `if`s through the layout.
  @ViewBuilder private func confidenceNote(_ summary: PanelHealthSummary) -> some View {
    switch summary.confidence {
    case .measured:
      PanelHealthBanner(
        symbol: "checkmark.circle",
        title: Text("Measured"),
        message: Text(
          "Built from one brightness reading a minute while this display has been awake and in use. The figures below describe this panel against itself."
        ))
    case .estimated:
      PanelHealthBanner(
        symbol: "questionmark.circle",
        title: Text("Estimated — brightness is not being measured"),
        message: Text(
          "Measuring is off for this display, so nothing here comes from the screen itself. What is left is window geometry: which app held which part of the display, and for how long. Turn on measuring in OLED Care to record what the panel is actually showing."
        ))
    case .insufficient:
      // Two very different causes reach one enum case, and telling them apart
      // is the difference between "wait" and "this will never start". Preflight
      // does NOT prompt — the only prompting call in the app is the pane's
      // telemetry toggle.
      if displayID != nil, !CGPreflightScreenCaptureAccess() {
        PanelHealthBanner(
          symbol: "exclamationmark.triangle",
          title: Text("Waiting on Screen Recording"),
          message: Text(
            "Measuring is switched on for this display, but macOS has not granted \(AppInfo.productName) Screen Recording, so no readings are being taken. Grant it in System Settings > Privacy & Security > Screen Recording."
          ))
      } else {
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

  @ViewBuilder private func mapCard(_ summary: PanelHealthSummary) -> some View {
    let blank = summary.confidence != .measured

    VStack(alignment: .leading, spacing: 10) {
      Text("Where this panel has been lit")
        .font(.subheadline.weight(.semibold))

      PanelExposureMap(
        cells: summary.cells,
        highlighted: blank ? nil : Self.hottestIndex(summary.cells),
        blank: blank
      )

      if blank {
        Text("Nothing measured to draw yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        PanelExposureLegend()
      }

      SettingsCaption(verbatim: orientationNote)
    }
  }

  /// Panel-native means the geometry the glass was manufactured with — the
  /// landscape rectangle — which is NOT the display's current orientation once
  /// a monitor is mounted rotated. Wear history is accumulated that way on
  /// purpose, so that turning a monitor cannot scramble it, and the map has to
  /// say so or a rotated panel's owner reads it as simply wrong.
  private var orientationNote: String {
    let base =
      "Drawn the way the panel itself is built — the long edge across — so the history survives a monitor being turned."
    guard let displayID, CGDisplayRotation(displayID) != 0 else { return base }
    return base
      + " This display is currently rotated, so the map will not line up with what you see on screen."
  }

  /// The peak cell, found from the normalized array rather than carried on the
  /// summary: `PanelHealthSummary.cells` is divided through by the map's own
  /// peak, so the hottest cell is exactly 1.0, and `ExposureMap.hottestCell`
  /// resolves ties to the first index the same way `firstIndex` does.
  private static func hottestIndex(_ cells: [Double]) -> Int? {
    guard let peak = cells.max(), peak > 0 else { return nil }
    return cells.firstIndex(of: peak)
  }

  // MARK: - Findings

  @ViewBuilder private func findings(_ summary: PanelHealthSummary) -> some View {
    if summary.confidence == .measured, let relative = summary.hottestRelative {
      VStack(alignment: .leading, spacing: 10) {
        Text("The hottest area")
          .font(.subheadline.weight(.semibold))

        // The one number this whole feature is allowed to state: a measured
        // ratio of a panel against itself. It is not a lifespan, a date or a
        // score, and it must never grow into one.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: Self.multiplePhrase(relative))
            .font(.title2.weight(.semibold))
            .monospacedDigit()
          Text("this panel's average")
            .foregroundStyle(.secondary)
        }

        if let region = Self.hottestIndex(summary.cells).map(Self.regionPhrase) {
          SettingsCaption(verbatim: "Outlined on the map, \(region).")
        }

        if let owner = summary.hottestOwner {
          SettingsCaption(
            verbatim: "\(owner) is what is on that part of the display right now.")
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
  /// is — and calling them an estimate here would be as wrong as calling them
  /// measured on the other side.
  @ViewBuilder private func ownersCard(_ summary: PanelHealthSummary) -> some View {
    let owners = summary.topOwnersByHours
    VStack(alignment: .leading, spacing: 10) {
      Text("Panel time by app")
        .font(.subheadline.weight(.semibold))

      if owners.isEmpty {
        Text("No data yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        // Index-keyed: the elements are tuples, which cannot be `Identifiable`,
        // and an owner name is not guaranteed unique across the list.
        ForEach(Array(owners.enumerated()), id: \.offset) { _, entry in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: entry.owner)
            Spacer(minLength: 0)
            Text(verbatim: Self.panelTimePhrase(entry.hours))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }

      // The figure is panel-time, NOT how long the app was open: an app filling
      // the display books an hour per hour, one covering a quarter books
      // fifteen minutes. Saying "Ghostty was open for 3 hours" would be a claim
      // this does not measure, so the caption states the weighting outright.
      SettingsCaption(
        "Weighted by how much of the panel each app's windows covered, so this is not how long the app was open. Read from window positions and owner names only — never window titles, and never their contents — and only while the display is awake and undimmed."
      )
    }
  }

  // MARK: - Formatting

  /// One decimal, because the underlying ratio is a mean over 240 cells and a
  /// second decimal would imply a precision the grid does not have.
  private static func multiplePhrase(_ relative: Double) -> String {
    guard relative.isFinite else { return "—" }
    return String(format: "%.1f×", relative)
  }

  /// Minutes below the hour. A freshly enrolled panel's whole leaderboard is
  /// under an hour for its first hour, and a column of "0.0 hours" reads as a
  /// counter that is not running — the same defect the pane's own hours line
  /// is written around.
  private static func panelTimePhrase(_ hours: Double) -> String {
    guard hours.isFinite, hours > 0 else { return "none yet" }
    if hours < 1 {
      let minutes = Int((hours * 60).rounded())
      if minutes < 1 { return "under a minute" }
      return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
    if hours < 10 { return String(format: "%.1f hours", hours) }
    return "\(Int(hours.rounded())) hours"
  }

  /// Thirds, named. Deliberately coarse: the grid is 24×10 over a 3440-wide
  /// panel, so "column 17" would be a false precision and "toward the top,
  /// right of centre" is what someone can actually go and look at.
  private static func regionPhrase(_ index: Int) -> String {
    let col = index % PanelGrid.cols
    let row = index / PanelGrid.cols
    let vertical = ["toward the top", "across the middle", "toward the bottom"][
      min(2, row * 3 / PanelGrid.rows)]
    let horizontal = ["on the left", "in the centre", "on the right"][
      min(2, col * 3 / PanelGrid.cols)]
    return "\(vertical), \(horizontal)"
  }
}

// MARK: - Banner

/// Symbol AND text, never state by colour alone — the same rule the OLED Care
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

/// The stored grid, drawn at the size it is stored in.
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
    .aspectRatio(CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows), contentMode: .fit)
    .frame(maxWidth: .infinity)
    .accessibilityElement()
    .accessibilityLabel(
      Text(
        verbatim:
          "Exposure map, \(PanelGrid.cols) by \(PanelGrid.rows) cells in the panel's own orientation"
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
    let clamped = min(1, max(0, value.isFinite ? value : 0))
    let scaled = clamped * Double(anchors.count - 1)
    let lower = min(anchors.count - 2, Int(scaled))
    let t = scaled - Double(lower)
    let a = anchors[lower]
    let b = anchors[lower + 1]
    return Color(
      .sRGB,
      red: a.r + (b.r - a.r) * t,
      green: a.g + (b.g - a.g) * t,
      blue: a.b + (b.b - a.b) * t,
      opacity: 1)
  }
}

/// The grid at glyph size, so the telemetry toggle's "at about the resolution
/// of this grid" has a grid to point at. Same dimensions as the real map — the
/// sentence is a claim about resolution, so a decorative stand-in with a
/// different cell count would make it false.
struct PanelGridMark: View {
  var body: some View {
    PanelExposureMap(cells: [], highlighted: nil, blank: true)
      .frame(width: 96)
      .accessibilityHidden(true)
  }
}
