import CandelaKit
import Foundation

/// One report as plain text (CK31), in the diagnostics report's shape: a header,
/// labeled facts, then a section per family.
///
/// The ONE renderer. The flow's Copy summary, the pane's history and anything
/// that hands a run to a person all come through here, so a reader who compares
/// two copies of the same run never finds them saying different things.
///
/// Nothing here grades the display (CK8): the families carry their claims, the
/// summary counts verdicts, and the completion line says how the run ended.
enum CheckupSummaryText {
  /// CK30: the file states in its own body that the visual fields are
  /// attestations rather than measurements. Its own sentence, not the summary
  /// page's, because the page can point at the control sensitivity on screen
  /// above it and a document cannot.
  static let attestationNote =
    "These are the user's attestations at the recorded control sensitivity."

  static let notReported = "not reported"

  static func render(_ report: CheckupReport) -> String {
    // The subject line carries the product name, the scenario and the UTC day
    // the exported file name uses; deriving any of the three again here is how
    // a document and its file name start disagreeing.
    var lines = [CheckupReport.headerSentence, "", CheckupCopy.subjectLine(for: report), ""]
    lines += identityLines(report)
    if let occlusion = CheckupCopy.occlusionLine(fieldIDs: report.partiallyOccludedFields) {
      lines += ["", occlusion]
    }
    for family in CheckupFamily.allCases {
      let claims = report.claims.filter { $0.family == family }
      guard !claims.isEmpty else { continue }
      lines += ["", CheckupCopy.familyTitle(family)]
      lines += claims.map(claimLine)
      if family == .visualField { lines.append(attestationNote) }
    }
    lines += ["", report.summary.line, completionLine(report)]
    return lines.joined(separator: "\n")
  }

  /// What the display said about itself, plus what the run ran on. The identity
  /// claim quotes most of this too, and it is repeated here on purpose: a run
  /// abandoned before the identity leg has no such claim, and these are the
  /// fields a person checks a report against the box by.
  private static func identityLines(_ report: CheckupReport) -> [String] {
    let identity = report.identity
    var lines = ["Serial: \(identity.serial)"]
    if let week = identity.manufactureWeek, let year = identity.manufactureYear {
      lines.append("Manufactured: week \(week) of \(year)")
    } else {
      lines.append("Manufactured: \(notReported)")
    }
    lines.append("Native resolution: \(identity.nativePixelWidth) by \(identity.nativePixelHeight)")
    if let hz = identity.maxRefreshHz {
      lines.append("Maximum refresh: \(rate(hz)) Hz")
    } else {
      lines.append("Maximum refresh: \(notReported)")
    }
    lines.append(
      "HDR flags in the display's EDID: PQ \(present(identity.supportsPQEOTF)), "
        + "HDR gamma \(present(identity.supportsHDRGammaEOTF))")
    lines.append("macOS: \(report.macOSBuild)")
    lines.append("\(AppInfo.productName): \(report.appBuild)")
    // Its own paragraph rather than a labeled fact: it is the sentence that
    // explains why a "not observed" below is about the panel's DDC and not
    // about the panel's picture.
    lines += ["", CheckupCopy.panelClassLine(report.panelClass)]
    return lines
  }

  /// Never the stored id: those are shipped schema and read like the keys they
  /// are, so the claim's prose name is what a person gets.
  private static func claimLine(_ claim: CheckupClaim) -> String {
    let sensitivity = claim.detectedAt.map { " " + CheckupCopy.detectedAt(pixels: $0) } ?? ""
    return "- \(CheckupCopy.claimLabel(id: claim.id)): "
      + "\(CheckupCopy.verdictLabel(claim.verdict)): \(claim.verdict.text)\(sensitivity)"
  }

  private static func completionLine(_ report: CheckupReport) -> String {
    switch report.completion {
    case .complete: "Completion: complete. \(CheckupCopy.summaryComplete)"
    case .incomplete(let reason):
      "Completion: incomplete. \(CheckupCopy.summaryIncomplete(reason: reason))"
    }
  }

  private static func present(_ flag: Bool) -> String { flag ? "present" : "absent" }

  /// One quantization boundary for the whole app: float noise prints the same,
  /// and NTSC's 59.9 stays its own number.
  private static func rate(_ hz: Double) -> String {
    String(format: "%g", DisplayMode.quantizedRefresh(hz))
  }
}
