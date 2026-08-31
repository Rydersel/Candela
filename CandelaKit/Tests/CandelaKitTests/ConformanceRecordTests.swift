import Foundation
import Testing
@testable import CandelaKit

/// R-B: the ledger reads the JSON, people read the lines, and both are derived
/// from one `Report` value so neither can drift from the other.
@Suite("Conformance run record")
struct ConformanceRecordTests {
  private typealias PC = PlatformConformance

  @Test func recordCarriesEveryFieldTheLedgerNeeds() throws {
    var report = PC.Report(platform: "Version 26.6.1 (Build 25G76)")
    report.checks = [
      .init(name: "a", outcome: .pass("fine"), control: .fired),
      .init(name: "b", outcome: .inconclusive("control failed"), control: .failed),
      .init(name: "c", outcome: .skip("no panel")),
    ]
    let when = Date(timeIntervalSince1970: 1_766_150_000)
    let record = report.runRecord(label: "regress", commit: "abc1234", timestamp: when)
    #expect(record.schema == 1)
    #expect(record.commit == "abc1234")
    // The outcome strings and the detail passthrough are the ledger's jq keys, so a typo
    // or a detail/name swap has to fail here rather than reach a committed ledger row.
    #expect(record.checks[0].outcome == "pass")
    #expect(record.checks[0].detail == "fine")
    #expect(record.checks[0].control == "fired")
    #expect(record.checks[1].outcome == "inconclusive")
    #expect(record.checks[1].detail == "control failed")
    #expect(record.checks[2].outcome == "skip")
    #expect(record.checks[2].detail == "no panel")
    #expect(record.checks[2].control == nil)
    #expect(record.inconclusive == 1 && record.passed == 1 && record.skipped == 1)
  }

  @Test func jsonRoundTrips() throws {
    var report = PC.Report(platform: "p")
    report.checks = [.init(name: "a", outcome: .fail("broke"), control: .fired)]
    let data = try report.jsonData(
      label: "regress", commit: "deadbee", timestamp: .init(timeIntervalSince1970: 0))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(PC.RunRecord.self, from: data)
    #expect(back.commit == "deadbee")
    #expect(back.checks[0].outcome == "fail")
  }

  /// The ledger is a committed directory read by a jq step, so the bytes have to diff
  /// like text: sorted keys, and a readable date stamp rather than a float.
  @Test func theEncodingIsStableForACommittedLedger() throws {
    // The key-order walk below searches bare substrings, so no fixture value here may
    // contain a key name.
    var report = PC.Report(platform: "p")
    report.checks = [.init(name: "a", outcome: .pass("fine"))]
    let json = try String(
      decoding: report.jsonData(
        label: "conform", commit: "cafe123", timestamp: .init(timeIntervalSince1970: 0)),
      as: UTF8.self)
    #expect(json.contains("\"timestamp\":\"1970-01-01T00:00:00Z\""))
    let keyOrder = ["\"checks\"", "\"commit\"", "\"failed\"", "\"inconclusive\"", "\"label\"",
                    "\"passed\"", "\"platform\"", "\"schema\"", "\"skipped\"", "\"timestamp\""]
    var cursor = json.startIndex
    for key in keyOrder {
      let found = try #require(json.range(of: key, range: cursor ..< json.endIndex))
      cursor = found.upperBound
    }
  }

  /// A check with no positive control must encode its absence, not a
  /// placeholder string a jq filter would count as a control that fired.
  @Test func aControlFreeCheckOmitsTheField() throws {
    var report = PC.Report(platform: "p")
    report.checks = [.init(name: "a", outcome: .skip("no panel"))]
    let json = try String(
      decoding: report.jsonData(
        label: "conform", commit: "c", timestamp: .init(timeIntervalSince1970: 0)),
      as: UTF8.self)
    #expect(!json.contains("\"control\""))
  }
}
