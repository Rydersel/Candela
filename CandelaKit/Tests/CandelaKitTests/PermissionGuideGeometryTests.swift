import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Permission guide geometry")
struct PermissionGuideGeometryTests {
  private func entry(pid: Int, layer: Int, width: Int, asNumber: Bool = false) -> [String: Any] {
    let bounds: [String: Any] = ["X": -1362, "Y": 25, "Width": width, "Height": 1032]
    return [
      kCGWindowOwnerPID as String: asNumber ? NSNumber(value: pid) : pid,
      kCGWindowLayer as String: asNumber ? NSNumber(value: layer) : layer,
      kCGWindowBounds as String: asNumber ? (bounds as NSDictionary) : bounds,
    ]
  }

  @Test func findsSettingsWindowByPIDAtLayerZero() {
    let list = [entry(pid: 7, layer: 0, width: 900), entry(pid: 42, layer: 0, width: 757)]
    let bounds = PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42)
    #expect(bounds == CGRect(x: -1362, y: 25, width: 757, height: 1032))
  }

  @Test func readsNSNumberValuesAndNSDictionaryBounds() {
    let list = [entry(pid: 42, layer: 0, width: 757, asNumber: true)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42)?.width == 757)
  }

  @Test func ignoresOtherPIDsAndNonZeroLayers() {
    let list = [entry(pid: 7, layer: 0, width: 757), entry(pid: 42, layer: 25, width: 757)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42) == nil)
  }

  @Test func noSettingsPIDMeansNoWindow() {
    let list = [entry(pid: 42, layer: 0, width: 757)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: nil) == nil)
  }

  @Test func ignoresSlivers() {
    let list = [entry(pid: 42, layer: 0, width: 120)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42) == nil)
  }

  @Test func skipsMalformedEntries() {
    let list: [[String: Any]] = [[kCGWindowOwnerPID as String: 42], entry(pid: 42, layer: 0, width: 757)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42) != nil)
  }

  /// A sheet is its own layer-0 window of the same process, listed in front of
  /// the window it hangs from; docking to it would put the guide mid-window.
  @Test func ignoresASheetInsideTheSettingsWindow() {
    let sheet: [String: Any] = [
      kCGWindowOwnerPID as String: 42,
      kCGWindowLayer as String: 0,
      kCGWindowBounds as String: ["X": -1200, "Y": 77, "Width": 480, "Height": 400],
    ]
    let list = [sheet, entry(pid: 42, layer: 0, width: 757)]
    let bounds = PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42)
    #expect(bounds == CGRect(x: -1362, y: 25, width: 757, height: 1032))
  }

  @Test func identicalBoundsDoNotCancelEachOther() {
    let list = [entry(pid: 42, layer: 0, width: 757), entry(pid: 42, layer: 0, width: 757)]
    #expect(PermissionGuideGeometry.settingsWindowBounds(windowList: list, settingsPID: 42) != nil)
  }

  @Test func panelSitsOnTheListEdgesAtTheWindowBottom() {
    let f = PermissionGuideGeometry.panelFrame(
      settingsWindowCG: CGRect(x: -1362, y: 25, width: 757, height: 1032),
      mainScreenHeight: 1169, panelHeight: 92)
    let expectedX: CGFloat = -1362 + 269 - 8
    let expectedWidth: CGFloat = 757 - 269 - 21 + 16
    let expectedY: CGFloat = (1169 - (25 + 1032)) + 10
    #expect(f.minX == expectedX)
    #expect(f.width == expectedWidth)
    #expect(f.minY == expectedY)
    #expect(f.height == 92)
  }
}
