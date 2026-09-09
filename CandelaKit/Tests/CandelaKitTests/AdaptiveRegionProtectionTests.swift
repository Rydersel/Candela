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
    isFocusedDisplay: false, frontmostPID: 99, pointerCell: nil)

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

  private func warmed() -> AdaptiveRegionProtection {
    var protection = AdaptiveRegionProtection()
    for second in stride(from: 0, through: 300, by: 60) {
      protection.record(displayGrid: Array(repeating: 0.8, count: 960), cols: 48, rows: 20,
                        through: transform, observation: observation(),
                        at: start.addingTimeInterval(Double(second)))
    }
    return protection
  }

  private func mask(_ protection: AdaptiveRegionProtection, at second: Double = 300,
                    observation: WindowObservation? = nil,
                    exposure: ExposureMap = .empty,
                    activity: AdaptiveRegionProtection.Activity? = nil) -> OverlayMask? {
    protection.nominate(observation: observation ?? self.observation(), exposure: exposure,
                        activity: activity ?? self.activity, at: start.addingTimeInterval(second))
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

  @Test func focusedAppAndRecentPointerAreaAreProtected() {
    let protection = warmed()
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 7, pointerCell: nil)) == nil)
    let otherApp = mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 99, pointerCell: 25))
    #expect(otherApp?.cells[25] == 0)
    #expect(otherApp?.cells[0] == 0) // adjacent cell
    #expect((otherApp?.cells[239] ?? 0) > 0)
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: nil, frontmostPID: 7, pointerCell: nil)) == nil)
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: nil, pointerCell: nil)) == nil)
  }

  @Test func anExcludedForegroundAppCannotBeDimmedThroughItsBackgroundWindows() {
    let protection = warmed()
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 42, pointerCell: nil,
      captureExcludedPID: 42)) == nil)
    #expect(mask(protection, activity: .init(
      isFocusedDisplay: true, frontmostPID: 42, pointerCell: nil,
      captureExcludedPID: 99)) != nil)
  }

  @Test func aForegroundAppSpanningDisplaysIsProtectedOnBoth() {
    #expect(mask(warmed(), activity: .init(
      isFocusedDisplay: false, frontmostPID: 7, pointerCell: nil)) == nil)
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
