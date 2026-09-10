import Foundation
import Testing
@testable import CandelaKit

@Suite("Media-key grant marker")
struct MediaKeyGrantMarkerTests {
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  @Test func aFreshMachineHasNoMarker() {
    #expect(!MediaKeyGrantMarker(directory: temporaryDirectory()).exists)
  }

  @Test func recordingMakesTheMarkerPresent() {
    let marker = MediaKeyGrantMarker(directory: temporaryDirectory())
    marker.record()
    #expect(marker.exists)
  }

  /// The launch path records on every launch that sees the grant, so a rewrite
  /// would cost a disk write each time and lose the first date. A sentinel stands
  /// in for the first body: two real stamps taken this close together are equal
  /// whether or not the second call wrote.
  @Test func recordingTwiceIsHarmlessAndKeepsTheFirstStamp() throws {
    let marker = MediaKeyGrantMarker(directory: temporaryDirectory())
    marker.record()
    try "sentinel".write(to: marker.fileURL, atomically: true, encoding: .utf8)
    let first = try String(contentsOf: marker.fileURL, encoding: .utf8)
    marker.record()
    let second = try String(contentsOf: marker.fileURL, encoding: .utf8)
    #expect(first == second)
  }

  /// A marker that cannot be written leaves the launch prompt suppressed, which
  /// is the safe direction, so the failure must be silent rather than fatal.
  @Test func recordingIntoAnUnwritableDirectoryDoesNotThrow() {
    let marker = MediaKeyGrantMarker(directory: URL(fileURLWithPath: "/dev/null/candela", isDirectory: true))
    marker.record()
    #expect(!marker.exists)
  }

  /// The only enforcement of the rule the file's own comment states: a timestamp
  /// and nothing else. Round-tripped rather than only parsed, so trailing content
  /// a lenient parser would skip past fails this too.
  @Test func theMarkerBodyIsATimestampAndNothingElse() throws {
    let marker = MediaKeyGrantMarker(directory: temporaryDirectory())
    marker.record()
    let body = try String(contentsOf: marker.fileURL, encoding: .utf8)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let parsed = try #require(formatter.date(from: body))
    #expect(formatter.string(from: parsed) == body)
  }

  /// Pinned so a later move of either one cannot silently move the other: both
  /// are machine-scoped state under the app's own Application Support folder.
  @Test func theMarkerLivesBesideTheCheckupStore() {
    #expect(MediaKeyGrantMarker.defaultDirectory() == CheckupStore.defaultDirectory().deletingLastPathComponent())
  }
}
