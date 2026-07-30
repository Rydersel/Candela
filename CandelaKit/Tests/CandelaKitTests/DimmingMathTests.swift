import Foundation
import Testing
@testable import CandelaKit

/// Expectations are the worked examples from `.superpowers/m3-dossier/dimming-math.md`
/// (§1, §2, §3, §6, §9) — the fork is the behavior oracle for every number here.
@Suite("Dimming math")
struct DimmingMathTests {
  /// Only for the two expectations that carry unavoidable binary-float residue
  /// (the sw reverse transform and the shade round-trip); everything else is
  /// exactly representable and asserted with `==`.
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

  @Test func ddcPortionIsTheInverseOfTheSplit() {
    #expect(DimmingMath.ddcPortion(ofValue: 0.71875, switching: 0.5) == 0.4375)
  }

  @Test func ddcPortionIsZeroInTheSoftwareZone() {
    #expect(DimmingMath.ddcPortion(ofValue: 0.25, switching: 0.5) == 0)
  }

  // MARK: - §3a software brightness transform

  @Test func swTransformForwardAtZeroLandsOnTheLowThreshold() {
    #expect(DimmingMath.swTransform(0, allowZero: false, reverse: false) == 0.15)
  }

  @Test func swTransformForwardAtHalf() {
    #expect(DimmingMath.swTransform(0.5, allowZero: false, reverse: false) == 0.575)
  }

  @Test func swTransformForwardAtOne() {
    #expect(DimmingMath.swTransform(1, allowZero: false, reverse: false) == 1.0)
  }

  @Test func swTransformReverse() {
    let reversed = DimmingMath.swTransform(0.575, allowZero: false, reverse: true)
    #expect(isClose(reversed, 0.5, accuracy: 1e-9))
  }

  @Test func swTransformIsIdentityWhenZeroIsAllowed() {
    #expect(DimmingMath.swTransform(0, allowZero: true, reverse: false) == 0)
    #expect(DimmingMath.swTransform(0.5, allowZero: true, reverse: false) == 0.5)
    #expect(DimmingMath.swTransform(0.5, allowZero: true, reverse: true) == 0.5)
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

  @Test func shadeRoundTrips() {
    #expect(isClose(DimmingMath.shadeValue(fromAlpha: DimmingMath.shadeAlpha(fromValue: 0.3)), 0.3, accuracy: 1e-9))
  }

  @Test func shadeClampsOutOfRangeInputs() {
    #expect(DimmingMath.shadeAlpha(fromValue: 1.5) == 0)
    #expect(DimmingMath.shadeAlpha(fromValue: -0.5) == 1)
    #expect(DimmingMath.shadeValue(fromAlpha: 1.5) == 0)
    #expect(DimmingMath.shadeValue(fromAlpha: -0.5) == 1)
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
}
