import Foundation

/// One record as plain text, in the diagnostics report's shape. Copy summary and
/// the verifier both render through here. Nothing here grades the display.
public enum ProvenanceSummaryText {
  public static func render(_ record: ProvenanceRecord) -> String {
    var lines = record.header
    lines += ["", "Display: \(record.identity.displayName)",
              "Identity key: \(record.identity.persistenceKey)",
              exportedLine(record)]
    lines += identityLines(record.identity)
    lines += ["", "Hours"] + hoursLines(record.hours)
    lines += ["", "Exposure"] + exposureLines(record.exposure)
    lines += ["", "Checkups"] + checkupLines(record.checkups)
    return lines.joined(separator: "\n")
  }

  /// An empty `appBuild` means "not recorded", from a file written before builds
  /// were. Naming it anyway would claim a build nobody knows.
  private static func exportedLine(_ record: ProvenanceRecord) -> String {
    let day = CheckupStore.day(record.exportedAt)
    return record.appBuild.isEmpty ? "Exported: \(day)" : "Exported: \(day) by Candela \(record.appBuild)"
  }

  private static func identityLines(_ identity: ProvenanceIdentity) -> [String] {
    var lines = ["Serial: \(serial(identity))"]
    if let edid = identity.edid {
      if let week = edid.manufactureWeek, let year = edid.manufactureYear {
        lines.append("Manufactured: week \(week) of \(year)")
      }
      lines.append("Native size: \(edid.nativePixelWidth) x \(edid.nativePixelHeight) pixels")
    }
    if let transport = identity.hardware?.transport {
      lines.append("Connection: \(transport)")
    }
    if let w = identity.hardware?.physicalWidthCm, let h = identity.hardware?.physicalHeightCm {
      lines.append("Screen size: \(w) x \(h) cm")
    }
    return lines
  }

  /// An EDID that reports no serial already reads as the fixed phrase, so it
  /// must not shadow a serial the connection layer did learn.
  private static func serial(_ identity: ProvenanceIdentity) -> String {
    let fromEDID = identity.edid?.serial
    return fromEDID.flatMap { $0 == CheckupDisplayIdentity.noSerial ? nil : $0 }
      ?? identity.hardware?.alphanumericSerial
      ?? identity.hardware?.numericSerial.map(String.init)
      ?? CheckupDisplayIdentity.noSerial
  }

  /// "Hours of use", never "panel hours": the copy rule keeps "panel" out of every
  /// string a person can read, type names and comments excepted.
  private static func hoursLines(_ section: ProvenanceSection<ProvenanceHours>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let h):
      return ["Hours of use: \(duration(h.lifetimeSeconds))",
              "Since last standby: \(duration(h.secondsSinceStandby))"]
    }
  }

  private static func exposureLines(_ section: ProvenanceSection<ProvenanceExposure>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let e):
      var lines = [readingsLine(e)]
      if let first = e.firstSample, let last = e.lastSample {
        lines.append("Recorded from \(CheckupStore.day(first)) to \(CheckupStore.day(last))")
      }
      // Under `.estimated` the peak is window geometry, not exposure, so naming a
      // hottest cell would read as a reading nobody took.
      if e.confidence == .measured, let hottest = hottestCell(e.cells) {
        lines.append("Hottest cell: \(hottest + 1) of \(e.cells.count)")
      }
      if let h = e.wearHistogram {
        for (name, row) in zip(h.stateOrder, h.seconds) where row.reduce(0, +) > 0 {
          lines.append("Time in \(stateWord(name)): \(duration(row.reduce(0, +)))")
        }
      }
      return lines
    }
  }

  private static func readingsLine(_ e: ProvenanceExposure) -> String {
    switch e.confidence {
    case .measured: "Readings: \(e.sampleCount) (measured)"
    case .insufficient: "Readings: \(e.sampleCount) (too few to analyze)"
    case .estimated: "Readings: \(e.sampleCount) recorded earlier; exposure measurement is off"
    }
  }

  /// The same scan as `ExposureMap.hottestCell`: strict `>` so a plateau names its
  /// first cell. A person reads both in one session, so the two must agree.
  private static func hottestCell(_ cells: [Double]) -> Int? {
    var hottest: Int?
    var peak = 0.0
    for (index, value) in cells.enumerated() where value > peak {
      peak = value
      hottest = index
    }
    return hottest
  }

  private static func checkupLines(_ section: ProvenanceSection<ProvenanceCheckups>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let c):
      var lines = ["Runs: \(c.runs.count)"]
      for (name, n) in c.countsByVerdict.sorted(by: { $0.key < $1.key }) {
        lines.append("\(verdictWord(name)): \(n)")
      }
      for run in c.runs {
        lines.append("\(CheckupStore.day(run.report.startedAt)): \(run.report.summary.line)")
      }
      return lines
    }
  }

  /// Stored verdict names are file schema, not English. An unmapped key shows as
  /// it is; a newer file can carry a verdict this build never heard of.
  private static func verdictWord(_ key: String) -> String {
    switch key {
    case "observed": "Observed"
    case "refused": "Refused"
    case "notObserved": "Not observed"
    case "selfReported": "Self-reported"
    case "inconclusive": "Inconclusive"
    default: key
    }
  }

  /// Same reasoning as `verdictWord`, for the wear histogram's stored state
  /// names. Lower case: these read inside a sentence.
  private static func stateWord(_ key: String) -> String {
    switch key {
    case "idleDim": "idle dim"
    case "lockDim": "lock dim"
    case "unfocusedDim": "unfocused dim"
    default: key
    }
  }

  private static func duration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
  }
}
