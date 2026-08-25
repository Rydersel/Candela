import Foundation
import Testing
@testable import CandelaKit

/// What Invert means, pinned against the composition it runs inside.
///
/// Invert is a HARDWARE CORRECTION: it says "this display's brightness register
/// runs backwards", and the portion domain stays the truth on both sides of it
/// (portion 0 is the darkest the display goes, whatever register value lands
/// there). Under combined dimming the software zone pins the portion to 0, so
/// with Invert on that pin writes the register's MAXIMUM, and on a display that
/// really does run backwards that is its darkest setting. The composed response
/// is then monotonic, which is the whole point of the control.
///
/// Turn Invert on for a display that does NOT run backwards and the composed
/// response is a tent: the software zone rides on a full-brightness register
/// while the hardware zone descends, so the peak sits exactly at the switching
/// point. That tent is not a defect in the composition. It is the identical
/// shape a genuinely backwards display shows with Invert OFF, which is the
/// symptom the control exists to remove, and the two are a bijection: no code
/// can make both of them monotonic, because the software leg would have to run
/// in opposite directions in the two cases and the app has one pref telling it
/// which case it is in.
///
/// So these tests pin the ruled semantics rather than a bug fix. A future
/// change that makes the software leg inversion-aware to flatten the tent will
/// fail `theInteriorMaximumOfAMismatchedInvertPrefSitsAtTheSwitchingPoint`, and
/// that failure is the warning: it buys a correct-looking slider on a display
/// that never needed the control and takes the top of the range away from the
/// display that did.
@Suite("Invert composition")
struct InvertCompositionTests {
  /// The register range the engine assumes until a display answers a read, and
  /// the one the write-only ultrawide in the rig never replaces.
  private static let maxDDC = 100.0

  /// How a display's light responds to its brightness register: rising with it,
  /// or running backwards, which is the only hardware Invert exists for.
  ///
  /// The floor is deliberately NOT zero. A display parked at its DDC minimum
  /// still emits light, and that residue is exactly what the software leg dims
  /// below; a model that bottomed out at zero would make the whole software
  /// zone flat and hide every ordering question these tests ask.
  private enum Panel {
    case normal
    case backwards

    static let floor = 0.1

    func light(register raw: UInt16) -> Double {
      let fraction = Double(raw) / InvertCompositionTests.maxDDC
      let rising = self == .normal ? fraction : 1 - fraction
      return Panel.floor + (1 - Panel.floor) * rising
    }
  }

  /// The three shapes the engine can put a display in, named by what carries
  /// the value rather than by the pref that selects them.
  private enum Leg {
    case combined(switchingPoint: Int)
    case pureDDC
    case softwareOnly
  }

  /// Every leg the composition can run, with the switching point walked to both
  /// rails: at -8 the software band has no width and combined degrades to pure
  /// hardware, at 7 it is nearly the whole slider.
  private static let legs: [Leg] = [
    .combined(switchingPoint: -8),
    .combined(switchingPoint: 0),
    .combined(switchingPoint: 4),
    .combined(switchingPoint: 7),
    .pureDDC,
    .softwareOnly,
  ]

  /// 1/64 steps, which contains every 1/16 switching value exactly, so a peak
  /// can be compared against `switchingValue` with `==` and no tolerance.
  private static let grid: [Double] = (0 ... 64).map { Double($0) / 64 }

  /// A display nobody is driving over DDC sits wherever its own buttons left
  /// it. The value is arbitrary; what matters is that it is a constant, because
  /// that is what makes the software-only leg unable to see the pref at all.
  private static let undrivenRegister: UInt16 = 60

  private func raw(_ portion: Double, invert: Bool) -> UInt16 {
    DimmingMath.valueToDDC(portion, minDDC: 0, maxDDC: Self.maxDDC, invert: invert)
  }

  /// The software leg's physical multiplier, floored at 0.15 as the engine
  /// floors it for every display that has not opted into zero.
  private func multiplier(_ sw: Double) -> Double {
    DimmingMath.swTransform(sw, allowZero: false)
  }

  /// The composed light a display emits for a slider value: the register's own
  /// response times whatever the software leg is scaling it by. This is the
  /// engine's arithmetic and nothing else, assembled the way `applyPaths`
  /// assembles it.
  private func composedLight(at value: Double, leg: Leg, invert: Bool, panel: Panel) -> Double {
    switch leg {
    case let .combined(point):
      let split = DimmingMath.combinedSplit(
        value: value, switching: DimmingMath.switchingValue(fromPoint: point)
      )
      return panel.light(register: raw(split.ddc, invert: invert)) * multiplier(split.sw)
    case .pureDDC:
      return panel.light(register: raw(value, invert: invert)) * multiplier(1)
    case .softwareOnly:
      return panel.light(register: Self.undrivenRegister) * multiplier(value)
    }
  }

  private func describe(_ leg: Leg) -> String {
    switch leg {
    case let .combined(point): "combined at switching point \(point)"
    case .pureDDC: "pure DDC"
    case .softwareOnly: "software only"
    }
  }

  // MARK: - The property the control promises

  @Test func composedLightRisesAcrossTheWholeRangeWhenTheInvertPrefMatchesThePanel() {
    let matched: [(panel: Panel, invert: Bool)] = [(.normal, false), (.backwards, true)]
    for (panel, invert) in matched {
      for leg in Self.legs {
        var previous = -Double.infinity
        for value in Self.grid {
          let light = composedLight(at: value, leg: leg, invert: invert, panel: panel)
          #expect(
            light >= previous,
            "\(panel) panel, invert \(invert), \(describe(leg)): light fell at \(value)"
          )
          previous = light
        }
      }
    }
  }

  @Test func theEndpointsSpanTheWholeRangeWhenTheInvertPrefMatchesThePanel() {
    // Monotonic alone would be satisfied by a flat line. Both matched pairings
    // have to reach the display's floor at 0 and its ceiling at 1, because the
    // failure a mismatched inversion would otherwise hide is a slider whose top
    // end is clamped to the software floor.
    let matched: [(panel: Panel, invert: Bool)] = [(.normal, false), (.backwards, true)]
    for (panel, invert) in matched {
      for point in [-8, 0, 4, 7] {
        let leg = Leg.combined(switchingPoint: point)
        let bottom = composedLight(at: 0, leg: leg, invert: invert, panel: panel)
        let top = composedLight(at: 1, leg: leg, invert: invert, panel: panel)
        #expect(top == 1.0, "\(panel), invert \(invert), \(describe(leg)): top was \(top)")
        #expect(bottom < top)
      }
    }
  }

  // MARK: - The ruled shape of a mismatched pref

  @Test func theInteriorMaximumOfAMismatchedInvertPrefSitsAtTheSwitchingPoint() {
    let mismatched: [(panel: Panel, invert: Bool)] = [(.normal, true), (.backwards, false)]
    for (panel, invert) in mismatched {
      for point in DimmingMath.switchingPointRange {
        let leg = Leg.combined(switchingPoint: point)
        let peak = Self.grid.max { left, right in
          composedLight(at: left, leg: leg, invert: invert, panel: panel)
            < composedLight(at: right, leg: leg, invert: invert, panel: panel)
        }
        #expect(
          peak == DimmingMath.switchingValue(fromPoint: point),
          "\(panel) panel, invert \(invert), switching point \(point): peak at \(peak ?? -1)"
        )
      }
    }
  }

  @Test func theInvertPrefCannotReachADisplayThatIsDimmedInSoftwareOnly() {
    for value in Self.grid {
      let on = composedLight(at: value, leg: .softwareOnly, invert: true, panel: .normal)
      let off = composedLight(at: value, leg: .softwareOnly, invert: false, panel: .normal)
      #expect(on == off)
    }
  }

  // MARK: - The wire

  /// The register values the arithmetic above is a model of, taken off the
  /// engine's own submit path rather than recomputed: with Invert on, the
  /// combined software zone parks the register at its MAXIMUM and a full slider
  /// puts it at its MINIMUM. `combinedBoundaryWalk` pins the same two points
  /// with the pref off, where they are 0 and 100 the other way round.
  @MainActor
  @Test func invertParksTheCombinedSoftwareZoneOnTheRegisterMaximum() {
    let h = Harness { prefs, _ in
      var tuning = prefs.tuning(for: .brightness)
      tuning.invert = true
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.25) // software zone: DDC portion 0
    h.controller.setBrightness(1.0) // DDC portion 1
    #expect(h.submitted == [.ddc(raw: 100), .ddc(raw: 0)])
  }
}
