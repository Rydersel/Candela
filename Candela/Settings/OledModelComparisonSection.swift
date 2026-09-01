import CandelaKit
import CoreGraphics
import SwiftUI

/// EM9's gate instrument, as amended by OCR7: scores the estimated exposure
/// model against the measured readings, beside the measurement controls and
/// never inside the health view it might one day change. Shown once measurement
/// is on or a stored comparison exists, so turning measurement off keeps the
/// score.
///
/// TEMPORARY, built to be deleted (OCR7). Hidden from the shipped window behind
/// the `showModelComparison` defaults key (D26) until Ryder records the verdict
/// on the comparison gate; deletion is then: remove this file, the one call
/// site in `HealthPane`, and the key. The stalled-sampling note already lives
/// on the measurement toggle, since it proved necessary independently.
@MainActor
struct OledModelComparisonSection: View {
  let persistenceKey: String

  @Environment(AppModel.self) private var model

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  var body: some View {
    let comparison = model.oledCare.modelComparison(for: persistenceKey)
    if prefs.oledTelemetry || comparison.pairCount > 0 {
      SettingsCardSection(title: "Model Comparison") {
        SettingRow(caption: SettingsCaption("Scores an estimate built only from window positions, the wallpaper, and light or dark appearance against the measured readings above. If the two keep agreeing, the estimate can stand in when Screen Recording is off. Estimated figures are never presented as measured.")) {
          VStack(alignment: .leading, spacing: 6) {
            SettingsCaption("A temporary instrument: it exists to judge the estimate during the current soak, is shown only when turned on from the command line, and is removed once that verdict is recorded.")
            LabeledContent("Paired readings") {
              Text(verbatim: pairedReadingsLine(comparison))
                .foregroundStyle(SettingsTheme.bodyColor)
            }
            if let last = comparison.lastPair {
              LabeledContent("Last pair") {
                Text(verbatim: Self.relativePhrase(last))
                  .foregroundStyle(SettingsTheme.bodyColor)
              }
            }
            if let stats = comparison.statistics() {
              LabeledContent("Correlation") {
                Text(verbatim: String(format: "%.2f", stats.pearson))
                  .foregroundStyle(SettingsTheme.bodyColor)
              }
              LabeledContent("Rank agreement") {
                Text(verbatim: String(format: "%.2f", stats.spearmanRank))
                  .foregroundStyle(SettingsTheme.bodyColor)
              }
              LabeledContent("Hottest regions in common") {
                Text(verbatim: Self.overlapPhrase(stats.hottestDecileOverlap))
                  .foregroundStyle(SettingsTheme.bodyColor)
              }
              if let measured = PanelHealthCopy.multiple(stats.measuredHottestMultiple),
                let modelled = PanelHealthCopy.multiple(stats.modelledHottestMultiple)
              {
                LabeledContent("Hottest region") {
                  Text(verbatim: "measured \(measured), estimated \(modelled)")
                    .foregroundStyle(SettingsTheme.bodyColor)
                }
              }
            } else if comparison.pairCount > 0 {
              OledInlineNote(Text("Still accumulating. Scores appear after 30 paired readings."))
            }
          }
        }
      }
    }
  }

  private func pairedReadingsLine(_ comparison: ModelComparison) -> String {
    guard comparison.pairCount > 0 else { return "None yet" }
    // A single pair has no span worth naming: "spanning 0 minutes" reads as a
    // broken counter.
    guard comparison.pairCount > 1, let first = comparison.firstPair,
      let last = comparison.lastPair
    else { return "\(comparison.pairCount)" }
    return "\(comparison.pairCount), spanning \(Self.spanPhrase(last.timeIntervalSince(first)))"
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
    // formatter, because the timestamps straddle the render by microseconds.
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
