import Foundation
import Testing
@testable import CandelaKit

@Suite("Media-key grant marker")
struct MediaKeyGrantMarkerTests {
  private func withDirectory(_ body: (URL) throws -> Void) rethrows {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func marker(_ directory: URL, machine: String? = "mac-a") -> MediaKeyGrantMarker {
    MediaKeyGrantMarker(directory: directory, machineIdentifier: machine)
  }

  @Test func aFreshMachineHasNoMarker() {
    withDirectory { #expect(!marker($0).exists) }
  }

  @Test func recordingPersistsAGrantAcrossInstancesOnTheSameMachine() {
    withDirectory { directory in
      marker(directory).record()
      #expect(marker(directory).exists)
    }
  }

  @Test func aMigratedMarkerDoesNotProveAGrantOnTheDestinationMachine() {
    withDirectory { directory in
      marker(directory, machine: "mac-a").record()
      #expect(marker(directory, machine: "mac-a").exists)
      #expect(!marker(directory, machine: "mac-b").exists)
    }
  }

  @Test func aGrantObservedOnTheDestinationReplacesTheMigratedMarker() {
    withDirectory { directory in
      marker(directory, machine: "mac-a").record()
      marker(directory, machine: "mac-b").record()
      #expect(marker(directory, machine: "mac-b").exists)
      #expect(!marker(directory, machine: "mac-a").exists)
    }
  }

  @Test func aLegacyTimestampRequiresANewGrantObservation() throws {
    try withDirectory { directory in
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let value = marker(directory)
      try "2026-09-10T12:00:00Z".write(to: value.fileURL, atomically: true, encoding: .utf8)
      #expect(!value.exists)
      value.record()
      #expect(marker(directory).exists)
    }
  }

  @Test(arguments: [nil, ""] as [String?])
  func anUnavailableMachineIdentityCannotAcceptOrRecordAGrant(machine: String?) throws {
    try withDirectory { directory in
      let unavailable = marker(directory, machine: machine)
      unavailable.record()
      #expect(!FileManager.default.fileExists(atPath: unavailable.fileURL.path))
      marker(directory).record()
      let before = try Data(contentsOf: unavailable.fileURL)
      #expect(!unavailable.exists)
      unavailable.record()
      #expect(try Data(contentsOf: unavailable.fileURL) == before)
    }
  }

  @Test func recordingAgainKeepsTheFirstObservation() throws {
    try withDirectory { directory in
      let value = marker(directory)
      value.record()
      let before = try Data(contentsOf: value.fileURL)
      value.record()
      #expect(try Data(contentsOf: value.fileURL) == before)
    }
  }

  @Test func anUnreadableOrCorruptMarkerDoesNotProveAGrant() throws {
    try withDirectory { directory in
      let value = marker(directory)
      try FileManager.default.createDirectory(at: value.fileURL, withIntermediateDirectories: true)
      #expect(!value.exists)
      value.record()
      #expect(!value.exists)
      try FileManager.default.removeItem(at: value.fileURL)
      try "corrupt".write(to: value.fileURL, atomically: true, encoding: .utf8)
      #expect(!value.exists)
    }
  }

  @Test func recordingIntoAnUnwritableDirectoryLeavesThePromptSuppressed() {
    let value = marker(URL(fileURLWithPath: "/dev/null/candela", isDirectory: true))
    value.record()
    #expect(!value.exists)
  }
}
