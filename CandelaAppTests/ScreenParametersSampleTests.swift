import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Testing

// Characterisation pins. Every test here passes against today's coordinators; they
// exist because the property holds by a mechanism nobody would guess from reading
// the registrations, and losing it would be silent.
//
// [MEASURED 2026-09-09, standalone Foundation binary and this bundle] an observer
// registered with `queue: .main` runs its block SYNCHRONOUSLY on the posting thread
// when the post comes from the main thread: `OperationQueue.current` is
// `OperationQueue.main` there, and `NotificationCenter` short-circuits when the
// target queue is already the current one. AppKit posts
// `didChangeScreenParametersNotification` on the main thread, so both `.main`
// coordinators below sample inside the post. `queue: nil`, which the two mirroring
// registrations use, gets the same delivery by documented contract.
//
// A late sample fails silently: an unplug and a replug inside one main-queue turn
// read as a display that never left, so the remembered resolution and the saved
// layout stay away. The control is one edit: delete the `center.post` line from
// each test and all four fail.

/// The screen-parameters sample is taken INSIDE AppKit's post, not on the far side
/// of a main-queue hop.
///
/// `DisplayArrivalTracker.noteObserved(live:)` is written for a set sampled at post
/// time: anything missing from it counts as departed, which is what makes the next
/// appearance an arrival. Sample it later and a replug within one main-queue turn
/// reads as a display that never left, so nothing is restored.
///
/// The counter tests run no `await` between the post and the assertion, so a read
/// that happened can only have happened inside the post.
@MainActor
@Suite("Screen-parameters sampling", .timeLimit(.minutes(1)))
struct ScreenParametersSampleTests {
  private static let panelID: CGDirectDisplayID = 12
  private static let native = DisplayMode(
    ioModeID: 1, logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true
  )
  private static let smaller = DisplayMode(
    ioModeID: 2, logicalWidth: 2560, logicalHeight: 1080,
    pixelWidth: 2560, pixelHeight: 1080, refreshHz: 175, isNative: false
  )

  @Test func theModeCoordinatorSamplesTheOnlineListInsideThePost() {
    let rig = Self.modeRig()
    defer { rig.forgetPrefs() }

    let before = rig.configurator.onlineListReads
    rig.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

    #expect(rig.configurator.onlineListReads == before + 1)
  }

  /// `currentTopology()` is this coordinator's online read: `displaysChanged` feeds
  /// `noteObserved(live:)` straight off `topology.displays`.
  @Test func theArrangementCoordinatorSamplesTheOnlineListInsideThePost() {
    let fixture = Self.layoutFixture()
    defer { fixture.forgetPrefs() }

    let before = fixture.rig.topologyReads
    fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

    #expect(fixture.rig.topologyReads == before + 1)
  }

  /// A replug compressed into one turn: the display leaves and is back before
  /// anything queued on the main actor runs. Only the sample taken during the post
  /// records the departure that makes the second pass an arrival.
  @Test func aReplugInsideOneMainQueueTurnStillRestoresTheRememberedMode() async throws {
    let rig = Self.modeRig()
    defer { rig.forgetPrefs() }
    rig.persistence.setEnabled(true, for: rig.identity)
    rig.persistence.store(Self.smaller.descriptor, for: rig.identity)

    await rig.modes.reapplyStoredModes()
    #expect(rig.world.applies.count == 1)

    rig.world.detach(Self.panelID)
    rig.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    rig.world.attach(
      Self.panel(rig.identity), modes: [Self.native, Self.smaller], current: Self.native,
      nativePixels: (width: 3440, height: 1440)
    )

    // This handler runs on the far side of a hop by design, so the pass it feeds has
    // to wait. Bounded rather than `Task.yield()`, which promises nothing about a
    // task the notification block created.
    try await Task.sleep(for: .milliseconds(50))
    await rig.modes.reapplyStoredModes()

    #expect(rig.world.applies.count == 2)
  }

  /// The layout half of the same replug. `TopologyArrivalTracker` also resets on a
  /// signature change, no help here: the set is identical before and after, so the
  /// sample is the only record that the display left.
  @Test func aReplugInsideOneMainQueueTurnStillRestoresTheSavedLayout() async {
    let fixture = Self.layoutFixture()
    defer { fixture.forgetPrefs() }
    let rig = fixture.rig
    let saved = rig.currentArrangement()
    fixture.store.setRestoreEnabled(true)
    fixture.store.save(saved)

    // Claims the launch arrival, so the second pass can only come from a departure.
    await fixture.coordinator.restoreSavedArrangement()

    let scrambled = saved.moving(2, to: DisplayPoint(x: -800, y: 0))
    rig.setLayout(DisplayArrangement(tiles: scrambled.tiles.filter { $0.id != 2 }))
    fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    rig.setLayout(scrambled)

    // No wait, unlike the mode half above: this coordinator's handler runs to
    // completion inside the post, and `restoreSavedArrangement` drains the queue
    // the handler enqueued on.
    await fixture.coordinator.restoreSavedArrangement()

    #expect(rig.currentArrangement() == saved)
  }

  // MARK: - Rigs

  /// Its own notification centre: a post on `.default` would reach every
  /// coordinator alive in the process, and Swift Testing runs suites in parallel.
  private struct ModeRig {
    let world: FakeDisplayWorld
    let configurator: FakeSynthesisDisplayConfigurator
    let modes: DisplayModeCoordinator
    let persistence: ModePersistence
    let identity: DisplayConfigIdentity
    let center: NotificationCenter
    let suiteName: String

    func forgetPrefs() {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
  }

  private static func panel(_ identity: DisplayConfigIdentity) -> ConfiguredDisplay {
    ConfiguredDisplay(id: panelID, identity: identity, name: "MAG341C", isBuiltIn: false)
  }

  private static func modeRig() -> ModeRig {
    let world = FakeDisplayWorld()
    let identity = DisplayConfigIdentity(vendor: 0x3669, model: 9, serial: 9, isBuiltIn: false)
    world.attach(
      panel(identity), modes: [native, smaller], current: native,
      nativePixels: (width: 3440, height: 1440)
    )
    let configurator = FakeSynthesisDisplayConfigurator(world)
    let suiteName = "app-tests-screen-parameters-\(UUID().uuidString)"
    let persistence = ModePersistence(defaults: UserDefaults(suiteName: suiteName)!)
    let center = NotificationCenter()
    let modes = DisplayModeCoordinator(
      gate: DisplayReconfigurationGate(),
      configurator: configurator,
      persistence: persistence,
      notificationCenter: center
    )
    return ModeRig(
      world: world, configurator: configurator, modes: modes, persistence: persistence,
      identity: identity, center: center, suiteName: suiteName
    )
  }

  private struct LayoutFixture {
    let rig: LayoutRig
    let coordinator: ArrangementCoordinator
    let store: ArrangementPersistence
    let center: NotificationCenter
    let suiteName: String

    func forgetPrefs() {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
  }

  private static func layoutFixture() -> LayoutFixture {
    let suiteName = "app-tests-screen-parameters-layout-\(UUID().uuidString)"
    let rig = LayoutRig()
    let center = NotificationCenter()
    let store = ArrangementPersistence(defaults: UserDefaults(suiteName: suiteName)!)
    let coordinator = ArrangementCoordinator(
      gate: DisplayReconfigurationGate(),
      configurator: rig,
      persistence: store,
      rotationConfigurator: rig,
      notificationCenter: center
    )
    return LayoutFixture(
      rig: rig, coordinator: coordinator, store: store, center: center, suiteName: suiteName
    )
  }
}

/// A settable layout, the topology derived from it, and a count of the topology
/// reads. Replaces only display I/O; the real coordinator, queue, preview session
/// and restorer run. `SavedLayoutConfirmationTests`' rig is private to that file.
///
/// `@unchecked Sendable`: every stored field is read and written only under `lock`,
/// so the notification block's thread and the test's own can touch it in either
/// order.
private final class LayoutRig: DisplayArrangementConfiguring, DisplayRotationConfiguring,
  @unchecked Sendable {
  private let lock = NSLock()
  private var layout = DisplayArrangement(tiles: [
    tile(1, .init(x: 0, y: 0, width: 1000, height: 800)),
    tile(2, .init(x: 1000, y: 0, width: 800, height: 1200)),
  ])
  private var _topologyReads = 0

  /// How many times the coordinator asked who is online. Counted on
  /// `currentTopology()`, not `currentArrangement()`: the set the arrival record is
  /// judged against comes off `topology.displays`.
  var topologyReads: Int { lock.withLock { _topologyReads } }

  func setLayout(_ layout: DisplayArrangement) {
    lock.withLock { self.layout = layout }
  }

  func currentArrangement() -> DisplayArrangement { lock.withLock { layout } }

  func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    let layout = lock.withLock {
      _topologyReads += 1
      return self.layout
    }
    return (layout.tiles.map {
      .init(id: $0.id, identity: $0.identity, name: $0.name, isBuiltIn: false)
    }, layout)
  }

  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    setLayout(plan.arrangement)
    return currentArrangement()
  }

  var canRotate: Bool { true }
  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { .standard }
  func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {
    Issue.record("Unexpected rotation change")
  }

  private static func tile(_ id: CGDirectDisplayID, _ rect: DisplayRect) -> ArrangementTile {
    .init(id: id, identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
          name: "Display \(id)", rect: rect, mirroredIDs: [])
  }
}
