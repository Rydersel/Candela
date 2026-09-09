import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Adaptive region protection")
struct AdaptiveRegionProtectionTests {
  private let start = Date(timeIntervalSince1970: 1_000)
  private let transform = PanelSpaceTransform(
    displaySize: CGSize(width: 2400, height: 1000), rotation: .standard)
  private let activity = AdaptiveRegionProtection.Activity(
    isFocusedDisplay: false, frontmostPID: 99, pointerPosition: nil)

  private func observation(window: UInt32 = 1, owner: Int32 = 7,
                           fullScreen: String? = nil) -> WindowObservation {
    WindowObservation(
      dominantOwnerByCell: Array(repeating: "Editor", count: 240),
      stationarySecondsByWindowID: [window: 600],
      stationaryByCell: Array(repeating: true, count: 240),
      fullScreenOwner: fullScreen,
      windowIDByCell: Array(repeating: window, count: 240),
      ownerPIDByCell: Array(repeating: owner, count: 240))
  }

  private func warmed(observation: WindowObservation? = nil) -> AdaptiveRegionProtection {
    var protection = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 300, by: 60) {
      protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                        through: transform, observation: observation ?? self.observation(),
                        at: start.addingTimeInterval(Double(second)))
    }
    return protection
  }

  private func mask(_ protection: AdaptiveRegionProtection, at second: Double = 300,
                    observation: WindowObservation? = nil,
                    exposure: ExposureMap = .empty,
                    activity: AdaptiveRegionProtection.Activity? = nil) -> OverlayMask? {
    var protection = protection
    return protection.nominate(observation: observation ?? self.observation(), exposure: exposure,
                        activity: activity ?? self.activity, windows: [
                          WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
                            bounds: CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: 0)
                        ], at: start.addingTimeInterval(second))
  }

  @Test func oneBrightSampleIsNotEvidenceOfPersistentContent() {
    var protection = AdaptiveRegionProtection()
    protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                      through: transform, observation: observation(), at: start)
    #expect(mask(protection, at: 0) == nil)
    #expect(mask(warmed()) != nil)
  }

  @Test func movingDetailWithTheSameMeanLuminanceDoesNotBecomeStatic() {
    var protection = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 360, by: 60) {
      // Every cell retains a mean of 0.7, but the detail swaps every sample.
      let grid = (0..<960).map { pixel in
        (pixel % 2 == (second / 60) % 2) ? 0.5 : 0.9
      }
      protection.record(displayGrid: grid, cols: 48, rows: 20,
                        through: transform, observation: observation(),
                        at: start.addingTimeInterval(Double(second)))
    }
    #expect(mask(protection, at: 360) == nil)
    #expect(mask(warmed()) != nil)
  }

  @Test func changedContentClearsOnlyItsOwnRegion() {
    var protection = warmed()
    var pixels = Array(repeating: 0.8, count: 960)
    pixels[0] = 0.4
    protection.record(displayGrid: pixels, cols: 48, rows: 20,
                      through: transform, observation: observation(),
                      at: start.addingTimeInterval(360))
    let result = mask(protection, at: 360)
    #expect(result?.cells[0] == 0)
    #expect((result?.cells[239] ?? 0) > 0)
  }

  @Test func aStaticRectangleHasATaperedBoundaryAndRoundedCorners() throws {
    var pixels = Array(repeating: 0.2, count: 240)
    for row in 2...7 {
      for col in 4...15 { pixels[row * 24 + col] = 0.8 }
    }
    var protection = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 300, by: 60) {
      protection.record(displayGrid: pixels, cols: 24, rows: 10,
        through: transform, observation: observation(),
        at: start.addingTimeInterval(Double(second)))
    }
    let result = try #require(mask(protection))
    let edge = result.cells[4 * 24 + 4]
    let shoulder = result.cells[4 * 24 + 5]
    let interior = result.cells[4 * 24 + 6]
    #expect(edge > 0 && edge < shoulder)
    #expect(shoulder < interior)
    #expect(interior == 38.0 / 255) // Original 15% depth, quantized to 8 bits.
    #expect(result.cells[2 * 24 + 4] < edge) // Corner fades in both directions.
    for cell in pixels.indices where pixels[cell] == 0.2 {
      #expect(result.cells[cell] == 0) // Feathering cannot nominate dark content.
    }
  }

  @Test func featheringKeepsAdjacentMovingContentClear() throws {
    var protection = AdaptiveRegionProtection()
    for sample in 0...5 {
      let pixels = (0..<240).map { cell in
        cell % 24 < 12 ? 0.8 : (sample.isMultiple(of: 2) ? 0.6 : 0.9)
      }
      protection.record(displayGrid: pixels, cols: 24, rows: 10,
        through: transform, observation: observation(),
        at: start.addingTimeInterval(Double(sample * 60)))
    }
    let result = try #require(mask(protection))
    #expect(result.cells[5 * 24 + 11] < result.cells[5 * 24 + 9])
    for cell in result.cells.indices where cell % 24 >= 12 {
      #expect(result.cells[cell] == 0)
    }
    // The physical display edge has no adjacent content to protect.
    #expect(result.cells[0] == 38.0 / 255)
  }

  @Test func focusedAppAndEntireHoveredWindowAreProtected() {
    let protection = warmed()
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 7, pointerPosition: nil)) == nil)
    let otherApp = mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 99, pointerPosition: CGPoint(x: 150, y: 150)))
    #expect(otherApp == nil) // Hover restores even the far end of the same window.
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: nil, frontmostPID: 7, pointerPosition: nil)) == nil)
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: nil, pointerPosition: nil)) == nil)
  }


  @Test func hoveringOneWindowLeavesAnotherWindowOfTheSameAppProtected() {
    let windows = [
      WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
        bounds: CGRect(x: 0, y: 0, width: 1200, height: 1000), layer: 0),
      WindowSnapshot(windowID: 2, ownerPID: 7, ownerName: "Editor",
        bounds: CGRect(x: 1200, y: 0, width: 1200, height: 1000), layer: 0),
    ]
    var observer = WindowObserver()
    _ = observer.observe(windows, through: transform, at: start)
    let observed = observer.observe(windows, through: transform, at: start.addingTimeInterval(300))
    var protection = warmed(observation: observed)
    func nominate(_ point: CGPoint?, _ second: Double) -> OverlayMask? {
      protection.nominate(observation: observed, exposure: .empty,
        activity: .init(isFocusedDisplay: false, frontmostPID: 99, pointerPosition: point),
        windows: windows, at: start.addingTimeInterval(second))
    }
    let beforeHover = nominate(nil, 300)
    let hovered = nominate(CGPoint(x: 1, y: 1), 300)
    #expect(protection.needsInputTracking)
    #expect(hovered?.cells[216] == 0) // Far corner of the hovered window.
    #expect((hovered?.cells[239] ?? 0) > 0) // Same app, different window.
    #expect(hovered?.cells[5 * 24 + 12] == beforeHover?.cells[5 * 24 + 12])
    #expect(nominate(nil, 301)?.cells[216] == 0)
    #expect(nominate(nil, 303)?.cells[216] == 0) // Grace has just ended.
    let fading = nominate(nil, 303.5)
    #expect((fading?.cells[216] ?? 0) > 0)
    #expect((fading?.cells[216] ?? 1) < (fading?.cells[239] ?? 0))
    #expect(nominate(nil, 304)?.cells[216] == hovered?.cells[239])
    #expect(!protection.needsInputTracking)
  }

  @Test func clearingTheLastMaskKeepsExitTrackingThroughTheReturn() {
    let windows = [WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
      bounds: CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: 0)]
    var protection = warmed()
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: .init(isFocusedDisplay: false, frontmostPID: 99,
                      pointerPosition: CGPoint(x: 50, y: 50)),
      windows: windows, at: start.addingTimeInterval(300)) == nil)
    #expect(protection.needsInputTracking)
    #expect(!protection.isRestoringWindows) // Listen for exit without fast polling.
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: activity, windows: windows, at: start.addingTimeInterval(301)) == nil)
    #expect(protection.needsInputTracking && protection.isRestoringWindows)
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: activity, windows: windows, at: start.addingTimeInterval(304)) != nil)
    #expect(!protection.needsInputTracking && !protection.isRestoringWindows)
  }

  @Test func staleEvidenceEndsTheReturnCadenceAndWithholdsTheMask() {
    let windows = [WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
      bounds: CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: 0)]
    var protection = warmed()
    _ = protection.nominate(observation: observation(), exposure: .empty,
      activity: .init(isFocusedDisplay: false, frontmostPID: 99,
                      pointerPosition: CGPoint(x: 50, y: 50)),
      windows: windows, at: start.addingTimeInterval(389))
    _ = protection.nominate(observation: observation(), exposure: .empty,
      activity: activity, windows: windows, at: start.addingTimeInterval(390))
    #expect(protection.isRestoringWindows)
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: activity, windows: windows, at: start.addingTimeInterval(391)) == nil)
    #expect(!protection.isRestoringWindows)
    #expect(!protection.needsInputTracking)
  }

  @Test func rotatedDisplayAndPointerBeyondItsBoundsRestoreTheSpanningWindow() {
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 1000, height: 2400), rotation: .ninety)
    let windows = [WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
      bounds: CGRect(x: -100, y: 0, width: 1100, height: 2400), layer: 0)]
    var protection = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 300, by: 60) {
      protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 20, rows: 48,
        through: rotated, observation: observation(), at: start.addingTimeInterval(Double(second)))
    }
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: activity, windows: windows, at: start.addingTimeInterval(300)) != nil)
    #expect(protection.nominate(observation: observation(), exposure: .empty,
      activity: .init(isFocusedDisplay: false, frontmostPID: 99,
                      pointerPosition: CGPoint(x: -50, y: 50)),
      windows: windows, at: start.addingTimeInterval(300)) == nil)
  }

  @Test func anExcludedForegroundAppCannotBeDimmedThroughItsBackgroundWindows() {
    let protection = warmed()
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 42, pointerPosition: nil,
      captureExcludedPID: 42)) == nil)
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 42, pointerPosition: nil,
      captureExcludedPID: 99)) != nil)
  }

  @Test func aForegroundAppSpanningDisplaysIsProtectedOnBoth() {
    #expect(mask(warmed(), activity: .init(
      isFocusedDisplay: false, frontmostPID: 7, pointerPosition: nil)) == nil)
  }

  @Test func historyStrengthensEligibleHotRegionsButCannotNominateDarkContent() {
    var accumulator = ExposureAccumulator()
    var past = Array(repeating: 0.1, count: 240)
    past[0] = 1
    for second in 0..<30 {
      accumulator.accumulate(displayGrid: past, cols: 24, rows: 10, through: transform,
                             elapsed: 60, at: start.addingTimeInterval(Double(second * 60)))
    }
    let protection = warmed()
    let baseline = mask(protection)
    let weighted = mask(protection, exposure: accumulator.map)
    #expect((weighted?.cells[0] ?? 0) > (baseline?.cells[0] ?? 0))
    #expect(weighted?.cells[0] == 64.0 / 255) // Full 25% depth survives away from boundaries.
    #expect(weighted?.cells[239] == baseline?.cells[239])
    #expect((weighted?.peak ?? 1) <= 0.251)

    var dark = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 300, by: 60) {
      dark.record(displayGrid: Array(repeating: 0.02, count: 960), cols: 48, rows: 20,
                  through: transform, observation: observation(),
                  at: start.addingTimeInterval(Double(second)))
    }
    #expect(mask(dark, exposure: accumulator.map) == nil)
  }

  @Test func windowReplacementAndFullScreenLiftImmediatelyWithoutAnotherCapture() {
    let protection = warmed()
    #expect(mask(protection, observation: observation(window: 2)) == nil)
    #expect(mask(protection, observation: observation(fullScreen: "Player")) == nil)
    #expect(mask(protection) != nil)
  }

  @Test func gapsAndInvalidSamplesRequireFreshEvidence() {
    let original = warmed()
    #expect(mask(original, at: 500) == nil)
    for bad in [Double.nan, .infinity, -1] {
      var protection = original
      var pixels = Array(repeating: 0.8, count: 960)
      pixels[0] = bad
      protection.record(displayGrid: pixels, cols: 48, rows: 20, through: transform,
                        observation: observation(), at: start.addingTimeInterval(360))
      #expect(mask(protection, at: 360) == nil)
    }
    var resumed = original
    resumed.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                   through: transform, observation: observation(),
                   at: start.addingTimeInterval(900))
    #expect(mask(resumed, at: 900) == nil)
  }

  @Test func clockReversalAndGeometryChangesDiscardStability() {
    var protection = warmed()
    protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                      through: transform, observation: observation(), at: start)
    #expect(mask(protection, at: 0) == nil)
    protection = warmed()
    protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                      through: .init(displaySize: CGSize(width: 1000, height: 2400),
                                     rotation: .ninety),
                      observation: observation(), at: start.addingTimeInterval(360))
    #expect(mask(protection, at: 360) == nil)
  }

  @Test func foregroundPartialWindowDoesNotBorrowTheBackgroundWindowsAge() {
    var observer = WindowObserver()
    let windows = [
      WindowSnapshot(windowID: 2, ownerPID: 8, ownerName: "Photo",
                     bounds: CGRect(x: 0, y: 0, width: 50, height: 100), layer: 0),
      WindowSnapshot(windowID: 1, ownerPID: 7, ownerName: "Editor",
                     bounds: CGRect(x: 0, y: 0, width: 2300, height: 1000), layer: 0),
    ]
    _ = observer.observe(windows, through: transform, at: start)
    let observation = observer.observe(windows, through: transform,
                                       at: start.addingTimeInterval(300))
    // A mixed cell is uncertain; the fully visible neighboring cell is usable.
    #expect(observation.windowIDByCell[0] == nil)
    #expect(observation.windowIDByCell[1] == 1)
    #expect(observation.ownerPIDByCell[1] == 7)
  }
}
