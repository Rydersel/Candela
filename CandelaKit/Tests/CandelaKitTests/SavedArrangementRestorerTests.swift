import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Confined to one restore actor at a time; tests inspect it only after awaiting
/// completion. The fake models rotation changing geometry and moving the desktop.
private final class LayoutRig: DisplayArrangementConfiguring, DisplayRotationConfiguring,
  @unchecked Sendable {
  var layout: DisplayArrangement
  var angles: [CGDirectDisplayID: DisplayRotation] = [1: .standard, 9: .standard]
  var events: [String] = []
  var canRotate = true
  var failRotation = false
  var ignoreRotation = false
  var departAfterRotation = false
  var disableAfterRotation = false
  var enabled = true
  var wroteOnMain = false
  var extraOnlineDisplay: ConfiguredDisplay?

  init() {
    layout = DisplayArrangement(tiles: [
      Self.tile(1, key: 1, .init(x: 0, y: 0, width: 1000, height: 800)),
      Self.tile(9, key: 2, .init(x: 1000, y: 0, width: 1200, height: 800)),
    ])
  }

  static func tile(_ id: CGDirectDisplayID, key: UInt32, _ rect: DisplayRect) -> ArrangementTile {
    .init(id: id, identity: .init(vendor: key, model: key, serial: key, isBuiltIn: false),
          name: "Display \(key)", rect: rect, mirroredIDs: [])
  }

  var saved: SavedArrangement {
    // The physical display saved as ID2 has returned as ID9.
    SavedArrangement(DisplayArrangement(tiles: [
      Self.tile(1, key: 1, .init(x: 0, y: 0, width: 1000, height: 800)),
      Self.tile(2, key: 2, .init(x: 0, y: 800, width: 800, height: 1200)),
    ]), rotations: [1: .standard, 2: .twoSeventy])
  }

  func currentArrangement() -> DisplayArrangement { layout }
  func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    var displays = layout.tiles.map {
      ConfiguredDisplay(id: $0.id, identity: $0.identity, name: $0.name, isBuiltIn: false)
    }
    if let extraOnlineDisplay { displays.append(extraOnlineDisplay) }
    return (displays, layout)
  }
  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { angles[displayID] }
  func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {
    wroteOnMain = wroteOnMain || Thread.isMainThread
    events.append("rotate:\(displayID):\(rotation.rawValue)")
    if failRotation { throw DisplayConfigError(cgErrorCode: 1001) }
    if ignoreRotation { return }
    let swap = angles[displayID]?.swapsAxes != rotation.swapsAxes
    angles[displayID] = rotation
    layout = DisplayArrangement(tiles: layout.tiles.compactMap { tile in
      if departAfterRotation && tile.id == 1 { return nil }
      guard tile.id == displayID else { return tile }
      return .init(id: tile.id, identity: tile.identity, name: tile.name,
                   rect: .init(x: 1000, y: 0,
                               width: swap ? tile.rect.height : tile.rect.width,
                               height: swap ? tile.rect.width : tile.rect.height), mirroredIDs: [])
    })
    if disableAfterRotation { enabled = false }
  }
  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    wroteOnMain = wroteOnMain || Thread.isMainThread
    events.append("layout")
    #expect(scope == .permanent)
    layout = plan.arrangement
    return layout
  }
}

@Suite("Restore rotation before saved positions")
struct SavedArrangementRestorerTests {
  @Test @MainActor func rotatesTheReassignedDisplayThenRestoresFreshGeometryOffMainActor() async {
    let rig = LayoutRig()
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(result.notice == nil)
    #expect(rig.events == ["rotate:9:270", "layout"])
    #expect(rig.angles[9] == .twoSeventy)
    #expect(rig.layout.tile(9)?.rect == .init(x: 0, y: 800, width: 800, height: 1200))
    #expect(!rig.wroteOnMain)
  }

  @Test func rotationFailureDoesNotApplyPositionsToTheWrongFootprint() async {
    let rig = LayoutRig()
    rig.failRotation = true
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(result.notice == .failed(.init(cgErrorCode: 1001)))
    #expect(rig.events == ["rotate:9:270"])
  }

  @Test func aSuccessfulReturnWithoutTheRequestedAngleIsNotSuccess() async {
    let rig = LayoutRig()
    rig.ignoreRotation = true
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(result.notice != nil)
    #expect(rig.events == ["rotate:9:270"])
  }

  @Test func optOutAndNonArrivalNeverTouchDisplays() async {
    let rig = LayoutRig()
    let restorer = SavedArrangementRestorer(arrangements: rig, rotations: rig)
    _ = await restorer.restore(rig.saved, arrivals: [1, 9], isEnabled: { false })
    _ = await restorer.restore(rig.saved, arrivals: [])
    #expect(rig.events.isEmpty)
  }

  @Test func anOptOutDuringRotationStopsBeforeRepositioning() async {
    let rig = LayoutRig()
    rig.disableAfterRotation = true
    _ = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9], isEnabled: { rig.enabled })
    #expect(rig.events == ["rotate:9:270"])
  }

  @Test func aDepartureDuringRotationDefersWithoutApplyingOldPositions() async {
    let rig = LayoutRig()
    rig.departAfterRotation = true
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(result.isDeferred)
    #expect(rig.events == ["rotate:9:270"])
  }

  @Test func changedResolutionIsNotMistakenForChangedRotation() async {
    let rig = LayoutRig()
    rig.layout = .init(tiles: [rig.layout.tile(1)!, LayoutRig.tile(9, key: 2,
      .init(x: 1000, y: 0, width: 1920, height: 1080))])
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(result.notice == .savedForDifferentGeometry([rig.layout.tile(9)!.identity.key]))
    #expect(rig.events.isEmpty)
  }

  @Test func anIncompleteDisplayReadWaitsBeforeAnyRotation() async {
    let rig = LayoutRig()
    rig.extraOnlineDisplay = .init(id: 20,
      identity: .init(vendor: 20, model: 20, serial: 20, isBuiltIn: false),
      name: "Unreadable display", isBuiltIn: false)
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9, 20])
    #expect(result.isDeferred)
    #expect(rig.events.isEmpty)
  }

  @Test func aLegacyLayoutRestoresPositionsWithoutTouchingAngles() async {
    let rig = LayoutRig()
    let saved = SavedArrangement(rig.layout.makingMain(9))
    let result = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(saved, arrivals: [1, 9])
    #expect(result.notice == nil)
    #expect(rig.events == ["layout"])
    #expect(rig.layout.mainDisplayID == 9)
  }

  @Test func oppositePortraitAnglesAreDifferentDespiteMatchingSizes() async {
    let rig = LayoutRig()
    rig.angles[9] = .ninety
    rig.layout = .init(tiles: [rig.layout.tile(1)!, LayoutRig.tile(9, key: 2,
      .init(x: 0, y: 800, width: 800, height: 1200))])
    _ = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(rig.saved, arrivals: [1, 9])
    #expect(rig.angles[9] == .twoSeventy)
    #expect(rig.events == ["rotate:9:270", "layout"])
  }

  @Test func anAlreadyCorrectSetupIsNotReconfigured() async {
    let rig = LayoutRig()
    let saved = SavedArrangement(rig.layout, rotations: rig.angles)
    _ = await SavedArrangementRestorer(arrangements: rig, rotations: rig)
      .restore(saved, arrivals: [1, 9])
    #expect(rig.events.isEmpty)
  }
}
