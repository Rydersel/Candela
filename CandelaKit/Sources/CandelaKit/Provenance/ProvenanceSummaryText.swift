import Foundation

/// One record as plain text, in the diagnostics report's shape. The one
/// renderer: Copy summary and the verifier both come through here. Nothing
/// here grades the display.
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

  /// A file written before the builds were recorded carries an empty
  /// `appBuild`, which means "not recorded". Naming it anyway would read as a
  /// claim about a build nobody knows.
  private static func exportedLine(_ record: ProvenanceRecord) -> String {
    let day = CheckupStore.day(record.exportedAt)
    return record.appBuild.isEmpty ? "Exported: \(day)" : "Exported: \(day) by Candela \(record.appBuild)"
  }

  private static func identityLines(_ identity: ProvenanceIdentity) -> [String] {
    var lines: [String] = []
    let serial = identity.edid?.serial
      ?? identity.hardware?.alphanumericSerial
      ?? identity.hardware?.numericSerial.map(String.init)
      ?? CheckupDisplayIdentity.noSerial
    lines.append("Serial: \(serial)")
    if let edid = identity.edid, let week = edid.manufactureWeek, let year = edid.manufactureYear {
      lines.append("Manufactured: week \(week) of \(year)")
    }
    if let edid = identity.edid {
      lines.append("Native size: \(edid.nativePixelWidth) x \(edid.nativePixelHeight) pixels")
    }
    if let transport = identity.hardware?.transport {
      lines.append("Connection: \(transport)")
    }
    if let w = identity.hardware?.physicalWidthCm, let h = identity.hardware?.physicalHeightCm {
      lines.append("Panel size: \(w) x \(h) cm")
    }
    return lines
  }

  private static func hoursLines(_ section: ProvenanceSection<ProvenanceHours>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let h):
      return ["Panel-on time: \(duration(h.lifetimeSeconds))",
              "Since last standby: \(duration(h.secondsSinceStandby))"]
    }
  }

  private static func exposureLines(_ section: ProvenanceSection<ProvenanceExposure>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let e):
      var lines = ["Readings: \(e.sampleCount) (\(confidenceWord(e.confidence)))"]
      if let first = e.firstSample, let last = e.lastSample {
        lines.append("Recorded from \(CheckupStore.day(first)) to \(CheckupStore.day(last))")
      }
      if let hottest = e.cells.indices.max(by: { e.cells[$0] < e.cells[$1] }), e.cells[hottest] > 0 {
        lines.append("Hottest cell: \(hottest) of \(e.cells.count)")
      }
      if let h = e.wearHistogram {
        for (name, row) in zip(h.stateOrder, h.seconds) where row.reduce(0, +) > 0 {
          lines.append("Time in \(name): \(duration(row.reduce(0, +)))")
        }
      }
      return lines
    }
  }

  private static func checkupLines(_ section: ProvenanceSection<ProvenanceCheckups>) -> [String] {
    switch section {
    case .notCollected(let reason): return [reason.sentence]
    case .collected(let c):
      var lines = ["Runs: \(c.runs.count)"]
      for (name, n) in c.countsByVerdict.sorted(by: { $0.key < $1.key }) {
        lines.append("\(name): \(n)")
      }
      for run in c.runs {
        lines.append("\(CheckupStore.day(run.report.startedAt)): \(run.report.summary.line)")
      }
      return lines
    }
  }

  private static func confidenceWord(_ c: ProvenanceExposure.Confidence) -> String {
    switch c {
    case .measured: "measured"
    case .estimated: "window geometry only, no exposure readings"
    case .insufficient: "too few readings to analyse"
    }
  }

  private static func duration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
  }
}
