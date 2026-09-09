import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Saved layout rotations")
struct SavedLayoutRotationTests {
  @Test func firstConfirmedArrangementIsRememberedWithoutEnablingOnLaunch() throws {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    #expect(!store.isRestoreEnabled)
    #expect(store.remembersConfirmedLayout)
    store.saveConfirmed(ArrangementFixtures.pair, rotations: [2: .twoSeventy])
    #expect(store.isRestoreEnabled)
    let saved = try #require(store.savedArrangement(for: TopologySignature(ArrangementFixtures.pair)))
    #expect(saved.entries.first { $0.identity == ArrangementFixtures.pair.tile(2)?.identity.key }?.rotation == .twoSeventy)
  }

  @Test func existingOptOutSurvivesAConfirmedArrangement() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.setRestoreEnabled(false)
    #expect(!store.remembersConfirmedLayout)
    store.saveConfirmed(ArrangementFixtures.pair)
    #expect(!store.isRestoreEnabled)
    #expect(store.savedArrangement(for: TopologySignature(ArrangementFixtures.pair)) == nil)
  }

  @Test func uncheckingRememberAtConfirmationIsAnExplicitOptOut() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.saveConfirmed(ArrangementFixtures.pair, remember: false)
    #expect(!store.isRestoreEnabled)
    #expect(!store.remembersConfirmedLayout)
    store.saveConfirmed(ArrangementFixtures.pair)
    #expect(store.savedArrangement(for: TopologySignature(ArrangementFixtures.pair)) == nil)
  }

  @Test func anEmptyCaptureDoesNotEnableRestoration() {
    let store = ArrangementPersistence(defaults: InMemoryDefaults())
    store.saveConfirmed(DisplayArrangement(tiles: []))
    #expect(!store.isRestoreEnabled)
    #expect(store.remembersConfirmedLayout)
  }
  @Test func savedRotationSurvivesDecodingAndReencoding() throws {
    let data = Data(#"{"version":2,"entries":[{"identity":"dell","x":0,"y":0,"width":1440,"height":2560,"rotation":270}]}"#.utf8)
    let saved = try JSONDecoder().decode(SavedArrangement.self, from: data)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
    let entries = try #require(encoded["entries"] as? [[String: Any]])
    #expect(entries.first?["rotation"] as? Int == 270)
  }

  @Test func invalidStoredRotationIsRejectedInsteadOfSilentlyDiscarded() {
    let data = Data(#"{"version":2,"entries":[{"identity":"dell","x":0,"y":0,"width":1440,"height":2560,"rotation":45}]}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SavedArrangement.self, from: data)
    }
  }

  @Test func legacyLayoutDoesNotInventAStandardRotation() throws {
    let data = Data(#"{"version":1,"entries":[{"identity":"dell","x":0,"y":0,"width":1440,"height":2560}]}"#.utf8)
    let saved = try JSONDecoder().decode(SavedArrangement.self, from: data)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
    let entries = try #require(encoded["entries"] as? [[String: Any]])
    #expect(entries.first?["rotation"] == nil)
  }
}
