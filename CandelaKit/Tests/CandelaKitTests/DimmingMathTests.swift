import Foundation
import Testing
@testable import CandelaKit

/// Expectations are the worked examples the port was written against: the
/// MonitorControl fork is the behavior oracle for every number here.
@Suite("Dimming math")
struct DimmingMathTests {
  /// Only for expectations carrying binary-float residue (the sw reverse transform,
  /// the shade curve); everything else is exactly representable and asserted `==`.
  private func isClose(_ actual: Double, _ expected: Double, accuracy: Double) -> Bool {
    abs(actual - expected) <= accuracy
  }

  // MARK: - §1 switching value

  @Test func switchingValueDefaultsToMidpoint() {
    #expect(DimmingMath.switchingValue(fromPoint: 0) == 0.5)
  }

  @Test func switchingValueAtBottomOfPrefRange() {
    #expect(DimmingMath.switchingValue(fromPoint: -8) == 0.0)
  }

  @Test func switchingValueAtTopOfPrefRange() {
    #expect(DimmingMath.switchingValue(fromPoint: 7) == 0.9375)
  }

  @Test func switchingValueClampsAbovePrefRange() {
    #expect(DimmingMath.switchingValue(fromPoint: 9) == DimmingMath.switchingValue(fromPoint: 7))
  }

  @Test func switchingValueClampsBelowPrefRange() {
    #expect(DimmingMath.switchingValue(fromPoint: -12) == DimmingMath.switchingValue(fromPoint: -8))
  }

  // MARK: - §2 combined split

  @Test func combinedSplitAtZero() {
    let split = DimmingMath.combinedSplit(value: 0, switching: 0.5)
    #expect(split.ddc == 0)
    #expect(split.sw == 0)
  }

  @Test func combinedSplitInSoftwareZone() {
    let split = DimmingMath.combinedSplit(value: 0.25, switching: 0.5)
    #expect(split.ddc == 0)
    #expect(split.sw == 0.5)
  }

  @Test func combinedSplitOnBoundaryTakesHardwareBranch() {
    let split = DimmingMath.combinedSplit(value: 0.5, switching: 0.5)
    #expect(split.ddc == 0)
    #expect(split.sw == 1)
  }

  @Test func combinedSplitInHardwareZone() {
    let split = DimmingMath.combinedSplit(value: 0.75, switching: 0.5)
    #expect(split.ddc == 0.5)
    #expect(split.sw == 1)
  }

  @Test func combinedSplitAtTop() {
    let split = DimmingMath.combinedSplit(value: 1, switching: 0.5)
    #expect(split.ddc == 1)
    #expect(split.sw == 1)
  }

  @Test func combinedSplitWithZeroSwitchingPointIsPureHardware() {
    // s = 0 is reachable (pref point -8): the `v >= s` branch always wins, so
    // the `v / s` divide never executes.
    let split = DimmingMath.combinedSplit(value: 0.3, switching: 0)
    #expect(split.ddc == 0.3)
    #expect(split.sw == 1)
  }

  @Test func combinedSplitClampsInputs() {
    let high = DimmingMath.combinedSplit(value: 1.4, switching: 0.5)
    #expect(high.ddc == 1)
    #expect(high.sw == 1)
    let low = DimmingMath.combinedSplit(value: -0.4, switching: 0.5)
    #expect(low.ddc == 0)
    #expect(low.sw == 0)
  }

  // MARK: - §3a software brightness transform

  @Test func swTransformForwardAtZeroLandsOnTheLowThreshold() {
    #expect(DimmingMath.swTransform(0, allowZero: false) == 0.15)
  }

  @Test func swTransformForwardAtHalf() {
    #expect(DimmingMath.swTransform(0.5, allowZero: false) == 0.575)
  }

  @Test func swTransformForwardAtOne() {
    #expect(DimmingMath.swTransform(1, allowZero: false) == 1.0)
  }

  @Test func swTransformIsIdentityWhenZeroIsAllowed() {
    #expect(DimmingMath.swTransform(0, allowZero: true) == 0)
    #expect(DimmingMath.swTransform(0.5, allowZero: true) == 0.5)
  }

  // MARK: - §3b shade curve

  @Test func shadeAlphaAtFullBrightnessIsTransparent() {
    #expect(DimmingMath.shadeAlpha(fromValue: 1) == 0)
  }

  @Test func shadeAlphaAtZeroIsOpaque() {
    #expect(DimmingMath.shadeAlpha(fromValue: 0) == 1)
  }

  @Test func shadeAlphaUsesTheOneAndAHalfExponent() {
    #expect(isClose(DimmingMath.shadeAlpha(fromValue: 0.575), 0.5640, accuracy: 1e-3))
  }

  @Test func shadeClampsOutOfRangeInputs() {
    #expect(DimmingMath.shadeAlpha(fromValue: 1.5) == 0)
    #expect(DimmingMath.shadeAlpha(fromValue: -0.5) == 1)
  }

  // MARK: - §6 combined-scale stepping

  @Test func stepCombinedDownFromChicletBoundary() {
    // c = 24.0, distance 0 → 23 → 23/32.
    #expect(DimmingMath.stepCombined(current: 0.75, isUp: false, isFine: false) == 0.71875)
  }

  @Test func stepCombinedDownFromOffBoundaryValue() {
    // c = 24.32, distance 0.32 ≥ 0.25 → floor 24 → 0.75.
    #expect(DimmingMath.stepCombined(current: 0.76, isUp: false, isFine: false) == 0.75)
  }

  @Test func stepCombinedUpFromChicletBoundary() {
    // c = 16.0, distance 0 → 17 → 17/32.
    #expect(DimmingMath.stepCombined(current: 0.5, isUp: true, isFine: false) == 0.53125)
  }

  @Test func stepCombinedDownSnapsWhenCloseToTheFloorChiclet() {
    // 0.505 · 32 = 16.16 → distance 0.16 < 0.25 → floor 16, then one more → 15/32.
    #expect(DimmingMath.stepCombined(current: 0.505, isUp: false, isFine: false) == 0.46875)
  }

  @Test func stepCombinedUpSnapsWhenCloseToTheCeilingChiclet() {
    // 0.529 · 32 = 16.928 → distance 0.928 > 0.75 → ceil 17 then one more → 18/32.
    #expect(DimmingMath.stepCombined(current: 0.529, isUp: true, isFine: false) == 0.5625)
  }

  @Test func stepCombinedFineIsOneHundredth() {
    #expect(DimmingMath.stepCombined(current: 0.5, isUp: false, isFine: true) == 0.49)
    #expect(DimmingMath.stepCombined(current: 0.5, isUp: true, isFine: true) == 0.51)
  }

  @Test func stepCombinedClampsAtTop() {
    #expect(DimmingMath.stepCombined(current: 1, isUp: true, isFine: false) == 1)
    #expect(DimmingMath.stepCombined(current: 1, isUp: true, isFine: true) == 1)
  }

  @Test func stepCombinedClampsAtBottom() {
    #expect(DimmingMath.stepCombined(current: 0, isUp: false, isFine: false) == 0)
    #expect(DimmingMath.stepCombined(current: 0, isUp: false, isFine: true) == 0)
  }

  // MARK: - §9 DDC conversion

  @Test func valueToDDCIsLinearWithTheDefaultCurve() {
    #expect(DimmingMath.valueToDDC(0.5, minDDC: 0, maxDDC: 100) == 50)
  }

  @Test func valueToDDCTruncatesTowardZero() {
    // No volume special case in M3 — this is the brightness path only.
    #expect(DimmingMath.valueToDDC(0.004, minDDC: 0, maxDDC: 100) == 0)
  }

  @Test func valueToDDCHonorsMinAndMax() {
    #expect(DimmingMath.valueToDDC(0.5, minDDC: 20, maxDDC: 90) == 55)
    #expect(DimmingMath.valueToDDC(0, minDDC: 20, maxDDC: 90) == 20)
    #expect(DimmingMath.valueToDDC(1, minDDC: 20, maxDDC: 90) == 90)
  }

  @Test func valueToDDCClampsOutOfRangeInput() {
    #expect(DimmingMath.valueToDDC(1.5, minDDC: 0, maxDDC: 100) == 100)
    #expect(DimmingMath.valueToDDC(-0.5, minDDC: 0, maxDDC: 100) == 0)
  }

  @Test func ddcToValueIsLinearWithTheDefaultCurve() {
    #expect(DimmingMath.ddcToValue(50, minDDC: 0, maxDDC: 100) == 0.5)
  }

  @Test func ddcToValueClampsToTheDDCRange() {
    #expect(DimmingMath.ddcToValue(10, minDDC: 20, maxDDC: 90) == 0)
    #expect(DimmingMath.ddcToValue(200, minDDC: 20, maxDDC: 90) == 1)
  }

  @Test func ddcConversionRoundTripsWithinOneStep() {
    for percent in stride(from: 0.0, through: 1.0, by: 0.05) {
      let raw = DimmingMath.valueToDDC(percent, minDDC: 0, maxDDC: 100)
      let back = DimmingMath.ddcToValue(raw, minDDC: 0, maxDDC: 100)
      #expect(isClose(back, percent, accuracy: 1.0 / 100.0))
    }
  }

  // MARK: - M4 per-command conversion (fork convValueToDDC/convDDCToValue)

  @Test func curveTableMatchesTheForkExactly() {
    let table: [Int: Double] = [1: 0.6, 2: 0.7, 3: 0.8, 4: 0.9, 5: 1.0, 6: 1.3, 7: 1.5, 8: 1.7, 9: 1.88]
    for (index, multiplier) in table {
      #expect(DimmingMath.curveMultiplier(forIndex: index) == multiplier)
    }
    #expect(DimmingMath.curveMultiplier(forIndex: 0) == 1.0) // unset = linear
    #expect(DimmingMath.curveMultiplier(forIndex: 42) == 1.0)
  }

  @Test func valueToDDCAppliesCurveThenAffineMap() {
    // curve 0.6: pow(0.5, 0.6) ≈ 0.6598 → truncates to 65 on 0…100
    #expect(DimmingMath.valueToDDC(0.5, minDDC: 0, maxDDC: 100, curve: 0.6) == 65)
    // curve 1.88: pow(0.5, 1.88) ≈ 0.2718 → 27
    #expect(DimmingMath.valueToDDC(0.5, minDDC: 0, maxDDC: 100, curve: 1.88) == 27)
  }

  @Test func valueToDDCInvertsBeforeTheCurve() {
    // invert → 0.25, then linear on 0…100 → 25
    #expect(DimmingMath.valueToDDC(0.75, minDDC: 0, maxDDC: 100, invert: true) == 25)
    // order matters: invert(0.75)=0.25, pow(0.25, 2)=0.0625 → 6 (not pow-then-invert = 43)
    #expect(DimmingMath.valueToDDC(0.75, minDDC: 0, maxDDC: 100, curve: 2.0, invert: true) == 6)
  }

  @Test func valueToDDCMapsIntoTheOverrideBand() {
    #expect(DimmingMath.valueToDDC(0.0, minDDC: 20, maxDDC: 80) == 20)
    #expect(DimmingMath.valueToDDC(1.0, minDDC: 20, maxDDC: 80) == 80)
    #expect(DimmingMath.valueToDDC(0.5, minDDC: 20, maxDDC: 80) == 50)
  }

  @Test func volumeFloorNeverWritesAccidentalDigitalZero() {
    // "Never let sound to mute accidentally" — fork convValueToDDC
    #expect(DimmingMath.valueToDDC(0.004, minDDC: 0, maxDDC: 100, floorNonZeroToOne: true) == 1)
    #expect(DimmingMath.valueToDDC(0.0, minDDC: 0, maxDDC: 100, floorNonZeroToOne: true) == 0)
    #expect(DimmingMath.valueToDDC(0.004, minDDC: 0, maxDDC: 100) == 0) // truncation without the floor
  }

  @Test func ddcToValueIsTheInverseWithCurveAndInvert() {
    #expect(abs(DimmingMath.ddcToValue(65, minDDC: 0, maxDDC: 100, curve: 0.6) - pow(0.65, 1 / 0.6)) < 1e-9)
    #expect(DimmingMath.ddcToValue(25, minDDC: 0, maxDDC: 100, invert: true) == 0.75)
    #expect(DimmingMath.ddcToValue(50, minDDC: 0, maxDDC: 0) == 0) // degenerate range guarded, no NaN
  }

  // MARK: - Shared 16-chiclet step (fork OtherDisplay.calcNewValue, half: false)

  @Test func stepValueCoarseWalksOneChiclet() {
    #expect(DimmingMath.stepValue(current: 0.5, isUp: true, isFine: false) == 0.5625) // 8/16 → 9/16
    #expect(DimmingMath.stepValue(current: 0.5, isUp: false, isFine: false) == 0.4375) // 8/16 → 7/16
  }

  @Test func stepValueSnapsWithTheQuarterChicletHysteresis() {
    // 0.51 → chiclet 8.16: up ceil→9; down floor 8, distance 0.16 < 0.25 → 7
    #expect(DimmingMath.stepValue(current: 0.51, isUp: true, isFine: false) == 0.5625)
    #expect(DimmingMath.stepValue(current: 0.51, isUp: false, isFine: false) == 0.4375)
    // 0.55 → chiclet 8.8: up distance 0.8 > 0.75 → 10; down floor → 8
    #expect(DimmingMath.stepValue(current: 0.55, isUp: true, isFine: false) == 0.625)
    #expect(DimmingMath.stepValue(current: 0.55, isUp: false, isFine: false) == 0.5)
  }

  @Test func stepValueFineIsFlatPlusMinusPointZeroOne() {
    #expect(abs(DimmingMath.stepValue(current: 0.5, isUp: true, isFine: true) - 0.51) < 1e-9)
    #expect(abs(DimmingMath.stepValue(current: 0.5, isUp: false, isFine: true) - 0.49) < 1e-9)
  }

  @Test func stepValueClampsAtTheRails() {
    #expect(DimmingMath.stepValue(current: 1.0, isUp: true, isFine: false) == 1.0)
    #expect(DimmingMath.stepValue(current: 0.0, isUp: false, isFine: false) == 0.0)
    #expect(DimmingMath.stepValue(current: 0.005, isUp: false, isFine: true) == 0.0)
  }

  @Test func stepCombinedBehaviorIsUnchangedByTheExtraction() {
    // Regression pin: 32 chiclets, same hysteresis, same fine step as M3.
    #expect(DimmingMath.stepCombined(current: 0.5, isUp: true, isFine: false) == 0.53125)
    #expect(DimmingMath.stepCombined(current: 0.5, isUp: false, isFine: false) == 0.46875)
    #expect(abs(DimmingMath.stepCombined(current: 0.5, isUp: true, isFine: true) - 0.51) < 1e-9)
  }
}
