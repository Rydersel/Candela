//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

/// The dimming contract, transplanted verbatim from the MonitorControl fork
/// (`Model/OtherDisplay.swift`, `Model/Display.swift`, `Support/OSDUtils.swift`)
/// and documented in `.superpowers/m3-dossier/dimming-math.md`. Pure functions
/// only — no state, no I/O — so every later M3 stage (combined brightness,
/// gamma/shade dimming, HDR-native routing) computes from one source of truth.
///
/// Three distinct value domains meet here; never store one in another's slot:
/// - **user value** `v` — the 0…1 combined brightness the user manipulates.
/// - **DDC portion** — the 0…1 slice of `v` that maps to hardware brightness.
/// - **sw value** — the 0…1 software-dimming level (gamma scale or shade alpha).
public enum DimmingMath {
  /// Range of the per-display switching-point pref (fork: `NSSlider(minValue: -8, maxValue: 7)`).
  public static let switchingPointRange: ClosedRange<Int> = -8 ... 7

  /// 16 OSD chiclets per half; the combined scale runs on both halves at once
  /// (fork `OSDUtils.chiclet(half: true)`), so 32 across 0…1.
  private static let combinedChicletCount: Double = 32
  /// "25% of the distance between the edges of an osd box" (fork verbatim).
  private static let chicletDistanceThreshold: Double = 0.25
  /// The compositor alpha-blends the shade in gamma-encoded space: linear alpha
  /// reads washed out, a full 2.2 curve double-applies gamma and goes near-black
  /// by mid-slider. 1.5 is the perceptual middle ground (fork `Display.shadeCurveExponent`).
  private static let shadeCurveExponent: Double = 1.5
  /// Software dimming stops at 15% of the panel's output unless the user opts
  /// into zero (fork `.allowZeroSwBrightness`), so it can never blank the screen.
  private static let swLowThreshold: Double = 0.15

  // MARK: - Combined-brightness boundary

  /// The boundary of the combined scale: user values in `[s, 1]` drive hardware
  /// (DDC) brightness, `[0, s)` drives software dimming with DDC pinned at 0.
  ///
  /// `s = (p + 8) / 16` for switching-point pref `p`, clamped to `-8...7`, so
  /// `s ∈ [0, 0.9375]` in 1/16 steps. Default `p = 0` → `s = 0.5`.
  public static func switchingValue(fromPoint p: Int) -> Double {
    Double(min(max(p, switchingPointRange.lowerBound), switchingPointRange.upperBound) + 8) / 16
  }

  /// Splits a combined user value into its hardware and software components
  /// (fork `OtherDisplay.setDirectBrightness`). Both components come back on
  /// every call whichever side of `s` the value falls on: the DDC write pins the
  /// panel to hardware minimum inside the software zone, and the sw value sits
  /// at 1 inside the hardware zone. That is what makes boundary crossings
  /// self-consistent without tracking a "mode".
  ///
  /// - `v >= s`: DDC portion `(v − s) / (1 − s)`, sw value `1`.
  /// - `v < s`: DDC portion `0`, sw value `v / s`.
  ///
  /// At `s = 0` (pref point −8, pure hardware) the first branch always wins, so
  /// the `v / s` divide never executes.
  public static func combinedSplit(value v: Double, switching s: Double) -> (ddc: Double, sw: Double) {
    let value = clamp01(v)
    let switching = clamp01(s)
    // `switchingValue` never returns 1 (its max is 0.9375), but the argument is
    // free-standing: guard rather than emit NaN.
    guard switching < 1 else { return (ddc: 0, sw: value) }
    if value >= switching {
      return (ddc: (value - switching) * (1 / (1 - switching)), sw: 1)
    }
    return (ddc: 0, sw: value / switching)
  }

  // MARK: - Software dimming

  /// Maps a 0…1 sw value onto the physical multiplier `[t, 1]` where
  /// `t = allowZero ? 0 : 0.15` (fork `Display.swBrightnessTransform`). Applied
  /// to both the current and the new value before any gamma/shade write.
  public static func swTransform(_ v: Double, allowZero: Bool) -> Double {
    let lowThreshold = allowZero ? 0 : swLowThreshold
    return v * (1 - lowThreshold) + lowThreshold
  }

  /// Overlay alpha for the shade dimming path: `alpha = 1 − v^1.5`.
  public static func shadeAlpha(fromValue v: Double) -> Double {
    1 - pow(clamp01(v), shadeCurveExponent)
  }

  // MARK: - Stepping

  /// One keypress step along the combined 0…1 scale (fork
  /// `OtherDisplay.calcNewValue` with `half: true`): 32 chiclets.
  public static func stepCombined(current: Double, isUp: Bool, isFine: Bool) -> Double {
    step(current: current, isUp: isUp, isFine: isFine, chicletCount: combinedChicletCount)
  }

  /// One keypress step for the plain 16-chiclet commands — volume, contrast,
  /// and (per D3) brightness's default branch: ceil/floor snap in the
  /// direction of travel, 25% hysteresis, fine ±0.01 (fork
  /// `OtherDisplay.calcNewValue`, `half: false`).
  public static func stepValue(current: Double, isUp: Bool, isFine: Bool) -> Double {
    step(current: current, isUp: isUp, isFine: isFine, chicletCount: 16)
  }

  private static func step(current: Double, isUp: Bool, isFine: Bool, chicletCount: Double) -> Double {
    let next: Double
    if isFine {
      next = current + (isUp ? 0.01 : -0.01)
    } else {
      let chiclet = current * chicletCount
      // Distance above the next-lower chiclet — `.towardZero`, not nearest.
      let distance = abs(chiclet.rounded(.towardZero) - chiclet)
      var nextFilledChiclet = isUp ? chiclet.rounded(.up) : chiclet.rounded(.down)
      if distance == 0 {
        // Exactly on a chiclet: ceil/floor would be a no-op, so move a whole one.
        nextFilledChiclet += isUp ? 1 : -1
      } else if !isUp, distance < chicletDistanceThreshold {
        // So close to the floor chiclet that stopping there is imperceptible.
        nextFilledChiclet -= 1
      } else if isUp, distance > 1 - chicletDistanceThreshold {
        nextFilledChiclet += 1
      }
      next = nextFilledChiclet / chicletCount
    }
    return clamp01(next)
  }

  // MARK: - DDC conversion

  /// Fork `getCurveMultiplier`: 9-step curve index → exponent. 0 (unset) and 5
  /// are both linear. Applied `pow(v, m)` on write, `pow(n, 1/m)` on read.
  public static func curveMultiplier(forIndex index: Int) -> Double {
    switch index {
    case 1: return 0.6
    case 2: return 0.7
    case 3: return 0.8
    case 4: return 0.9
    case 6: return 1.3
    case 7: return 1.5
    case 8: return 1.7
    case 9: return 1.88
    default: return 1.0
    }
  }

  /// A 0…1 portion as a raw register value (fork `convValueToDDC`). Order is
  /// load-bearing (D3): invert → clamp01 → curve → affine [minDDC, maxDDC] →
  /// clamp → truncating UInt16 (fork behavior: 0.004 of a 0…100 range is DDC
  /// 0) → optional volume floor. `floorNonZeroToOne` is the fork's "never let
  /// sound mute accidentally" rule — muting breaks some panels, so a non-zero
  /// input never produces digital 0.
  public static func valueToDDC(
    _ v: Double, minDDC: Double, maxDDC: Double,
    curve: Double = 1.0, invert: Bool = false, floorNonZeroToOne: Bool = false
  ) -> UInt16 {
    var value = v
    if invert { value = 1 - value }
    let curvedValue = pow(clamp01(value), curve)
    let deNormalizedValue = (maxDDC - minDDC) * curvedValue + minDDC
    let bounded = min(max(deNormalizedValue, minDDC), maxDDC)
    var raw = UInt16(min(max(bounded, 0), Double(UInt16.max)))
    if floorNonZeroToOne, v > 0 {
      raw = max(1, raw)
    }
    return raw
  }

  /// Inverse of ``valueToDDC`` (fork `convDDCToValue`): curve unapplied as
  /// `pow(n, 1/curve)`, invert last.
  public static func ddcToValue(
    _ raw: UInt16, minDDC: Double, maxDDC: Double,
    curve: Double = 1.0, invert: Bool = false
  ) -> Double {
    guard maxDDC > minDDC else { return 0 }
    let normalizedValue = (min(max(Double(raw), minDDC), maxDDC) - minDDC) / (maxDDC - minDDC)
    var value = pow(normalizedValue, 1 / curve)
    if invert { value = 1 - value }
    return clamp01(value)
  }

  private static func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}
