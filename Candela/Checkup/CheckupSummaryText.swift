import CandelaKit
import Foundation

/// One report as plain text (CK31), in the diagnostics report's shape. The ONE
/// renderer, so two copies of a run never disagree. Nothing here grades the
/// display (CK8).
enum CheckupSummaryText {
  static func render(_ report: CheckupReport) -> String {
    // The subject line owns the product name, scenario and UTC day; deriving
    // any of them again here is how document and file name drift.
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

  /// CK30, measured claims only: the identity block exists only when the leg
  /// read an EDID. An abandoned run carries a placeholder identity, and
  /// printing it would report a serial and flags nothing observed.
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
    // Its own paragraph: this sentence is why a "not observed" below is about
    // DDC, not the picture.
    // Derived from the capability rows rather than stored twice: the pre-graded
    // reason is the record that HDR was engaged.
    let hdrEngaged = report.claims.contains {
      $0.family == .capabilities
        && $0.verdict == .notObserved(CheckupPlan.hdrEngagedCapabilityText)
    }
    lines += ["", CheckupCopy.panelClassLine(report.panelClass, hdrEngaged: hdrEngaged)]
    return lines
  }

  /// Only an observed identity claim licenses the block; a refusal, a
  /// not-observed or a missing claim all mean the display was not read. The
  /// provenance exporter picks a stored run by the same rule.
  static func identityWasRead(_ report: CheckupReport) -> Bool {
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
