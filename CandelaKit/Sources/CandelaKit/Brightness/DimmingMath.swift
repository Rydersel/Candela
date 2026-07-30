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
  /// Fixed linear DDC curve for M3. Per-command curve/invert tuning is M4 work;
  /// `minDDC`/`maxDDC` are already parameters so that arrival is additive.
  private static let ddcCurveMultiplier: Double = 1.0

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
  /// (fork `OtherDisplay.setDirectBrightness`). Both components are produced on
  /// every call regardless of which side of `s` the value falls on — the DDC
  /// write pins the panel to hardware minimum inside the software zone, and the
  /// sw value sits at 1 (dimming off) inside the hardware zone. That is what
  /// makes boundary crossings self-consistent without tracking a "mode".
  ///
  /// - `v >= s`: DDC portion `(v − s) / (1 − s)`, sw value `1`.
  /// - `v < s`: DDC portion `0`, sw value `v / s`.
  ///
  /// At `s = 0` (pref point −8, pure hardware) the first branch always wins, so
  /// the `v / s` divide never executes.
  public static func combinedSplit(value v: Double, switching s: Double) -> (ddc: Double, sw: Double) {
    let value = clamp01(v)
    let switching = clamp01(s)
    // `switchingValue` can never return 1 (its max is 0.9375), but the argument
    // is free-standing — guard rather than emit NaN.
    guard switching < 1 else { return (ddc: 0, sw: value) }
    if value >= switching {
      return (ddc: (value - switching) * (1 / (1 - switching)), sw: 1)
    }
    return (ddc: 0, sw: value / switching)
  }

  /// The DDC portion of a combined value, for restore/readback paths that don't
  /// need the software component (fork `OtherDisplay.getDDCValueFromPrefs`).
  public static func ddcPortion(ofValue v: Double, switching s: Double) -> Double {
    let value = clamp01(v)
    let switching = clamp01(s)
    guard switching < 1 else { return 0 }
    return max(0, value - switching) * (1 / (1 - switching))
  }

  // MARK: - Software dimming

  /// Maps a 0…1 sw value onto the physical multiplier `[t, 1]` where
  /// `t = allowZero ? 0 : 0.15` (fork `Display.swBrightnessTransform`). Applied
  /// to both the current and the new value before any gamma/shade write; the
  /// reverse direction recovers the sw value on readback.
  public static func swTransform(_ v: Double, allowZero: Bool, reverse: Bool) -> Double {
    let lowThreshold = allowZero ? 0 : swLowThreshold
    if !reverse {
      return v * (1 - lowThreshold) + lowThreshold
    } else {
      return (v - lowThreshold) / (1 - lowThreshold)
    }
  }

  /// Overlay alpha for the shade dimming path: `alpha = 1 − v^1.5`.
  public static func shadeAlpha(fromValue v: Double) -> Double {
    1 - pow(clamp01(v), shadeCurveExponent)
  }

  /// Inverse of ``shadeAlpha(fromValue:)``: `v = (1 − alpha)^(1/1.5)`.
  public static func shadeValue(fromAlpha a: Double) -> Double {
    pow(clamp01(1 - a), 1 / shadeCurveExponent)
  }

  // MARK: - Stepping

  /// One keypress step along the combined 0…1 scale (fork
  /// `OtherDisplay.calcNewValue` with `half: true`): 32 chiclets, snapping in
  /// the direction of travel, with a quarter-chiclet bias so a step never lands
  /// imperceptibly close to where it started. `isFine` is a flat ±0.01.
  public static func stepCombined(current: Double, isUp: Bool, isFine: Bool) -> Double {
    let next: Double
    if isFine {
      next = current + (isUp ? 0.01 : -0.01)
    } else {
      let chiclet = current * combinedChicletCount
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
      next = nextFilledChiclet / combinedChicletCount
    }
    return clamp01(next)
  }

  // MARK: - DDC conversion

  /// A 0…1 DDC portion as a raw register value (fork `convValueToDDC`):
  /// curve, denormalize into `[minDDC, maxDDC]`, truncate. Truncation (not
  /// rounding) is the fork's behavior — 0.004 of a 0…100 range is DDC 0.
  ///
  /// No volume special case here: M3 is brightness only.
  public static func valueToDDC(_ v: Double, minDDC: Double, maxDDC: Double) -> UInt16 {
    let curvedValue = pow(clamp01(v), ddcCurveMultiplier)
    let deNormalizedValue = (maxDDC - minDDC) * curvedValue + minDDC
    let bounded = min(max(deNormalizedValue, minDDC), maxDDC)
    return UInt16(min(max(bounded, 0), Double(UInt16.max)))
  }

  /// Inverse of ``valueToDDC(_:minDDC:maxDDC:)`` (fork `convDDCToValue`).
  public static func ddcToValue(_ raw: UInt16, minDDC: Double, maxDDC: Double) -> Double {
    guard maxDDC > minDDC else { return 0 }
    let normalizedValue = (min(max(Double(raw), minDDC), maxDDC) - minDDC) / (maxDDC - minDDC)
    return clamp01(pow(normalizedValue, 1 / ddcCurveMultiplier))
  }

  private static func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}
