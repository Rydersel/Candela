import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Window observation")
struct WindowObservationTests {

  private let transform = PanelSpaceTransform(
    displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)

  private func window(
    _ id: UInt32, _ owner: String, _ rect: CGRect, layer: Int = 0, pid: Int32 = 100
  ) -> WindowSnapshot {
    WindowSnapshot(windowID: id, ownerPID: pid, ownerName: owner, bounds: rect, layer: layer)
  }

  // MARK: - Attribution

  @Test func aWindowClaimsTheCellsItCovers() {
    var observer = WindowObserver()
    let slack = window(1, "Slack", CGRect(x: 0, y: 0, width: 340, height: 1440))
    let result = observer.observe([slack], through: transform, at: Date())
    #expect(result.dominantOwnerByCell[0] == "Slack")
    #expect(result.dominantOwnerByCell[PanelGrid.cols - 1] == nil)
  }

  @Test func theLargerCoverageWinsAContestedCell() {
    var observer = WindowObserver()
    let big = window(1, "Xcode", CGRect(x: 0, y: 0, width: 3440, height: 1440))
    let sliver = window(2, "Notes", CGRect(x: 0, y: 0, width: 4, height: 4))
    let result = observer.observe([big, sliver], through: transform, at: Date())
    #expect(result.dominantOwnerByCell[0] == "Xcode")
  }

  @Test func anEmptySnapshotClaimsNothing() {
    var observer = WindowObserver()
    let result = observer.observe([], through: transform, at: Date())
    #expect(result.dominantOwnerByCell.count == PanelGrid.cellCount)
    #expect(result.stationaryByCell.count == PanelGrid.cellCount)
    #expect(result.dominantOwnerByCell.allSatisfy { $0 == nil })
    #expect(result.stationaryByCell.allSatisfy { $0 == false })
    #expect(result.fullScreenOwner == nil)
    #expect(result.stationarySecondsByWindowID.isEmpty)
  }

  /// A display reporting zero size mid-reconfiguration must not attribute
  /// anything, rather than dividing by it.
  @Test func aDegenerateDisplayAttributesNothing() {
    var observer = WindowObserver()
    let degenerate = PanelSpaceTransform(displaySize: .zero, rotation: .standard)
    let result = observer.observe(
      [window(1, "Slack", CGRect(x: 0, y: 0, width: 400, height: 400))],
      through: degenerate, at: Date())
    #expect(result.dominantOwnerByCell.allSatisfy { $0 == nil })
    #expect(result.fullScreenOwner == nil)
  }

  // MARK: - Stationary ageing

  @Test func aStationaryWindowAgesPastTheThreshold() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    let terminal = window(1, "Terminal", CGRect(x: 0, y: 0, width: 800, height: 600))
    _ = observer.observe([terminal], through: transform, at: start)
    let later = start.addingTimeInterval(WindowObserver.stationaryThresholdSeconds + 1)
    let result = observer.observe([terminal], through: transform, at: later)
    #expect(result.stationarySecondsByWindowID[1]! > WindowObserver.stationaryThresholdSeconds)
    #expect(result.stationaryByCell[0] == true)
  }

  @Test func aFirstSightingIsNotYetStationary() {
    var observer = WindowObserver()
    let result = observer.observe(
      [window(1, "Terminal", CGRect(x: 0, y: 0, width: 800, height: 600))],
      through: transform, at: Date(timeIntervalSince1970: 0))
    #expect(result.stationarySecondsByWindowID[1] == 0)
    #expect(result.stationaryByCell[0] == false)
  }

  @Test func movingAWindowResetsItsStationaryAge() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    _ = observer.observe(
      [window(1, "Terminal", CGRect(x: 0, y: 0, width: 800, height: 600))],
      through: transform, at: start)
    let later = start.addingTimeInterval(600)
    let moved = window(1, "Terminal", CGRect(x: 40, y: 0, width: 800, height: 600))
    let result = observer.observe([moved], through: transform, at: later)
    #expect(result.stationarySecondsByWindowID[1] == 0)
    #expect(result.stationaryByCell[0] == false)
  }

  /// The counter-example the spec names: a video player holds a fixed rect
  /// while every pixel under it changes. Geometry alone WILL call it
  /// stationary — that is correct behaviour for this type, and the reason
  /// OC18 makes it a prior rather than a verdict. Pinned so nobody "fixes" it.
  @Test func geometryCallsAStationaryVideoPlayerStationary() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    let player = window(1, "IINA", CGRect(x: 100, y: 100, width: 1920, height: 1080))
    _ = observer.observe([player], through: transform, at: start)
    let result = observer.observe(
      [player], through: transform, at: start.addingTimeInterval(3600))
    #expect(result.stationarySecondsByWindowID[1]! > 3000)
  }

  @Test func aClosedWindowDropsOutOfTheAgeTable() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    _ = observer.observe(
      [window(1, "Notes", CGRect(x: 0, y: 0, width: 400, height: 400))],
      through: transform, at: start)
    let result = observer.observe([], through: transform, at: start.addingTimeInterval(60))
    #expect(result.stationarySecondsByWindowID[1] == nil)
  }

  /// The observable half of "state for absent windows is dropped": a reused
  /// window ID must not inherit the age of the window that held it. Nothing
  /// else can see the table, so this is what pins the unbounded-growth rule.
  @Test func aReappearingWindowIDStartsFromZero() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
    _ = observer.observe([window(1, "Notes", rect)], through: transform, at: start)
    _ = observer.observe([], through: transform, at: start.addingTimeInterval(60))
    let result = observer.observe(
      [window(1, "Notes", rect)], through: transform, at: start.addingTimeInterval(1000))
    #expect(result.stationarySecondsByWindowID[1] == 0)
  }

  /// Non-overlapping windows age independently; one moving must not disturb
  /// the other's clock.
  @Test func windowsAgeIndependently() {
    var observer = WindowObserver()
    let start = Date(timeIntervalSince1970: 0)
    let still = window(1, "Terminal", CGRect(x: 0, y: 0, width: 400, height: 400))
    _ = observer.observe(
      [still, window(2, "Notes", CGRect(x: 2000, y: 0, width: 400, height: 400))],
      through: transform, at: start)
    let later = start.addingTimeInterval(600)
    let result = observer.observe(
      [still, window(2, "Notes", CGRect(x: 2100, y: 0, width: 400, height: 400))],
      through: transform, at: later)
    #expect(result.stationarySecondsByWindowID[1] == 600)
    #expect(result.stationarySecondsByWindowID[2] == 0)
  }

  // MARK: - Full screen

  @Test func aFullScreenWindowIsIdentifiedByBounds() {
    var observer = WindowObserver()
    let full = window(1, "IINA", CGRect(x: 0, y: 0, width: 3440, height: 1440))
    let result = observer.observe([full], through: transform, at: Date())
    #expect(result.fullScreenOwner == "IINA")
  }

  @Test func anAlmostFullScreenWindowIsNotFullScreen() {
    var observer = WindowObserver()
    let nearly = window(1, "Safari", CGRect(x: 0, y: 25, width: 3440, height: 1415))
    let result = observer.observe([nearly], through: transform, at: Date())
    #expect(result.fullScreenOwner == nil)
  }

  /// A screen-filling window above the normal layer is chrome — a shade, a
  /// screen saver, another tool's overlay — not an app running full screen.
  @Test func aScreenFillingWindowAboveTheNormalLayerIsNotFullScreen() {
    var observer = WindowObserver()
    let overlay = window(
      1, "SomeOverlay", CGRect(x: 0, y: 0, width: 3440, height: 1440), layer: 25)
    let result = observer.observe([overlay], through: transform, at: Date())
    #expect(result.fullScreenOwner == nil)
  }

  // MARK: - Rotation

  @Test func observationMapsThroughRotation() {
    var observer = WindowObserver()
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    // Under 270°, top-left in DISPLAY space is the panel's TOP-RIGHT. See the
    // rotation-convention note in PanelSpaceTransform — the direction is
    // reasoned from CGDisplayRotation's counter-clockwise sign and is NOT yet
    // hardware-verified.
    let w = window(1, "Slack", CGRect(x: 0, y: 0, width: 200, height: 200))
    let result = observer.observe([w], through: rotated, at: Date())
    #expect(result.dominantOwnerByCell[PanelGrid.cols - 1] == "Slack")
    #expect(result.dominantOwnerByCell[(PanelGrid.rows - 1) * PanelGrid.cols] == nil)
  }

  @Test func aRotatedFullScreenWindowIsStillFullScreen() {
    var observer = WindowObserver()
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    let full = window(1, "IINA", CGRect(x: 0, y: 0, width: 2160, height: 3840))
    let result = observer.observe([full], through: rotated, at: Date())
    #expect(result.fullScreenOwner == "IINA")
  }
}
