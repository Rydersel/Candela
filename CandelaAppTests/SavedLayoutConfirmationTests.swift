import CandelaKit
import CoreGraphics
import Foundation
import Testing

@Suite("Remember a confirmed display setup", .timeLimit(.minutes(1)))
@MainActor
struct SavedLayoutConfirmationTests {
  @Test func keepingTheFirstArrangementEnablesAndSavesItsRotations() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      #expect(!coordinator.isRestoringLayout)
      coordinator.apply(rig.currentArrangement().makingMain(2))
      // A reconnect while the preview is up must not save or restore it.
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      #expect(coordinator.remembersThisLayout)
      #expect(!store.isRestoreEnabled)
      #expect(await coordinator.confirm(preview) == .committed)
      #expect(store.isRestoreEnabled)
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      #expect(saved.entries.first { $0.identity == rig.currentArrangement().tile(2)?.identity.key }?.rotation == .twoSeventy)
    }
  }

  @Test func revertingDoesNotCommitTheSuggestedRememberChoice() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      #expect(await coordinator.revert(preview) == .reverted)
      #expect(!store.isRestoreEnabled)
      #expect(store.remembersConfirmedLayout)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
      _ = await coordinator.confirm(preview)
      #expect(!store.isRestoreEnabled)
    }
  }

  @Test func anExplicitOptOutRemainsUncheckedAndIsNotOverriddenByKeep() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.setRestoringLayout(false)
      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      #expect(!coordinator.remembersThisLayout)
      #expect(await coordinator.confirm(preview) == .committed)
      #expect(!store.isRestoreEnabled)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
    }
  }

  @Test func uncheckingTheConfirmationChoicePersistsTheOptOut() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      coordinator.remembersThisLayout = false
      #expect(await coordinator.confirm(preview) == .committed)
      #expect(!store.remembersConfirmedLayout)
      #expect(!store.isRestoreEnabled)
    }
  }

  @Test func keepingANewRotationRefreshesAnAlreadyRememberedSetup() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      rig.angle = .ninety
      coordinator.rotationWasConfirmed()
      await coordinator.restoreSavedArrangement()
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      #expect(saved.entries.first { $0.identity == rig.currentArrangement().tile(2)?.identity.key }?.rotation == .ninety)
    }
  }

  @Test func enablingRememberDuringARotationPreviewCannotSaveTheRejectedAngle() async throws {
    try await withCoordinator { coordinator, store, rig, gate in
      let rotation = RotationCoordinator(gate: gate, topologyStore: MirrorTopologyStore(), configurator: rig)
      let presenter = RotationReadyPresenter()
      rotation.confirmation = presenter
      rotation.didConfirmRotation = { coordinator.rotationWasConfirmed() }
      rotation.rotate(2, to: .ninety)
      for await _ in presenter.ready { break }
      let preview = try #require(rotation.preview)
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      #expect(!store.isRestoreEnabled)
      #expect(coordinator.blockedBy == .rotation)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
      #expect(await rotation.revert(preview) == .reverted)
      #expect(rig.angle == .twoSeventy)
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      #expect(saved.entries.first { $0.identity == rig.currentArrangement().tile(2)?.identity.key }?.rotation == .twoSeventy)
    }
  }

  @Test func rotationKeepCapturesBeforeReturningAndDuplicateAnswersDoNotSaveAgain() async throws {
    try await withCoordinator { coordinator, store, rig, gate in
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      let rotation = RotationCoordinator(gate: gate, topologyStore: MirrorTopologyStore(), configurator: rig)
      let presenter = RotationReadyPresenter()
      rotation.confirmation = presenter
      var captures = 0
      rotation.didConfirmRotation = {
        captures += 1
        coordinator.rotationWasConfirmed()
      }
      rotation.rotate(2, to: .ninety)
      for await _ in presenter.ready { break }
      let preview = try #require(rotation.preview)
      #expect(await rotation.confirm(preview) == .committed)
      #expect(captures == 1)
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      #expect(saved.entries.first { $0.identity == rig.currentArrangement().tile(2)?.identity.key }?.rotation == .ninety)
      rig.angle = .twoSeventy
      _ = await rotation.confirm(preview)
      #expect(captures == 1)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == saved)
    }
  }

  @Test func duplicateArrangementKeepDoesNotCaptureALaterRotation() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      #expect(await coordinator.confirm(preview) == .committed)
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      rig.angle = .ninety
      _ = await coordinator.confirm(preview)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == saved)
    }
  }

  @Test func switchingOffCancelsAnEarlierQueuedEnable() async throws {
    try await withCoordinator { coordinator, store, rig, gate in
      coordinator.setRestoringLayout(true)
      coordinator.setRestoringLayout(false)
      await coordinator.restoreSavedArrangement()
      #expect(!store.isRestoreEnabled)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
      #expect(await gate.holder == nil)
    }
  }

  @Test func switchingOffWhileKeepCommitsPreservesTheExplicitOptOut() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)
      rig.beforeCommit = {
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor in
          coordinator.setRestoringLayout(false)
          finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 5) == .success)
      }
      #expect(await coordinator.confirm(preview) == .committed)
      #expect(!store.isRestoreEnabled)
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
    }
  }

  @Test func savingFromTheStaleNoticeRecordsTheLayoutOnScreenAndClearsTheNotice() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) != nil)

      let resized = try #require(rig.currentArrangement().tile(2)?.identity.key)
      await reconnect(coordinator, rig, showing: Self.widening(rig.currentArrangement(), 2, by: 200))
      #expect(coordinator.restoreNotice == .savedForDifferentGeometry([resized]))

      coordinator.saveCurrentLayout()
      // The queue is what the click hands the work to, so drain it before reading.
      await coordinator.restoreSavedArrangement()
      #expect(coordinator.restoreNotice == nil)
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))
      #expect(saved.entries.count == 2)
      #expect(saved.entries.first { $0.identity == resized }?.width == 1000)

      // The point of the save: the next reconnect restores this layout instead of
      // raising the same notice again.
      await reconnect(coordinator, rig, showing: rig.currentArrangement())
      #expect(coordinator.restoreNotice == nil)
    }
  }

  @Test func savingDoesNothingWhileTheRememberSettingIsOff() async throws {
    try await withCoordinator { coordinator, store, rig, _ in
      coordinator.saveCurrentLayout()
      await coordinator.restoreSavedArrangement()
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == nil)
      // A save must not turn the setting on as a side effect.
      #expect(!store.isRestoreEnabled)
      // A no-op reports nothing, so no card is raised over work that would do nothing.
      #expect(coordinator.blockedBy == nil)
    }
  }

  @Test func savingDuringAnOutstandingPreviewSavesNothingAndSaysWhoBlockedIt() async throws {
    try await withCoordinator { coordinator, store, rig, gate in
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))

      let rotation = RotationCoordinator(gate: gate, topologyStore: MirrorTopologyStore(), configurator: rig)
      let presenter = RotationReadyPresenter()
      rotation.confirmation = presenter
      rotation.rotate(2, to: .ninety)
      for await _ in presenter.ready { break }
      let preview = try #require(rotation.preview)

      coordinator.saveCurrentLayout()
      await coordinator.restoreSavedArrangement()
      #expect(coordinator.saveRefusedBy == .rotation)
      // Off the report card, whose one button would clear the notice the save
      // exists to answer.
      #expect(coordinator.blockedBy == nil)
      // Not merely "no new record": the stored layout is the one saved before.
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == saved)
      #expect(await rotation.revert(preview) == .reverted)
    }
  }

  /// The gate cannot cover this branch: a claim by the claimant already holding the
  /// gate is GRANTED, so an outstanding ARRANGEMENT preview gets past `gate.claim`
  /// and only the preview guard stops the save.
  @Test func savingDuringAnOutstandingArrangementPreviewLeavesTheRecordAndThePreviewAlone() async throws {
    try await withCoordinator { coordinator, store, rig, gate in
      coordinator.setRestoringLayout(true)
      await coordinator.restoreSavedArrangement()
      let saved = try #require(store.savedArrangement(for: TopologySignature(rig.currentArrangement())))

      coordinator.apply(rig.currentArrangement().makingMain(2))
      await coordinator.restoreSavedArrangement()
      let preview = try #require(coordinator.preview)

      coordinator.saveCurrentLayout()
      await coordinator.restoreSavedArrangement()

      #expect(coordinator.saveRefusedBy == .arrangement)
      // Not the report card: its one button would clear the notice with nothing
      // saved.
      #expect(coordinator.blockedBy == nil)
      // Equal, not merely present: the mid-preview layout did not overwrite the
      // one the user approved.
      #expect(store.savedArrangement(for: TopologySignature(rig.currentArrangement())) == saved)
      // The preview still stands and still holds the gate: the refusal cost the
      // user nothing.
      #expect(coordinator.preview?.value == preview.value)
      #expect(await gate.holder == .arrangement)
      #expect(await coordinator.revert(preview) == .reverted)
    }
  }

  /// A reconnect in the two steps the bookkeeping needs: a sample taken while the
  /// display is gone makes its return an arrival, and the restore pass acts on it.
  private func reconnect(
    _ coordinator: ArrangementCoordinator, _ rig: ConfirmationLayoutRig,
    showing layout: DisplayArrangement
  ) async {
    let present = rig.currentArrangement()
    rig.layout = DisplayArrangement(tiles: present.tiles.filter { $0.id != 2 })
    coordinator.displaysChanged()
    rig.layout = layout
    await coordinator.restoreSavedArrangement()
  }

  /// The same display set at a different size, which the saved origins no longer
  /// describe.
  private static func widening(
    _ layout: DisplayArrangement, _ displayID: CGDirectDisplayID, by extra: Int
  ) -> DisplayArrangement {
    DisplayArrangement(tiles: layout.tiles.map { tile in
      guard tile.id == displayID else { return tile }
      return ArrangementTile(
        id: tile.id, identity: tile.identity, name: tile.name,
        rect: DisplayRect(x: tile.rect.x, y: tile.rect.y,
                          width: tile.rect.width + extra, height: tile.rect.height),
        mirroredIDs: tile.mirroredIDs)
    })
  }

  private func withCoordinator(
    _ body: (ArrangementCoordinator, ArrangementPersistence, ConfirmationLayoutRig, DisplayReconfigurationGate) async throws -> Void
  ) async throws {
    let suite = "test.saved-layout.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ArrangementPersistence(defaults: defaults)
    let rig = ConfirmationLayoutRig()
    let gate = DisplayReconfigurationGate()
    let coordinator = ArrangementCoordinator(gate: gate,
      configurator: rig, persistence: store, rotationConfigurator: rig)
    try await body(coordinator, store, rig, gate)
  }
}

/// Replaces only display I/O; the actual coordinator, queue and preview session run.
private final class ConfirmationLayoutRig: DisplayArrangementConfiguring,
  DisplayConfiguring, @unchecked Sendable {
  private let lock = NSLock()
  // Installed before an operation starts; the test never mutates it in flight.
  var beforeCommit: (@Sendable () -> Void)?
  private var storedLayout = DisplayArrangement(tiles: [
    tile(1, .init(x: 0, y: 0, width: 1000, height: 800)),
    tile(2, .init(x: 1000, y: 0, width: 800, height: 1200)),
  ])
  var layout: DisplayArrangement {
    get { lock.withLock { storedLayout } }
    set { lock.withLock { storedLayout = newValue } }
  }
  private var storedAngle: DisplayRotation = .twoSeventy
  var angle: DisplayRotation {
    get { lock.withLock { storedAngle } }
    set { lock.withLock { storedAngle = newValue } }
  }
  var canRotate: Bool { true }
  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? {
    displayID == 2 ? angle : .standard
  }
  func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {
    angle = rotation
  }
  func displays() -> [ConfiguredDisplay] { currentTopology().displays }
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { [] }
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? { nil }
  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? { nil }
  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
    Issue.record("Unexpected mode change")
  }
  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {
    Issue.record("Unexpected mirroring change")
  }
  var revealsHiddenModes: Bool { false }
  var guardsWireTiming: Bool { true }
  func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int { 0 }
  func currentArrangement() -> DisplayArrangement { layout }
  func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    let layout = currentArrangement()
    return (layout.tiles.map {
      .init(id: $0.id, identity: $0.identity, name: $0.name, isBuiltIn: false)
    }, layout)
  }
  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    if scope == .permanent { beforeCommit?() }
    return lock.withLock { storedLayout = plan.arrangement; return storedLayout }
  }
  private static func tile(_ id: CGDirectDisplayID, _ rect: DisplayRect) -> ArrangementTile {
    .init(id: id, identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
          name: "Display \(id)", rect: rect, mirroredIDs: [])
  }
}

@MainActor
private final class RotationReadyPresenter: RotationConfirmationPresenting {
  let ready: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (ready, continuation) = AsyncStream.makeStream() }
  func presentRotationConfirmation(_ content: RotationConfirmationContent) {
    if case .preview = content { continuation.yield(()) }
  }
  func dismissRotationConfirmation() {}
}
