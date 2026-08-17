import CandelaKit
import CoreGraphics
import SwiftUI

/// EM9's gate instrument, as amended by OCR7: scores the estimated exposure
/// model against the measured readings, on the Measurement & Data page and
/// revertable, never inside the health view it might one day change. Shown
/// once measurement is on or a stored comparison exists, so a user who turns
/// measurement off keeps their score.
///
/// **TEMPORARY, built to be deleted (OCR7).** This section exists to judge the
/// estimate during the current soak. Once Ryder records the verdict on the
/// comparison gate, deletion is: remove this file, remove the one call site in
/// `OledCareMeasurementPage`, and move the stalled-sampling note below up to
/// ride the "Measure how bright each part of this display is" toggle, because
/// that note proved necessary independently of the comparison.
@MainActor
struct OledModelComparisonSection: View {
  let persistenceKey: String

  @Environment(AppModel.self) private var model

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  var body: some View {
    let comparison = model.oledCare.modelComparison(for: persistenceKey)
    if prefs.oledTelemetry || comparison.pairCount > 0 {
      Section {
        SettingRow(caption: SettingsCaption("Scores an estimate built only from window positions, the wallpaper, and light or dark appearance against the measured readings above. If the two keep agreeing, the estimate can stand in when Screen Recording is off. Estimated figures are never presented as measured.")) {
          VStack(alignment: .leading, spacing: 6) {
            SettingsCaption("A temporary instrument: it exists to judge the estimate during the current soak, and it is removed once that verdict is recorded.")
            LabeledContent("Paired readings") {
              Text(verbatim: pairedReadingsLine(comparison))
                .foregroundStyle(.secondary)
            }
            if let last = comparison.lastPair {
              LabeledContent("Last pair") {
                Text(verbatim: Self.relativePhrase(last))
                  .foregroundStyle(.secondary)
              }
            }
            if let stats = comparison.statistics() {
              LabeledContent("Correlation") {
                Text(verbatim: String(format: "%.2f", stats.pearson))
                  .foregroundStyle(.secondary)
              }
              LabeledContent("Rank agreement") {
                Text(verbatim: String(format: "%.2f", stats.spearmanRank))
                  .foregroundStyle(.secondary)
              }
              LabeledContent("Hottest regions in common") {
                Text(verbatim: Self.overlapPhrase(stats.hottestDecileOverlap))
                  .foregroundStyle(.secondary)
              }
              if let measured = PanelHealthCopy.multiple(stats.measuredHottestMultiple),
                let modelled = PanelHealthCopy.multiple(stats.modelledHottestMultiple)
              {
                LabeledContent("Hottest region") {
                  Text(verbatim: "measured \(measured), estimated \(modelled)")
                    .foregroundStyle(.secondary)
                }
              }
            } else if comparison.pairCount > 0 {
              OledInlineNote(Text("Still accumulating. Scores appear after 30 paired readings."))
            }
            if isComparisonStalled(comparison) {
              OledInlineNote(Text("No paired reading in over 10 minutes while measurement is on. If this persists, macOS may have dropped the Screen Recording grant after an update to the app; check System Settings > Privacy & Security > Screen Recording."))
            }
          }
        }
      } header: {
        Text("Model Comparison").settingsHeading()
      }
    }
  }

  private func pairedReadingsLine(_ comparison: ModelComparison) -> String {
    guard comparison.pairCount > 0 else { return "None yet" }
    // A single pair has no span worth naming; "spanning 0 minutes" reads as a
    // broken counter.
    guard comparison.pairCount > 1, let first = comparison.firstPair,
      let last = comparison.lastPair
    else { return "\(comparison.pairCount)" }
    return "\(comparison.pairCount), spanning \(Self.spanPhrase(last.timeIntervalSince(first)))"
  }

  /// Stalled means the pipeline should be producing pairs and is not: the
  /// pref is on, the grant preflights true, the session is not Safe Mode, and
  /// the last pair is well past the sampling interval. A missing grant is NOT
  /// stalled here; the measurement rows above already carry that note.
  private func isComparisonStalled(_ comparison: ModelComparison) -> Bool {
    guard prefs.oledTelemetry, !model.isSafeMode, CGPreflightScreenCaptureAccess(),
      let last = comparison.lastPair
    else { return false }
    return Date().timeIntervalSince(last) > 600
  }

  private static func spanPhrase(_ interval: TimeInterval) -> String {
    let minutes = Int((interval / 60).rounded())
    if minutes < 120 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
    let hours = interval / 3600
    if hours < 48 {
      let whole = Int(hours.rounded())
      return whole == 1 ? "1 hour" : "\(whole) hours"
    }
    return String(format: "%.1f days", hours / 24)
  }

  private static func relativePhrase(_ date: Date) -> String {
    // A pair booked this minute rounds to "in 0 seconds" through the relative
    // formatter (the timestamps straddle the render by microseconds); the
    // honest phrase for anything inside one sampling interval is this one.
    let interval = Date().timeIntervalSince(date)
    guard interval >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private static func overlapPhrase(_ overlap: Double) -> String {
    "\(Int((overlap * 24).rounded())) of 24"
  }
}
