import CandelaKit
import Foundation

/// One report as plain text (CK31), in the diagnostics report's shape: a header,
/// labeled facts, then a section per family.
///
/// The ONE renderer. The flow's summary page, its Copy summary, the pane's
/// history and anything that hands a run to a person all come through here, so
/// a reader who compares two copies of the same run never finds them saying
/// different things.
///
/// Nothing here grades the display (CK8): the families carry their claims, the
/// summary counts verdicts, and the completion line says how the run ended.
enum CheckupSummaryText {
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
      if family == .visualField { lines.append(CheckupCopy.attestationNote) }
    }
    lines += ["", report.summary.line, CheckupCopy.completionLine(report.completion)]
    return lines.joined(separator: "\n")
  }

  /// What the display said about itself, plus what the run ran on.
  ///
  /// CK30, measured claims only: every line in the first block is read out of
  /// the EDID, so the block exists only when the identity leg actually read one.
  /// A run abandoned before that leg still carries a fully populated
  /// `CheckupDisplayIdentity` built from placeholders, and printing it would
  /// have the document report a serial, a native size and a pair of HDR flags
  /// that nothing observed.
  private static func identityLines(_ report: CheckupReport) -> [String] {
    var lines: [String] = []
    if identityWasRead(report) {
      let identity = report.identity
      lines.append("\(CheckupCopy.serialLabel) \(identity.serial)")
      if let week = identity.manufactureWeek, let year = identity.manufactureYear {
        lines.append(CheckupCopy.manufactured(week: week, year: year))
      } else {
        lines.append("\(CheckupCopy.manufacturedLabel) \(CheckupCopy.notReported)")
      }
      lines.append("\(CheckupCopy.nativeResolutionLabel) \(nativeSize(identity))")
      if let hz = identity.maxRefreshHz {
        lines.append("\(CheckupCopy.maximumRefreshLabel) \(rate(hz)) Hz")
      } else {
        lines.append("\(CheckupCopy.maximumRefreshLabel) \(CheckupCopy.notReported)")
      }
      lines.append(
        CheckupCopy.hdrFlagsLine(
          pq: identity.supportsPQEOTF, hdrGamma: identity.supportsHDRGammaEOTF))
    } else {
      lines.append(CheckupCopy.identityNotRead)
    }
    // The two builds are facts about the run rather than about the display, so
    // they stand either way.
    lines.append("\(CheckupCopy.macOSLabel) \(report.macOSBuild)")
    lines.append("\(AppInfo.productName): \(report.appBuild)")
    // Its own paragraph rather than a labeled fact: it is the sentence that
    // explains why a "not observed" below is about the panel's DDC and not
    // about the panel's picture.
    lines += ["", CheckupCopy.panelClassLine(report.panelClass)]
    return lines
  }

  /// Only an observed identity claim licenses the block. A refusal, a
  /// not-observed, or no claim at all all mean the same thing to a reader: the
  /// display was not read.
  private static func identityWasRead(_ report: CheckupReport) -> Bool {
    guard let claim = report.claims.first(where: { $0.id == CheckupCheckID.identity })
    else { return false }
    if case .observed = claim.verdict { return true }
    return false
  }

  /// A zero size is a placeholder that survived, not a panel that measures zero.
  private static func nativeSize(_ identity: CheckupDisplayIdentity) -> String {
    guard identity.nativePixelWidth > 0, identity.nativePixelHeight > 0 else {
      return CheckupCopy.notReported
    }
    return "\(identity.nativePixelWidth) by \(identity.nativePixelHeight)"
  }

  /// Never the stored id: those are shipped schema and read like the keys they
  /// are, so the claim's prose name is what a person gets.
  private static func claimLine(_ claim: CheckupClaim) -> String {
    let sensitivity = claim.detectedAt.map { " " + CheckupCopy.detectedAt(pixels: $0) } ?? ""
    return "- \(CheckupCopy.claimLabel(id: claim.id)): "
      + "\(CheckupCopy.verdictLabel(claim.verdict)): \(claim.verdict.text)\(sensitivity)"
  }

  /// One quantization boundary for the whole app: float noise prints the same,
  /// and NTSC's 59.9 stays its own number.
  private static func rate(_ hz: Double) -> String {
    String(format: "%g", DisplayMode.quantizedRefresh(hz))
  }
}
