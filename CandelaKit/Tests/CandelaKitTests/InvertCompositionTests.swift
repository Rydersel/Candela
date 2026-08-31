import Foundation
import Testing
@testable import CandelaKit

/// Invert is a hardware correction: it says this display's brightness register
/// runs backwards, and the portion domain stays the truth on both sides of it.
/// Combined dimming pins the portion to 0 in the software zone, so with Invert
/// on that pin writes the register's MAXIMUM, which on a backwards display is
/// its darkest setting.
///
/// With the pref on a display that runs the normal way, the composed response is
/// a tent peaking at the switching point. Ruled, not a defect: it is the same
/// shape a backwards display shows with Invert off, and one pref cannot flatten
/// both, because the software leg would have to run in opposite directions.
/// Flattening it breaks
/// `theInteriorMaximumOfAMismatchedInvertPrefSitsAtTheSwitchingPoint` on purpose,
/// and costs the top of the range on the display that needed Invert.
@Suite("Invert composition")
struct InvertCompositionTests {
  /// The register range the engine assumes until a display answers a read, and
  /// the one the write-only ultrawide in the rig never replaces.
  private static let maxDDC = 100.0

  /// Light against the brightness register: rising with it, or running backwards,
  /// which is the only hardware Invert exists for. The floor is not zero because
  /// a display parked at its DDC minimum still emits light, and a zero floor
  /// would flatten the software zone and hide every ordering question here.
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

  /// The shapes the engine can put a display in, named by what carries the value.
  private enum Leg {
    case combined(switchingPoint: Int)
    case pureDDC
    case softwareOnly
  }

  /// The switching point walked to both rails: at -8 the software band has no
  /// width and combined degrades to pure hardware, at 7 it is nearly the whole slider.
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

  /// A display nobody drives over DDC sits wherever its own buttons left it. The
  /// value is arbitrary; the constancy is what keeps the pref out of that leg.
  private static let undrivenRegister: UInt16 = 60

  private func raw(_ portion: Double, invert: Bool) -> UInt16 {
    DimmingMath.valueToDDC(portion, minDDC: 0, maxDDC: Self.maxDDC, invert: invert)
  }

  /// The software leg's physical multiplier, floored at 0.15 as the engine
  /// floors it for every display that has not opted into zero.
  private func multiplier(_ sw: Double) -> Double {
    DimmingMath.swTransform(sw, allowZero: false)
  }

  /// The register's own response times whatever the software leg scales it by,
  /// assembled the way `applyPaths` assembles it and no other way.
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
    // Monotonic alone would pass on a flat line. The endpoints catch what that
    // hides: a slider whose top end is clamped to the software floor.
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

  /// Off the engine's submit path, not recomputed: with Invert on, the combined
  /// software zone parks the register at its MAXIMUM and a full slider at its
  /// MINIMUM. `combinedBoundaryWalk` pins the same two points the other way round.
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
